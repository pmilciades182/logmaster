#!/bin/bash
# ============================================================
# LogMaster v2.0 - Dispatcher Principal (ejecutado por cron)
# Evalúa calendario interno, itera destinos por directorio
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/functions.sh"

db_init

if ! acquire_lock; then
    exit 0
fi

trap 'release_lock' EXIT

# Identidad del nodo para el log
NODE_ID=$(db_get "SELECT node_id FROM node_config WHERE id=1")
NODE_NAME=$(db_get "SELECT node_name FROM node_config WHERE id=1")
NODE_ID="${NODE_ID:-local}"
NODE_NAME="${NODE_NAME:-$(hostname)}"

log_info "=== Inicio de ciclo [$NODE_NAME] ==="

# ============================================================
# Procesar un destino específico para un directorio
# ============================================================

process_destination() {
    local dir_id="$1" src_path="$2" dest_id="$3"

    local row
    row=$(db_query "
        SELECT dd.dest_type, dd.samba_target_id, dd.local_path,
               dd.remote_subdir, dd.action,
               COALESCE(st.name,''), COALESCE(st.server,''), COALESCE(st.share,''),
               COALESCE(st.remote_path,''), COALESCE(st.username,''), COALESCE(st.password,''),
               COALESCE(st.domain,''), COALESCE(st.port,445)
        FROM directory_destinations dd
        LEFT JOIN samba_targets st ON st.id = dd.samba_target_id
        WHERE dd.id = $dest_id AND dd.active = 1
    ")

    [ -z "$row" ] && return

    IFS='|' read -r dest_type samba_id local_path remote_subdir action \
        samba_name server share remote_path username password domain port <<< "$row"

    local dest_label
    dest_label=$(get_dest_label "$dest_id")
    log_info "  Destino: $dest_label"

    # Buscar archivos que coincidan con filtros
    local files
    files=$(find_matching_files "$src_path" "$dir_id")

    if [ -z "$files" ]; then
        log_info "  Sin archivos para transferir"
        return
    fi

    # Validar destino antes de transferir
    if [ "$dest_type" = "samba" ]; then
        if ! samba_test_connection "$server" "$share" "$username" "$password" "$domain" "$port"; then
            local msg="No se pudo conectar a Samba: //${server}/${share}"
            log_error "  $msg"
            db_exec "INSERT INTO execution_log (node_id, node_name, directory_id, destination_id, source_path, dest_label, status, message)
                     VALUES ('$NODE_ID', '$NODE_NAME', $dir_id, $dest_id, '$src_path', '$dest_label', 'error', '$msg')"
            notify_result "error" "$src_path" "$dest_label" "0" "0" "$msg" ""
            return
        fi
        local full_remote="$remote_path"
        [ -n "$remote_subdir" ] && full_remote="${remote_path%/}/${remote_subdir}"
    else
        local full_local="$local_path"
        [ -n "$remote_subdir" ] && full_local="${local_path%/}/${remote_subdir}"
        if [ ! -d "$full_local" ]; then
            if ! mkdir -p "$full_local" 2>/dev/null; then
                local msg="No se pudo crear directorio destino local: $full_local"
                log_error "  $msg"
                db_exec "INSERT INTO execution_log (directory_id, destination_id, source_path, dest_label, status, message)
                         VALUES ($dir_id, $dest_id, '$src_path', '$dest_label', 'error', '$msg')"
                notify_result "error" "$src_path" "$dest_label" "0" "0" "$msg" ""
                return
            fi
        fi
    fi

    # Transferir archivos
    local count_ok=0 count_fail=0 detail_lines=""

    while IFS= read -r filepath; do
        [ -z "$filepath" ] && continue
        local fname
        fname=$(basename "$filepath")
        local transfer_ok=0

        if [ "$dest_type" = "samba" ]; then
            if samba_upload_file "$server" "$share" "$username" "$password" "$domain" "$port" "$full_remote" "$filepath"; then
                transfer_ok=1
            fi
        else
            if local_copy_file "$filepath" "$full_local"; then
                transfer_ok=1
            fi
        fi

        if [ "$transfer_ok" -eq 1 ]; then
            log_info "    OK: $fname"
            count_ok=$((count_ok + 1))

            if [ "$action" = "move" ]; then
                if rm -f "$filepath" 2>/dev/null; then
                    detail_lines="${detail_lines}MOVIDO: ${fname}\n"
                else
                    log_warn "    No se pudo eliminar: $filepath"
                    detail_lines="${detail_lines}COPIADO (no eliminado): ${fname}\n"
                fi
            else
                detail_lines="${detail_lines}COPIADO: ${fname}\n"
            fi
        else
            log_error "    FALLO: $fname"
            count_fail=$((count_fail + 1))
            detail_lines="${detail_lines}ERROR: ${fname}\n"
        fi
    done <<< "$files"

    # Estado final
    local final_status="success"
    local final_msg="${count_ok} archivos transferidos"

    if [ "$count_fail" -gt 0 ] && [ "$count_ok" -gt 0 ]; then
        final_status="partial"
        final_msg="${count_ok} OK, ${count_fail} fallidos"
    elif [ "$count_fail" -gt 0 ] && [ "$count_ok" -eq 0 ]; then
        final_status="error"
        final_msg="Todos los archivos fallaron (${count_fail})"
    fi

    local safe_details safe_label
    safe_details=$(echo -e "$detail_lines" | sed "s/'/''/g")
    safe_label=$(echo "$dest_label" | sed "s/'/''/g")

    db_exec "INSERT INTO execution_log (node_id, node_name, directory_id, destination_id, source_path, dest_label, status, files_processed, files_failed, message, details)
             VALUES ('$NODE_ID', '$NODE_NAME', $dir_id, $dest_id, '$src_path', '$safe_label', '$final_status', $count_ok, $count_fail, '$final_msg', '$safe_details')"

    log_info "  Resultado destino: $final_msg"

    notify_result "$final_status" "$src_path" "$dest_label" "$count_ok" "$count_fail" "$final_msg" "$(echo -e "$detail_lines")"
}

# ============================================================
# Procesar un schedule completo (directorio + todos sus destinos)
# ============================================================

process_schedule() {
    local sched_id="$1"

    local sched_row
    sched_row=$(db_query "
        SELECT s.id, s.directory_id, s.schedule_type, s.interval_minutes,
               s.run_at_time, s.days_of_week,
               d.source_path
        FROM schedules s
        JOIN directories d ON d.id = s.directory_id
        WHERE s.id = $sched_id AND s.active = 1 AND d.active = 1
    ")

    [ -z "$sched_row" ] && return

    IFS='|' read -r sid dir_id stype interval run_at days src_path <<< "$sched_row"

    log_info "Procesando directorio: $src_path (schedule #$sid)"

    # Verificar directorio fuente
    if [ ! -d "$src_path" ]; then
        local msg="Directorio fuente no existe: $src_path"
        log_error "$msg"
        db_exec "INSERT INTO execution_log (node_id, node_name, directory_id, source_path, status, message)
                 VALUES ('$NODE_ID', '$NODE_NAME', $dir_id, '$src_path', 'error', '$msg')"
        notify_result "error" "$src_path" "N/A" "0" "0" "$msg" ""
        # Actualizar schedule de todas formas
        local now next
        now=$(date '+%Y-%m-%d %H:%M:%S')
        next=$(calculate_next_run "$stype" "$interval" "$run_at" "$days")
        db_exec "UPDATE schedules SET last_run='$now', next_run='$next' WHERE id=$sid"
        return
    fi

    # Obtener todos los destinos activos para este directorio
    local dest_ids
    dest_ids=$(db_query "
        SELECT dd.id FROM directory_destinations dd
        LEFT JOIN samba_targets st ON st.id = dd.samba_target_id
        WHERE dd.directory_id = $dir_id
          AND dd.active = 1
          AND (dd.dest_type = 'local' OR (dd.dest_type = 'samba' AND st.active = 1))
    ")

    if [ -z "$dest_ids" ]; then
        log_warn "Sin destinos activos para: $src_path"
        local now next
        now=$(date '+%Y-%m-%d %H:%M:%S')
        next=$(calculate_next_run "$stype" "$interval" "$run_at" "$days")
        db_exec "UPDATE schedules SET last_run='$now', next_run='$next' WHERE id=$sid"
        return
    fi

    # Procesar cada destino
    while IFS= read -r dest_id; do
        [ -z "$dest_id" ] && continue
        process_destination "$dir_id" "$src_path" "$dest_id"
    done <<< "$dest_ids"

    # Actualizar schedule
    local now next
    now=$(date '+%Y-%m-%d %H:%M:%S')
    next=$(calculate_next_run "$stype" "$interval" "$run_at" "$days")
    db_exec "UPDATE schedules SET last_run='$now', next_run='$next' WHERE id=$sid"

    log_info "Directorio completado: $src_path"
}

# ============================================================
# Bucle principal
# ============================================================

schedule_ids=$(db_query "
    SELECT s.id FROM schedules s
    JOIN directories d ON d.id = s.directory_id
    WHERE s.active = 1 AND d.active = 1
")

processed=0

while IFS= read -r sid; do
    [ -z "$sid" ] && continue

    next_run=$(db_get "SELECT next_run FROM schedules WHERE id=$sid")

    if is_schedule_due "$next_run"; then
        process_schedule "$sid"
        processed=$((processed + 1))
    fi
done <<< "$schedule_ids"

log_info "Ciclo completado: $processed tareas ejecutadas"

# Limpieza de logs antiguos
retention=$(db_get "SELECT value FROM config WHERE key='log_retention_days'")
retention=${retention:-30}
db_exec "DELETE FROM execution_log WHERE timestamp < datetime('now','localtime','-${retention} days')"

exit 0

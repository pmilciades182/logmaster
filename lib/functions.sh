#!/bin/bash
# ============================================================
# LogMaster v1.1 - Librería de Funciones Compartidas
# ============================================================

# Rutas base
LOGMASTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGMASTER_DB="${LOGMASTER_DIR}/data/logmaster.db"
LOGMASTER_LOG="${LOGMASTER_DIR}/logs/logmaster.log"
LOGMASTER_LOCK="/tmp/logmaster.lock"
LOGMASTER_TEMPLATES="${LOGMASTER_DIR}/templates"

# Colores para terminal
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ============================================================
# Base de Datos
# ============================================================

db_exec() {
    sqlite3 "$LOGMASTER_DB" "$1" 2>/dev/null
}

db_query() {
    sqlite3 -separator '|' "$LOGMASTER_DB" "$1" 2>/dev/null
}

db_query_csv() {
    sqlite3 -header -csv "$LOGMASTER_DB" "$1" 2>/dev/null
}

db_get() {
    sqlite3 "$LOGMASTER_DB" "$1" 2>/dev/null | head -1
}

db_init() {
    mkdir -p "${LOGMASTER_DIR}/data" "${LOGMASTER_DIR}/logs"
    if [ ! -f "$LOGMASTER_DB" ]; then
        sqlite3 "$LOGMASTER_DB" < "${LOGMASTER_DIR}/schema.sql"
        log_info "Base de datos inicializada: $LOGMASTER_DB"
    fi
}

# ============================================================
# Logging
# ============================================================

_log() {
    local level="$1" msg="$2"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] [$level] $msg" >> "$LOGMASTER_LOG"
}

log_info()  { _log "INFO"  "$1"; }
log_warn()  { _log "WARN"  "$1"; }
log_error() { _log "ERROR" "$1"; }

# ============================================================
# Lock (evitar ejecuciones concurrentes)
# ============================================================

acquire_lock() {
    local timeout
    timeout=$(db_get "SELECT value FROM config WHERE key='lock_timeout_minutes'")
    timeout=${timeout:-10}

    if [ -f "$LOGMASTER_LOCK" ]; then
        local lock_pid lock_age
        lock_pid=$(cat "$LOGMASTER_LOCK" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            lock_age=$(( ( $(date +%s) - $(stat -c %Y "$LOGMASTER_LOCK" 2>/dev/null || echo 0) ) / 60 ))
            if [ "$lock_age" -ge "$timeout" ]; then
                log_warn "Lock expirado (${lock_age}min), forzando liberación"
                rm -f "$LOGMASTER_LOCK"
            else
                log_info "Otra instancia en ejecución (PID $lock_pid), saliendo"
                return 1
            fi
        else
            rm -f "$LOGMASTER_LOCK"
        fi
    fi

    echo $$ > "$LOGMASTER_LOCK"
    return 0
}

release_lock() {
    rm -f "$LOGMASTER_LOCK"
}

# ============================================================
# Programación / Calendario
# ============================================================

calculate_next_run() {
    local schedule_type="$1" interval="$2" run_at="$3" days="$4"
    local now now_epoch next

    now=$(date '+%Y-%m-%d %H:%M:%S')
    now_epoch=$(date +%s)

    case "$schedule_type" in
        interval)
            next=$(date -d "@$((now_epoch + interval * 60))" '+%Y-%m-%d %H:%M:%S')
            ;;
        daily)
            local today today_run
            today=$(date '+%Y-%m-%d')
            today_run="${today} ${run_at}:00"
            if [ "$(date -d "$today_run" +%s 2>/dev/null)" -gt "$now_epoch" ]; then
                next="$today_run"
            else
                next="$(date -d "$today +1 day" '+%Y-%m-%d') ${run_at}:00"
            fi
            ;;
        weekly)
            local dow today_dow today
            today=$(date '+%Y-%m-%d')
            today_dow=$(date '+%u')
            local found=0 days_ahead=0

            for i in $(seq 0 7); do
                local check_dow=$(( ((today_dow - 1 + i) % 7) + 1 ))
                if echo ",$days," | grep -q ",$check_dow,"; then
                    if [ "$i" -eq 0 ]; then
                        local today_run="${today} ${run_at}:00"
                        if [ "$(date -d "$today_run" +%s 2>/dev/null)" -gt "$now_epoch" ]; then
                            days_ahead=0
                            found=1
                            break
                        fi
                    else
                        days_ahead=$i
                        found=1
                        break
                    fi
                fi
            done

            if [ "$found" -eq 1 ]; then
                next="$(date -d "$today +${days_ahead} day" '+%Y-%m-%d') ${run_at}:00"
            else
                next="$(date -d "$today +1 day" '+%Y-%m-%d') ${run_at}:00"
            fi
            ;;
    esac

    echo "$next"
}

is_schedule_due() {
    local next_run="$1"
    local now_epoch next_epoch

    [ -z "$next_run" ] && return 0

    now_epoch=$(date +%s)
    next_epoch=$(date -d "$next_run" +%s 2>/dev/null)

    [ -z "$next_epoch" ] && return 0
    [ "$now_epoch" -ge "$next_epoch" ] && return 0

    return 1
}

# ============================================================
# Buscar archivos con filtros
# ============================================================

find_matching_files() {
    local dir_path="$1" dir_id="$2"

    if [ ! -d "$dir_path" ]; then
        log_error "Directorio no existe: $dir_path"
        return 1
    fi

    local filters
    filters=$(db_query "SELECT pattern FROM filters WHERE directory_id=$dir_id AND active=1")

    if [ -z "$filters" ]; then
        find "$dir_path" -maxdepth 1 -type f 2>/dev/null
    else
        local find_args=()
        local first=1
        while IFS= read -r pattern; do
            [ -z "$pattern" ] && continue
            if [ "$first" -eq 1 ]; then
                find_args+=(-name "$pattern")
                first=0
            else
                find_args+=(-o -name "$pattern")
            fi
        done <<< "$filters"

        if [ "${#find_args[@]}" -gt 0 ]; then
            find "$dir_path" -maxdepth 1 -type f \( "${find_args[@]}" \) 2>/dev/null
        fi
    fi
}

# ============================================================
# Samba
# ============================================================

samba_test_connection() {
    local server="$1" share="$2" user="$3" pass="$4" domain="$5" port="$6"
    local auth_arg

    if [ -n "$user" ] && [ -n "$pass" ]; then
        if [ -n "$domain" ]; then
            auth_arg="-U ${domain}/${user}%${pass}"
        else
            auth_arg="-U ${user}%${pass}"
        fi
    else
        auth_arg="-N"
    fi

    local port_arg=""
    [ -n "$port" ] && [ "$port" != "445" ] && port_arg="-p $port"

    smbclient "//${server}/${share}" $auth_arg $port_arg -c "ls" >/dev/null 2>&1
    return $?
}

samba_upload_file() {
    local server="$1" share="$2" user="$3" pass="$4" domain="$5" port="$6"
    local remote_path="$7" local_file="$8"
    local auth_arg port_arg=""

    if [ -n "$user" ] && [ -n "$pass" ]; then
        if [ -n "$domain" ]; then
            auth_arg="-U ${domain}/${user}%${pass}"
        else
            auth_arg="-U ${user}%${pass}"
        fi
    else
        auth_arg="-N"
    fi

    [ -n "$port" ] && [ "$port" != "445" ] && port_arg="-p $port"

    local filename
    filename=$(basename "$local_file")

    local cmd=""
    if [ -n "$remote_path" ] && [ "$remote_path" != "/" ]; then
        local accum=""
        IFS='/' read -ra PARTS <<< "$remote_path"
        for part in "${PARTS[@]}"; do
            [ -z "$part" ] && continue
            accum="${accum}/${part}"
            cmd="${cmd}mkdir ${accum}; "
        done
        cmd="${cmd}cd ${remote_path}; put \"${local_file}\" \"${filename}\""
    else
        cmd="put \"${local_file}\" \"${filename}\""
    fi

    local output
    output=$(smbclient "//${server}/${share}" $auth_arg $port_arg -c "$cmd" 2>&1)
    local rc=$?

    if echo "$output" | grep -qi "NT_STATUS_\|ERRSRV\|ERRDOS\|Connection.*failed"; then
        if ! echo "$output" | grep -qi "NT_STATUS_OBJECT_NAME_COLLISION"; then
            log_error "Samba upload falló: $output"
            return 1
        fi
    fi

    return $rc
}

# ============================================================
# Copia/Movimiento Local
# ============================================================

local_copy_file() {
    local local_file="$1" dest_path="$2"

    if [ ! -f "$local_file" ]; then
        log_error "Archivo fuente no existe: $local_file"
        return 1
    fi

    # Crear directorio destino si no existe
    if [ ! -d "$dest_path" ]; then
        if ! mkdir -p "$dest_path" 2>/dev/null; then
            log_error "No se pudo crear directorio destino: $dest_path"
            return 1
        fi
    fi

    local filename
    filename=$(basename "$local_file")

    if cp -f "$local_file" "${dest_path}/${filename}" 2>/dev/null; then
        return 0
    else
        log_error "Error copiando $local_file -> $dest_path"
        return 1
    fi
}

# ============================================================
# Etiqueta descriptiva de un destino
# ============================================================

get_dest_label() {
    local dest_id="$1"
    local row
    row=$(db_query "
        SELECT dd.dest_type, dd.local_path, dd.remote_subdir, dd.action,
               COALESCE(st.name,''), COALESCE(st.server,''), COALESCE(st.share,''), COALESCE(st.remote_path,'')
        FROM directory_destinations dd
        LEFT JOIN samba_targets st ON st.id = dd.samba_target_id
        WHERE dd.id = $dest_id
    ")
    [ -z "$row" ] && echo "Destino #$dest_id" && return

    IFS='|' read -r dtype lpath subdir action sname server share rpath <<< "$row"

    if [ "$dtype" = "samba" ]; then
        local full="${rpath%/}"
        [ -n "$subdir" ] && full="${full}/${subdir}"
        echo "[Samba] ${sname} //${server}/${share}${full} (${action})"
    else
        local full="$lpath"
        [ -n "$subdir" ] && full="${full}/${subdir}"
        echo "[Local] ${full} (${action})"
    fi
}

# ============================================================
# Correo Electrónico
# ============================================================

send_email() {
    local subject="$1" body_html="$2"

    local smtp_server smtp_port use_tls from_email to_email username password
    local row
    row=$(db_query "SELECT smtp_server, smtp_port, use_tls, from_email, to_email, username, password FROM email_config WHERE id=1")

    [ -z "$row" ] && return 1

    IFS='|' read -r smtp_server smtp_port use_tls from_email to_email username password <<< "$row"

    [ -z "$smtp_server" ] || [ -z "$from_email" ] || [ -z "$to_email" ] && return 1

    local tmpfile
    tmpfile=$(mktemp /tmp/logmaster_email_XXXXXX.eml)

    cat > "$tmpfile" <<EMAILEOF
From: LogMaster <${from_email}>
To: ${to_email}
Subject: ${subject}
MIME-Version: 1.0
Content-Type: text/html; charset=UTF-8

${body_html}
EMAILEOF

    local tls_flag=""
    [ "$use_tls" = "1" ] && tls_flag="--ssl-reqd"

    local curl_auth=""
    if [ -n "$username" ] && [ -n "$password" ]; then
        curl_auth="--user ${username}:${password}"
    fi

    local proto="smtp"
    [ "$use_tls" = "1" ] && [ "$smtp_port" = "465" ] && proto="smtps"

    curl --silent --max-time 30 \
        --url "${proto}://${smtp_server}:${smtp_port}" \
        $tls_flag \
        --mail-from "$from_email" \
        --mail-rcpt "$to_email" \
        $curl_auth \
        -T "$tmpfile" 2>/dev/null

    local rc=$?
    rm -f "$tmpfile"

    if [ $rc -eq 0 ]; then
        log_info "Correo enviado: $subject -> $to_email"
    else
        log_error "Error enviando correo (rc=$rc): $subject"
    fi

    return $rc
}

render_template() {
    local template_file="$1"
    shift

    if [ ! -f "$template_file" ]; then
        log_error "Template no encontrado: $template_file"
        return 1
    fi

    local content
    content=$(cat "$template_file")

    while [ $# -ge 2 ]; do
        local var="$1" val="$2"
        content="${content//\{\{${var}\}\}/${val}}"
        shift 2
    done

    echo "$content"
}

notify_result() {
    local status="$1" source_path="$2" dest_label="$3"
    local files_ok="$4" files_fail="$5" message="$6" details="$7"

    local row
    row=$(db_query "SELECT notify_success, notify_error FROM email_config WHERE id=1")
    [ -z "$row" ] && return

    local notify_success notify_error
    IFS='|' read -r notify_success notify_error <<< "$row"

    local should_notify=0
    if [ "$status" = "success" ] && [ "$notify_success" = "1" ]; then
        should_notify=1
    elif [ "$status" = "error" ] || [ "$status" = "partial" ]; then
        [ "$notify_error" = "1" ] && should_notify=1
    fi

    [ "$should_notify" -eq 0 ] && return

    local template subject timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [ "$status" = "success" ]; then
        template="${LOGMASTER_TEMPLATES}/success.html"
        subject="[LogMaster] Transferencia exitosa - ${source_path}"
    else
        template="${LOGMASTER_TEMPLATES}/error.html"
        subject="[LogMaster] ERROR en transferencia - ${source_path}"
    fi

    local body
    body=$(render_template "$template" \
        "TIMESTAMP" "$timestamp" \
        "SOURCE_PATH" "$source_path" \
        "DEST_TARGET" "$dest_label" \
        "FILES_OK" "$files_ok" \
        "FILES_FAIL" "$files_fail" \
        "STATUS" "$status" \
        "MESSAGE" "$message" \
        "DETAILS" "$details" \
        "HOSTNAME" "$(hostname)")

    [ -n "$body" ] && send_email "$subject" "$body"
}

# ============================================================
# Utilidades de UI
# ============================================================

print_header() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║          LOGMASTER v1.1.0                    ║"
    echo "║   Sistema de Transferencia de Archivos       ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_separator() {
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────${NC}"
}

print_ok()    { echo -e " ${GREEN}✓${NC} $1"; }
print_err()   { echo -e " ${RED}✗${NC} $1"; }
print_warn()  { echo -e " ${YELLOW}!${NC} $1"; }
print_info()  { echo -e " ${CYAN}→${NC} $1"; }

pause() {
    echo ""
    read -rp "  Presione ENTER para continuar..." _
}

confirm() {
    local msg="${1:-¿Está seguro?}"
    echo -en " ${YELLOW}${msg} [s/N]:${NC} "
    read -r resp
    [[ "$resp" =~ ^[sS]$ ]]
}

read_input() {
    local prompt="$1" var_name="$2" default="$3"
    if [ -n "$default" ]; then
        echo -en "  ${prompt} [${default}]: "
    else
        echo -en "  ${prompt}: "
    fi
    read -r input
    input="${input:-$default}"
    eval "$var_name='$input'"
}

read_password() {
    local prompt="$1" var_name="$2"
    echo -en "  ${prompt}: "
    read -rs input
    echo ""
    eval "$var_name='$input'"
}

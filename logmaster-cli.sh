#!/bin/bash
# ============================================================
# LogMaster v2.0 - Frontend de Consola Interactivo
# Arquitectura Master/Slave con sincronización SSH
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/functions.sh"
source "${SCRIPT_DIR}/lib/sync.sh"

db_init

# ============================================================
# MENÚ PRINCIPAL
# ============================================================

main_menu() {
    while true; do
        clear
        print_header
        echo -e "  ${BOLD}MENÚ PRINCIPAL${NC}"
        print_separator
        echo ""
        # Mostrar rol del nodo
        local current_role current_name
        current_role=$(get_node_role)
        current_name=$(db_get "SELECT node_name FROM node_config WHERE id=1")
        local role_label
        case "$current_role" in
            master)     role_label="${GREEN}MASTER${NC}" ;;
            slave)      role_label="${YELLOW}SLAVE${NC}" ;;
            standalone) role_label="${CYAN}STANDALONE${NC}" ;;
        esac
        echo -e "  Nodo: ${WHITE}${current_name:-$(hostname)}${NC}  Rol: ${role_label}"
        echo ""

        echo "   1) Directorios fuente y destinos"
        echo "   2) Catálogo Samba"
        echo "   3) Filtros de archivos"
        echo "   4) Programación"
        echo "   5) Correo electrónico"
        echo "   6) Historial de ejecuciones"
        echo "   7) Ejecutar transferencia manual"
        echo "   8) Cron (instalar/desinstalar)"
        echo "   9) Estado del sistema"
        echo -e "  ${MAGENTA}10) Red y Sincronización${NC}"
        echo "   0) Salir"
        echo ""
        echo -en "  ${CYAN}Opción:${NC} "
        read -r opt
        case "$opt" in
            1)  directories_menu ;;
            2)  samba_menu ;;
            3)  filters_menu ;;
            4)  schedules_menu ;;
            5)  email_menu ;;
            6)  log_menu ;;
            7)  manual_exec_menu ;;
            8)  cron_menu ;;
            9)  status_menu ;;
            10) network_menu ;;
            0)  echo ""; print_ok "Hasta luego."; exit 0 ;;
            *)  print_err "Opción inválida" ; sleep 1 ;;
        esac
    done
}

# ============================================================
# Vista de árbol: directorios con sus destinos y filtros
# ============================================================

show_directories_tree() {
    local dirs
    dirs=$(db_query "SELECT id, source_path, active FROM directories ORDER BY id")

    if [ -z "$dirs" ]; then
        print_warn "No hay directorios configurados"
        return
    fi

    while IFS='|' read -r dir_id dir_path dir_active; do
        local estado_color estado_txt
        if [ "$dir_active" = "1" ]; then
            estado_color="$GREEN"; estado_txt="Activo"
        else
            estado_color="$RED"; estado_txt="Inactivo"
        fi

        echo -e "  ${WHITE}${BOLD}[${dir_id}]${NC} ${WHITE}${dir_path}${NC}  ${estado_color}${estado_txt}${NC}"

        # Filtros del directorio
        local filters
        filters=$(db_query "SELECT pattern, active FROM filters WHERE directory_id=$dir_id ORDER BY id")
        if [ -n "$filters" ]; then
            local filter_list=""
            while IFS='|' read -r fpat factive; do
                if [ "$factive" = "1" ]; then
                    filter_list="${filter_list} ${CYAN}${fpat}${NC}"
                else
                    filter_list="${filter_list} ${DIM}${fpat}${NC}"
                fi
            done <<< "$filters"
            echo -e "  │  Filtros:${filter_list}"
        fi

        # Destinos del directorio
        local dests
        dests=$(db_query "
            SELECT dd.id, dd.dest_type, dd.action, dd.active, dd.remote_subdir,
                   COALESCE(dd.local_path,''),
                   COALESCE(st.name,''), COALESCE(st.server,''),
                   COALESCE(st.share,''), COALESCE(st.remote_path,'')
            FROM directory_destinations dd
            LEFT JOIN samba_targets st ON st.id = dd.samba_target_id
            WHERE dd.directory_id = $dir_id
            ORDER BY dd.id
        ")

        if [ -n "$dests" ]; then
            local dest_count=0 dest_total=0
            # Contar destinos
            while IFS= read -r _; do dest_total=$((dest_total + 1)); done <<< "$dests"

            while IFS='|' read -r did dtype daction dactive dsubdir dlpath sname sserver sshare srpath; do
                dest_count=$((dest_count + 1))
                local connector="├──"
                [ "$dest_count" -eq "$dest_total" ] && connector="└──"

                local dest_estado
                if [ "$dactive" = "1" ]; then
                    dest_estado="${GREEN}●${NC}"
                else
                    dest_estado="${RED}○${NC}"
                fi

                local action_txt
                [ "$daction" = "move" ] && action_txt="${YELLOW}mover${NC}" || action_txt="${GREEN}copiar${NC}"

                if [ "$dtype" = "samba" ]; then
                    local full_rpath="${srpath%/}"
                    [ -n "$dsubdir" ] && full_rpath="${full_rpath}/${dsubdir}"
                    echo -e "  ${connector} ${dest_estado} ${MAGENTA}[Samba]${NC} #${did} ${sname} → //${sserver}/${sshare}${full_rpath}  (${action_txt})"
                else
                    local full_lpath="$dlpath"
                    [ -n "$dsubdir" ] && full_lpath="${full_lpath}/${dsubdir}"
                    echo -e "  ${connector} ${dest_estado} ${BLUE}[Local]${NC} #${did} → ${full_lpath}  (${action_txt})"
                fi
            done <<< "$dests"
        else
            echo -e "  └── ${YELLOW}(sin destinos configurados)${NC}"
        fi

        # Schedule
        local sched
        sched=$(db_query "SELECT schedule_type, interval_minutes, run_at_time, next_run, active FROM schedules WHERE directory_id=$dir_id LIMIT 1")
        if [ -n "$sched" ]; then
            IFS='|' read -r stype sint srun snext sact <<< "$sched"
            local prog_txt display_time
            [[ "$srun" =~ ^[0-9]{4}$ ]] && display_time="${srun:0:2}:${srun:2:2}" || display_time="$srun"
            case "$stype" in
                interval) prog_txt="Cada ${sint}min" ;;
                daily)    prog_txt="Diario ${display_time}" ;;
                weekly)   prog_txt="Semanal ${display_time}" ;;
            esac
            local sact_icon
            [ "$sact" = "1" ] && sact_icon="${GREEN}⏱${NC}" || sact_icon="${RED}⏱${NC}"
            echo -e "  ${DIM}     ${sact_icon} ${prog_txt} → próx: ${snext:-pendiente}${NC}"
        fi

        echo ""
    done <<< "$dirs"
}

# ============================================================
# DIRECTORIOS FUENTE Y DESTINOS
# ============================================================

directories_menu() {
    while true; do
        clear
        print_header
        echo -e "  ${BOLD}DIRECTORIOS FUENTE Y DESTINOS${NC}"
        print_separator
        echo ""

        show_directories_tree

        print_separator
        echo ""
        echo "  a) Agregar directorios fuente (varios a la vez)"
        echo "  d) Agregar destino a un directorio"
        echo "  e) Editar directorio"
        echo "  r) Eliminar directorio"
        echo "  x) Eliminar un destino"
        echo "  t) Activar/Desactivar destino"
        echo "  v) Volver"
        echo ""
        echo -en "  ${CYAN}Opción:${NC} "
        read -r opt
        case "$opt" in
            a) directories_add ;;
            d) destinations_add ;;
            e) directories_edit ;;
            r) directories_delete ;;
            x) destinations_delete ;;
            t) destinations_toggle ;;
            v) return ;;
        esac
    done
}

directories_add() {
    echo ""
    echo -e "  ${BOLD}AGREGAR DIRECTORIOS FUENTE${NC}"
    print_separator
    echo ""
    echo -e "  ${CYAN}Ingrese las rutas separadas por espacio${NC}"
    echo -e "  ${CYAN}Ej: /var/www/croms/logs /store/logs /opt/app/data${NC}"
    echo ""
    echo -en "  Rutas: "
    read -r paths_input

    [ -z "$paths_input" ] && { print_err "Debe ingresar al menos una ruta"; pause; return; }

    echo ""
    local count=0
    for path in $paths_input; do
        path="${path%/}"

        if [ ! -d "$path" ]; then
            print_warn "Directorio no existe: $path (se agregará de todas formas)"
        fi

        db_exec "INSERT INTO directories (source_path) VALUES ('$path')"
        local new_id
        new_id=$(db_get "SELECT last_insert_rowid()")

        print_ok "Directorio [ID=$new_id]: $path"
        count=$((count + 1))

        # Preguntar por filtros
        echo ""
        echo -e "  ${CYAN}¿Filtros para ${path}?${NC}"
        echo -e "  ${CYAN}Patrones separados por espacio (ej: *.log log-2024* *.pdf)${NC}"
        echo -e "  ${CYAN}(ENTER = sin filtro, todos los archivos)${NC}"
        echo -en "  Filtros: "
        read -r filters_input

        if [ -n "$filters_input" ]; then
            for pattern in $filters_input; do
                db_exec "INSERT INTO filters (directory_id, pattern) VALUES ($new_id, '$pattern')"
                print_info "  Filtro: $pattern"
            done
        fi

        # Preguntar si agregar destinos ahora
        echo ""
        if confirm "¿Agregar destinos para este directorio ahora?"; then
            _add_destinations_for "$new_id" "$path"
        fi
    done

    echo ""
    print_ok "$count directorio(s) agregado(s)"

    # Programación automática
    echo ""
    if confirm "¿Crear programación automática para los directorios nuevos?"; then
        echo ""
        echo "  Tipo: 1) Cada N minutos  2) Diaria  3) Semanal"
        echo -en "  Opción [1]: "
        read -r sched_opt

        local dir_ids
        dir_ids=$(db_query "SELECT id FROM directories ORDER BY id DESC LIMIT $count")

        case "$sched_opt" in
            2)
                read_time_hhmm run_time "0800"
                while IFS= read -r did; do
                    [ -z "$did" ] && continue
                    local next
                    next=$(calculate_next_run "daily" "0" "$run_time" "")
                    db_exec "INSERT INTO schedules (directory_id, schedule_type, run_at_time, next_run)
                             VALUES ($did, 'daily', '$run_time', '$next')"
                done <<< "$dir_ids"
                print_ok "Programación diaria a las $run_time"
                ;;
            3)
                read_time_hhmm run_time "0800"
                echo "  Días (1=Lun 2=Mar 3=Mié 4=Jue 5=Vie 6=Sáb 7=Dom)"
                read_input "Días separados por coma" days "1,2,3,4,5"
                while IFS= read -r did; do
                    [ -z "$did" ] && continue
                    local next
                    next=$(calculate_next_run "weekly" "0" "$run_time" "$days")
                    db_exec "INSERT INTO schedules (directory_id, schedule_type, run_at_time, days_of_week, next_run)
                             VALUES ($did, 'weekly', '$run_time', '$days', '$next')"
                done <<< "$dir_ids"
                print_ok "Programación semanal creada"
                ;;
            *)
                read_input "Intervalo en minutos" interval "60"
                while IFS= read -r did; do
                    [ -z "$did" ] && continue
                    local next
                    next=$(calculate_next_run "interval" "$interval" "" "")
                    db_exec "INSERT INTO schedules (directory_id, schedule_type, interval_minutes, next_run)
                             VALUES ($did, 'interval', $interval, '$next')"
                done <<< "$dir_ids"
                print_ok "Programación cada $interval minutos"
                ;;
        esac
    fi

    pause
}

# Función interna para agregar destinos a un directorio
_add_destinations_for() {
    local dir_id="$1" dir_path="$2"
    local adding=1

    while [ "$adding" -eq 1 ]; do
        echo ""
        echo -e "  ${BOLD}Agregar destino para: $dir_path${NC}"
        echo "  Tipo de destino:"
        echo "    1) Samba (servidor remoto)"
        echo "    2) Local (directorio en este servidor)"
        echo -en "  Opción: "
        read -r dtype_opt

        case "$dtype_opt" in
            1)
                # Mostrar catálogo Samba
                local targets
                targets=$(db_query "SELECT id, name, server, share FROM samba_targets WHERE active=1")
                if [ -z "$targets" ]; then
                    print_err "No hay destinos Samba en el catálogo. Agréguelos primero (menú 2)"
                    return
                fi

                echo ""
                echo -e "  ${BOLD}Catálogo Samba:${NC}"
                while IFS='|' read -r tid tname tserver tshare; do
                    echo "    [$tid] $tname (//$tserver/$tshare)"
                done <<< "$targets"
                echo ""

                read_input "ID del destino Samba" samba_id ""
                [ -z "$samba_id" ] && continue

                local check
                check=$(db_get "SELECT id FROM samba_targets WHERE id=$samba_id AND active=1")
                [ -z "$check" ] && { print_err "ID no válido"; continue; }

                read_input "Subdirectorio remoto adicional (opcional)" subdir ""

                echo "  Acción: 1) copy  2) move"
                echo -en "  Opción [1]: "
                read -r act_opt
                local action="copy"
                [ "$act_opt" = "2" ] && action="move"

                db_exec "INSERT INTO directory_destinations (directory_id, dest_type, samba_target_id, remote_subdir, action)
                         VALUES ($dir_id, 'samba', $samba_id, '$subdir', '$action')"

                local sname
                sname=$(db_get "SELECT name FROM samba_targets WHERE id=$samba_id")
                print_ok "Destino Samba '$sname' agregado ($action)"
                ;;
            2)
                read_input "Ruta del directorio destino local" local_dest ""
                [ -z "$local_dest" ] && continue

                read_input "Subdirectorio adicional (opcional)" subdir ""

                echo "  Acción: 1) copy  2) move"
                echo -en "  Opción [1]: "
                read -r act_opt
                local action="copy"
                [ "$act_opt" = "2" ] && action="move"

                db_exec "INSERT INTO directory_destinations (directory_id, dest_type, local_path, remote_subdir, action)
                         VALUES ($dir_id, 'local', '$local_dest', '$subdir', '$action')"

                print_ok "Destino local '$local_dest' agregado ($action)"
                ;;
            *)
                print_err "Opción inválida"
                continue
                ;;
        esac

        echo ""
        if ! confirm "¿Agregar otro destino a este directorio?"; then
            adding=0
        fi
    done
}

destinations_add() {
    echo ""

    local dirs
    dirs=$(db_query "SELECT id, source_path FROM directories ORDER BY id")
    if [ -z "$dirs" ]; then
        print_err "Primero agregue directorios fuente"
        pause
        return
    fi

    echo -e "  ${BOLD}Directorios disponibles:${NC}"
    while IFS='|' read -r did dpath; do
        echo "    [$did] $dpath"
    done <<< "$dirs"
    echo ""

    read_input "ID del directorio" dir_id ""
    [ -z "$dir_id" ] && { pause; return; }

    local path
    path=$(db_get "SELECT source_path FROM directories WHERE id=$dir_id")
    [ -z "$path" ] && { print_err "ID no encontrado"; pause; return; }

    _add_destinations_for "$dir_id" "$path"
    pause
}

directories_edit() {
    echo ""
    read_input "ID del directorio a editar" edit_id ""
    [ -z "$edit_id" ] && return

    local row
    row=$(db_query "SELECT source_path, active FROM directories WHERE id=$edit_id")
    [ -z "$row" ] && { print_err "ID no encontrado"; pause; return; }

    IFS='|' read -r old_path old_active <<< "$row"

    echo ""
    echo -e "  ${BOLD}Editando directorio #$edit_id${NC} (ENTER para mantener)"
    print_separator

    local path active
    read_input "Ruta [$old_path]" path "$old_path"
    read_input "Activo (1/0) [$old_active]" active "$old_active"

    db_exec "UPDATE directories SET source_path='$path', active=$active WHERE id=$edit_id"

    print_ok "Directorio actualizado"
    pause
}

directories_delete() {
    echo ""
    read_input "ID del directorio a eliminar" del_id ""
    [ -z "$del_id" ] && return

    local path
    path=$(db_get "SELECT source_path FROM directories WHERE id=$del_id")
    [ -z "$path" ] && { print_err "ID no encontrado"; pause; return; }

    if confirm "¿Eliminar '$path' con todos sus destinos, filtros y programaciones?"; then
        db_exec "DELETE FROM directory_destinations WHERE directory_id=$del_id"
        db_exec "DELETE FROM schedules WHERE directory_id=$del_id"
        db_exec "DELETE FROM filters WHERE directory_id=$del_id"
        db_exec "DELETE FROM directories WHERE id=$del_id"
        print_ok "Directorio y relaciones eliminados"
    fi
    pause
}

destinations_delete() {
    echo ""
    read_input "ID del destino a eliminar (número después de #)" dest_id ""
    [ -z "$dest_id" ] && return

    local label
    label=$(get_dest_label "$dest_id")

    if confirm "¿Eliminar destino: $label?"; then
        db_exec "DELETE FROM directory_destinations WHERE id=$dest_id"
        print_ok "Destino eliminado"
    fi
    pause
}

destinations_toggle() {
    echo ""
    read_input "ID del destino a activar/desactivar" dest_id ""
    [ -z "$dest_id" ] && return

    local current
    current=$(db_get "SELECT active FROM directory_destinations WHERE id=$dest_id")
    [ -z "$current" ] && { print_err "ID no encontrado"; pause; return; }

    local new_val
    [ "$current" = "1" ] && new_val=0 || new_val=1

    db_exec "UPDATE directory_destinations SET active=$new_val WHERE id=$dest_id"

    local state_txt
    [ "$new_val" = "1" ] && state_txt="activado" || state_txt="desactivado"
    print_ok "Destino #$dest_id $state_txt"
    pause
}

# ============================================================
# CATÁLOGO SAMBA
# ============================================================

samba_menu() {
    while true; do
        clear
        print_header
        echo -e "  ${BOLD}CATÁLOGO DE DESTINOS SAMBA${NC}"
        print_separator
        echo ""

        local targets
        targets=$(db_query "SELECT id, name, server, share, remote_path, active FROM samba_targets ORDER BY id")

        if [ -n "$targets" ]; then
            printf "  ${WHITE}%-4s %-20s %-20s %-15s %-15s %-8s${NC}\n" "ID" "Nombre" "Servidor" "Recurso" "Ruta" "Estado"
            print_separator
            while IFS='|' read -r id name server share rpath active; do
                local estado
                [ "$active" = "1" ] && estado="${GREEN}Activo${NC}" || estado="${RED}Inactivo${NC}"
                printf "  %-4s %-20s %-20s %-15s %-15s ${estado}\n" "$id" "$name" "$server" "$share" "$rpath"
            done <<< "$targets"
        else
            print_warn "No hay destinos Samba en el catálogo"
        fi

        echo ""
        echo "  a) Agregar destino Samba"
        echo "  e) Editar destino"
        echo "  t) Probar conexión"
        echo "  d) Eliminar destino"
        echo "  v) Volver"
        echo ""
        echo -en "  ${CYAN}Opción:${NC} "
        read -r opt
        case "$opt" in
            a) samba_add ;;
            e) samba_edit ;;
            t) samba_test ;;
            d) samba_delete ;;
            v) return ;;
        esac
    done
}

samba_add() {
    echo ""
    echo -e "  ${BOLD}Nuevo destino Samba${NC}"
    print_separator

    local name server share rpath user pass domain port

    read_input "Nombre identificador" name ""
    [ -z "$name" ] && { print_err "Nombre requerido"; pause; return; }

    read_input "Servidor (IP o hostname)" server ""
    [ -z "$server" ] && { print_err "Servidor requerido"; pause; return; }

    read_input "Nombre del recurso compartido" share ""
    [ -z "$share" ] && { print_err "Recurso requerido"; pause; return; }

    read_input "Ruta remota destino" rpath "/"
    read_input "Usuario" user ""
    read_password "Contraseña" pass
    read_input "Dominio (opcional)" domain ""
    read_input "Puerto" port "445"

    db_exec "INSERT INTO samba_targets (name, server, share, remote_path, username, password, domain, port)
             VALUES ('$name', '$server', '$share', '$rpath', '$user', '$pass', '$domain', $port)"

    print_ok "Destino Samba '$name' agregado al catálogo"
    pause
}

samba_edit() {
    echo ""
    read_input "ID del destino a editar" edit_id ""
    [ -z "$edit_id" ] && return

    local row
    row=$(db_query "SELECT name, server, share, remote_path, username, password, domain, port, active FROM samba_targets WHERE id=$edit_id")
    [ -z "$row" ] && { print_err "ID no encontrado"; pause; return; }

    IFS='|' read -r old_name old_server old_share old_rpath old_user old_pass old_domain old_port old_active <<< "$row"

    echo ""
    echo -e "  ${BOLD}Editando: $old_name${NC} (ENTER para mantener actual)"
    print_separator

    local name server share rpath user pass domain port active
    read_input "Nombre [$old_name]" name "$old_name"
    read_input "Servidor [$old_server]" server "$old_server"
    read_input "Recurso [$old_share]" share "$old_share"
    read_input "Ruta remota [$old_rpath]" rpath "$old_rpath"
    read_input "Usuario [$old_user]" user "$old_user"

    echo -en "  Contraseña (ENTER para mantener): "
    read -rs pass
    echo ""
    pass="${pass:-$old_pass}"

    read_input "Dominio [$old_domain]" domain "$old_domain"
    read_input "Puerto [$old_port]" port "$old_port"
    read_input "Activo (1/0) [$old_active]" active "$old_active"

    db_exec "UPDATE samba_targets SET name='$name', server='$server', share='$share',
             remote_path='$rpath', username='$user', password='$pass', domain='$domain',
             port=$port, active=$active WHERE id=$edit_id"

    print_ok "Destino actualizado"
    pause
}

samba_test() {
    echo ""
    read_input "ID del destino a probar" test_id ""
    [ -z "$test_id" ] && return

    local row
    row=$(db_query "SELECT name, server, share, username, password, domain, port FROM samba_targets WHERE id=$test_id")
    [ -z "$row" ] && { print_err "ID no encontrado"; pause; return; }

    IFS='|' read -r name server share user pass domain port <<< "$row"

    print_info "Probando conexión a //${server}/${share}..."

    if samba_test_connection "$server" "$share" "$user" "$pass" "$domain" "$port"; then
        print_ok "Conexión exitosa a '$name'"
    else
        print_err "No se pudo conectar a '$name'"
    fi
    pause
}

samba_delete() {
    echo ""
    read_input "ID del destino a eliminar" del_id ""
    [ -z "$del_id" ] && return

    local name
    name=$(db_get "SELECT name FROM samba_targets WHERE id=$del_id")
    [ -z "$name" ] && { print_err "ID no encontrado"; pause; return; }

    local in_use
    in_use=$(db_get "SELECT COUNT(*) FROM directory_destinations WHERE samba_target_id=$del_id")

    if [ "$in_use" -gt 0 ]; then
        print_warn "Este destino está asignado a $in_use directorio(s):"
        db_query "SELECT d.source_path FROM directory_destinations dd
                  JOIN directories d ON d.id = dd.directory_id
                  WHERE dd.samba_target_id=$del_id" | while read -r p; do
            echo "    - $p"
        done
        echo ""
        if ! confirm "¿Eliminar en cascada (también se borrarán esos destinos)?"; then
            print_info "Operación cancelada"
            pause
            return
        fi
        db_exec "DELETE FROM directory_destinations WHERE samba_target_id=$del_id"
    else
        if ! confirm "¿Eliminar destino Samba '$name'?"; then
            pause
            return
        fi
    fi

    db_exec "DELETE FROM samba_targets WHERE id=$del_id"
    print_ok "Destino '$name' eliminado del catálogo"
    pause
}

# ============================================================
# FILTROS DE ARCHIVOS
# ============================================================

filters_menu() {
    while true; do
        clear
        print_header
        echo -e "  ${BOLD}FILTROS DE ARCHIVOS${NC}"
        print_separator
        echo ""

        local filters
        filters=$(db_query "
            SELECT f.id, d.source_path, f.pattern, f.active
            FROM filters f
            JOIN directories d ON d.id = f.directory_id
            ORDER BY d.id, f.id
        ")

        if [ -n "$filters" ]; then
            printf "  ${WHITE}%-4s %-35s %-25s %-8s${NC}\n" "ID" "Directorio" "Patrón" "Estado"
            print_separator
            while IFS='|' read -r id path pattern active; do
                local estado
                [ "$active" = "1" ] && estado="${GREEN}Activo${NC}" || estado="${RED}Inactivo${NC}"
                printf "  %-4s %-35s %-25s ${estado}\n" "$id" "${path:0:35}" "$pattern"
            done <<< "$filters"
        else
            print_warn "No hay filtros configurados"
        fi

        echo ""
        echo "  a) Agregar filtros a un directorio"
        echo "  d) Eliminar filtro"
        echo "  p) Previsualizar archivos coincidentes"
        echo "  v) Volver"
        echo ""
        echo -en "  ${CYAN}Opción:${NC} "
        read -r opt
        case "$opt" in
            a) filters_add ;;
            d) filters_delete ;;
            p) filters_preview ;;
            v) return ;;
        esac
    done
}

filters_add() {
    echo ""

    local dirs
    dirs=$(db_query "SELECT id, source_path FROM directories ORDER BY id")
    if [ -z "$dirs" ]; then
        print_err "Primero agregue directorios"
        pause
        return
    fi

    echo -e "  ${BOLD}Directorios disponibles:${NC}"
    while IFS='|' read -r did dpath; do
        echo "    [$did] $dpath"
    done <<< "$dirs"
    echo ""

    read_input "ID del directorio" dir_id ""
    [ -z "$dir_id" ] && return

    local check
    check=$(db_get "SELECT id FROM directories WHERE id=$dir_id")
    [ -z "$check" ] && { print_err "ID no válido"; pause; return; }

    echo ""
    echo -e "  ${BOLD}Ingrese patrones de filtro separados por espacio${NC}"
    echo -e "  ${CYAN}Ejemplos: *.log *.pdf log-2024* reporte*.xlsx${NC}"
    echo ""
    echo -en "  Patrones: "
    read -r patterns_input

    [ -z "$patterns_input" ] && { print_err "Ingrese al menos un patrón"; pause; return; }

    for pattern in $patterns_input; do
        db_exec "INSERT INTO filters (directory_id, pattern) VALUES ($dir_id, '$pattern')"
        print_ok "Filtro: $pattern"
    done
    pause
}

filters_delete() {
    echo ""
    read_input "ID del filtro a eliminar" del_id ""
    [ -z "$del_id" ] && return

    local pattern
    pattern=$(db_get "SELECT pattern FROM filters WHERE id=$del_id")
    [ -z "$pattern" ] && { print_err "ID no encontrado"; pause; return; }

    if confirm "¿Eliminar filtro '$pattern'?"; then
        db_exec "DELETE FROM filters WHERE id=$del_id"
        print_ok "Filtro eliminado"
    fi
    pause
}

filters_preview() {
    echo ""
    read_input "ID del directorio a previsualizar" dir_id ""
    [ -z "$dir_id" ] && return

    local path
    path=$(db_get "SELECT source_path FROM directories WHERE id=$dir_id")
    [ -z "$path" ] && { print_err "ID no encontrado"; pause; return; }

    echo ""
    echo -e "  ${BOLD}Archivos coincidentes en: $path${NC}"
    print_separator

    local files
    files=$(find_matching_files "$path" "$dir_id")

    if [ -n "$files" ]; then
        local count=0
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            local size mod
            size=$(stat -c %s "$f" 2>/dev/null || echo "?")
            mod=$(stat -c %y "$f" 2>/dev/null | cut -d. -f1)
            printf "  %-40s %10s  %s\n" "$(basename "$f")" "${size}B" "$mod"
            count=$((count + 1))
        done <<< "$files"
        echo ""
        print_info "Total: $count archivo(s)"
    else
        print_warn "No se encontraron archivos"
    fi
    pause
}

# ============================================================
# PROGRAMACIÓN
# ============================================================

schedules_menu() {
    while true; do
        clear
        print_header
        echo -e "  ${BOLD}PROGRAMACIÓN DE EJECUCIONES${NC}"
        print_separator
        echo ""

        local scheds
        scheds=$(db_query "
            SELECT s.id, d.source_path, s.schedule_type, s.interval_minutes,
                   s.run_at_time, s.days_of_week, s.last_run, s.next_run, s.active
            FROM schedules s
            JOIN directories d ON d.id = s.directory_id
            ORDER BY s.id
        ")

        if [ -n "$scheds" ]; then
            printf "  ${WHITE}%-4s %-28s %-10s %-18s %-20s %-6s${NC}\n" "ID" "Directorio" "Tipo" "Programación" "Próxima ejecución" "Estado"
            print_separator
            while IFS='|' read -r sid spath stype interval run_at days last_run next_run active; do
                local estado prog display_time
                [ "$active" = "1" ] && estado="${GREEN}Act${NC}" || estado="${RED}Ina${NC}"
                [[ "$run_at" =~ ^[0-9]{4}$ ]] && display_time="${run_at:0:2}:${run_at:2:2}" || display_time="$run_at"

                case "$stype" in
                    interval) prog="Cada ${interval}min" ;;
                    daily)    prog="Diario ${display_time}" ;;
                    weekly)   prog="Sem D:${days} ${display_time}" ;;
                esac

                printf "  %-4s %-28s %-10s %-18s %-20s ${estado}\n" "$sid" "${spath:0:28}" "$stype" "$prog" "${next_run:--}"

                local dests
                dests=$(db_query "
                    SELECT dd.dest_type, dd.action, dd.local_path, dd.remote_subdir,
                           st.name, st.server, st.share
                    FROM directory_destinations dd
                    JOIN directories d ON d.id = dd.directory_id
                    LEFT JOIN samba_targets st ON st.id = dd.samba_target_id
                    WHERE d.source_path='${spath}' AND dd.active=1
                ")
                if [ -n "$dests" ]; then
                    while IFS='|' read -r dtype action lpath rsubdir stname server share; do
                        if [ "$dtype" = "samba" ]; then
                            printf "       ${DIM}└── [Samba] %s → //%s/%s%s (%s)${NC}\n" \
                                "$stname" "$server" "$share" "${rsubdir:+/$rsubdir}" "$action"
                        else
                            printf "       ${DIM}└── [Local] %s%s (%s)${NC}\n" \
                                "$lpath" "${rsubdir:+/$rsubdir}" "$action"
                        fi
                    done <<< "$dests"
                else
                    printf "       ${DIM}└── (sin destinos configurados)${NC}\n"
                fi
            done <<< "$scheds"
        else
            print_warn "No hay programaciones configuradas"
        fi

        echo ""
        echo "  a) Agregar programación"
        echo "  e) Editar programación"
        echo "  d) Eliminar programación"
        echo "  v) Volver"
        echo ""
        echo -en "  ${CYAN}Opción:${NC} "
        read -r opt
        case "$opt" in
            a) schedules_add ;;
            e) schedules_edit ;;
            d) schedules_delete ;;
            v) return ;;
        esac
    done
}

schedules_add() {
    echo ""

    local dirs
    dirs=$(db_query "SELECT id, source_path FROM directories WHERE active=1 ORDER BY id")
    if [ -z "$dirs" ]; then
        print_err "Primero agregue directorios"
        pause
        return
    fi

    echo -e "  ${BOLD}Directorios disponibles:${NC}"
    while IFS='|' read -r did dpath; do
        echo "    [$did] $dpath"
    done <<< "$dirs"
    echo ""

    read_input "ID del directorio" dir_id ""
    [ -z "$dir_id" ] && return

    echo ""
    echo "  Tipo: 1) Cada N minutos  2) Diaria  3) Semanal"
    echo -en "  Opción: "
    read -r stype_opt

    local stype interval run_at days next

    case "$stype_opt" in
        2)
            stype="daily"
            read_time_hhmm run_at "0800"
            interval=0
            days="1,2,3,4,5,6,7"
            next=$(calculate_next_run "daily" "0" "$run_at" "")
            ;;
        3)
            stype="weekly"
            read_time_hhmm run_at "0800"
            echo "  Días: 1=Lun 2=Mar 3=Mié 4=Jue 5=Vie 6=Sáb 7=Dom"
            read_input "Días separados por coma" days "1,2,3,4,5"
            interval=0
            next=$(calculate_next_run "weekly" "0" "$run_at" "$days")
            ;;
        *)
            stype="interval"
            read_input "Intervalo en minutos" interval "60"
            run_at=""
            days="1,2,3,4,5,6,7"
            next=$(calculate_next_run "interval" "$interval" "" "")
            ;;
    esac

    db_exec "INSERT INTO schedules (directory_id, schedule_type, interval_minutes, run_at_time, days_of_week, next_run)
             VALUES ($dir_id, '$stype', ${interval:-0}, '${run_at}', '$days', '$next')"

    print_ok "Programación creada (próxima: $next)"
    pause
}

schedules_edit() {
    echo ""
    read_input "ID de la programación a editar" edit_id ""
    [ -z "$edit_id" ] && return

    local row
    row=$(db_query "SELECT schedule_type, interval_minutes, run_at_time, days_of_week, active FROM schedules WHERE id=$edit_id")
    [ -z "$row" ] && { print_err "ID no encontrado"; pause; return; }

    IFS='|' read -r old_stype old_interval old_run_at old_days old_active <<< "$row"

    echo ""
    echo -e "  ${BOLD}Editando programación #$edit_id${NC}"
    print_separator

    local active
    read_input "Activo (1/0) [$old_active]" active "$old_active"

    echo "  Tipo: 1)interval 2)daily 3)weekly (actual: $old_stype)"
    echo -en "  Opción [actual]: "
    read -r stype_opt

    local stype interval run_at days next

    case "$stype_opt" in
        1)
            stype="interval"
            read_input "Intervalo en minutos [$old_interval]" interval "$old_interval"
            run_at=""; days="1,2,3,4,5,6,7"
            ;;
        2)
            stype="daily"
            read_time_hhmm run_at "${old_run_at//:/}"
            interval=0; days="1,2,3,4,5,6,7"
            ;;
        3)
            stype="weekly"
            read_time_hhmm run_at "${old_run_at//:/}"
            read_input "Días [$old_days]" days "$old_days"
            interval=0
            ;;
        *)
            stype="$old_stype"; interval="$old_interval"
            run_at="$old_run_at"; days="$old_days"
            ;;
    esac

    next=$(calculate_next_run "$stype" "${interval:-0}" "$run_at" "$days")

    db_exec "UPDATE schedules SET schedule_type='$stype', interval_minutes=${interval:-0},
             run_at_time='$run_at', days_of_week='$days', next_run='$next', active=$active
             WHERE id=$edit_id"

    print_ok "Programación actualizada (próxima: $next)"
    pause
}

schedules_delete() {
    echo ""
    read_input "ID de la programación a eliminar" del_id ""
    [ -z "$del_id" ] && return

    if confirm "¿Eliminar programación #$del_id?"; then
        db_exec "DELETE FROM schedules WHERE id=$del_id"
        print_ok "Programación eliminada"
    fi
    pause
}

# ============================================================
# CORREO ELECTRÓNICO
# ============================================================

email_menu() {
    while true; do
        clear
        print_header
        echo -e "  ${BOLD}CONFIGURACIÓN DE CORREO${NC}"
        print_separator
        echo ""

        local row
        row=$(db_query "SELECT smtp_server, smtp_port, use_tls, from_email, to_email, username, notify_success, notify_error FROM email_config WHERE id=1")

        if [ -n "$row" ]; then
            IFS='|' read -r smtp_server smtp_port use_tls from_email to_email username notify_s notify_e <<< "$row"
            echo -e "  Servidor SMTP:    ${WHITE}${smtp_server:-No configurado}${NC}"
            echo -e "  Puerto:           ${WHITE}${smtp_port}${NC}"
            echo -e "  TLS:              ${WHITE}$([ "$use_tls" = "1" ] && echo "Sí" || echo "No")${NC}"
            echo -e "  Remitente:        ${WHITE}${from_email:-No configurado}${NC}"
            echo -e "  Destinatario(s):  ${WHITE}${to_email:-No configurado}${NC}"
            echo -e "  Usuario SMTP:     ${WHITE}${username:-No configurado}${NC}"
            echo -e "  Notificar éxito:  $([ "$notify_s" = "1" ] && echo "${GREEN}Sí${NC}" || echo "${YELLOW}No${NC}")"
            echo -e "  Notificar error:  $([ "$notify_e" = "1" ] && echo "${GREEN}Sí${NC}" || echo "${YELLOW}No${NC}")"
        fi

        echo ""
        echo "  c) Configurar correo"
        echo "  t) Enviar correo de prueba"
        echo "  v) Volver"
        echo ""
        echo -en "  ${CYAN}Opción:${NC} "
        read -r opt
        case "$opt" in
            c) email_configure ;;
            t) email_test ;;
            v) return ;;
        esac
    done
}

email_configure() {
    echo ""
    echo -e "  ${BOLD}Configurar correo electrónico${NC}"
    print_separator

    local row
    row=$(db_query "SELECT smtp_server, smtp_port, use_tls, from_email, to_email, username, password, notify_success, notify_error FROM email_config WHERE id=1")
    IFS='|' read -r old_smtp old_port old_tls old_from old_to old_user old_pass old_ns old_ne <<< "$row"

    local smtp_server smtp_port use_tls from_email to_email username password notify_s notify_e

    read_input "Servidor SMTP [$old_smtp]" smtp_server "${old_smtp}"
    read_input "Puerto [$old_port]" smtp_port "${old_port:-587}"
    read_input "Usar TLS (1/0) [$old_tls]" use_tls "${old_tls:-1}"
    read_input "Email remitente [$old_from]" from_email "${old_from}"
    read_input "Email(s) destinatario [$old_to]" to_email "${old_to}"
    read_input "Usuario SMTP [$old_user]" username "${old_user}"

    echo -en "  Contraseña SMTP (ENTER para mantener): "
    read -rs password
    echo ""
    password="${password:-$old_pass}"

    read_input "Notificar éxitos (1/0) [$old_ns]" notify_s "${old_ns:-0}"
    read_input "Notificar errores (1/0) [$old_ne]" notify_e "${old_ne:-1}"

    db_exec "UPDATE email_config SET
             smtp_server='$smtp_server', smtp_port=$smtp_port, use_tls=$use_tls,
             from_email='$from_email', to_email='$to_email',
             username='$username', password='$password',
             notify_success=$notify_s, notify_error=$notify_e
             WHERE id=1"

    print_ok "Configuración de correo actualizada"
    pause
}

email_test() {
    echo ""
    print_info "Enviando correo de prueba..."

    local body
    body=$(render_template "${LOGMASTER_TEMPLATES}/success.html" \
        "TIMESTAMP" "$(date '+%Y-%m-%d %H:%M:%S')" \
        "SOURCE_PATH" "/test/prueba" \
        "DEST_TARGET" "[Samba] Servidor de prueba" \
        "FILES_OK" "3" \
        "FILES_FAIL" "0" \
        "STATUS" "success" \
        "MESSAGE" "Correo de prueba de LogMaster" \
        "DETAILS" "archivo1.log - OK<br>archivo2.pdf - OK<br>archivo3.csv - OK" \
        "HOSTNAME" "$(hostname)")

    if send_email "[LogMaster] Correo de prueba" "$body"; then
        print_ok "Correo de prueba enviado"
    else
        print_err "Error al enviar correo de prueba"
    fi
    pause
}

# ============================================================
# HISTORIAL DE EJECUCIONES
# ============================================================

log_menu() {
    while true; do
        clear
        print_header
        echo -e "  ${BOLD}HISTORIAL DE EJECUCIONES${NC}"
        print_separator
        echo ""

        local logs
        logs=$(db_query "
            SELECT id, timestamp, source_path, dest_label, status, files_processed, files_failed, message
            FROM execution_log
            ORDER BY id DESC
            LIMIT 25
        ")

        if [ -n "$logs" ]; then
            printf "  ${WHITE}%-4s %-20s %-20s %-20s %-8s %-4s %-4s${NC}\n" \
                "ID" "Fecha" "Origen" "Destino" "Estado" "OK" "Fail"
            print_separator
            while IFS='|' read -r id ts path dest status ok fail msg; do
                local color
                case "$status" in
                    success) color="$GREEN" ;;
                    error)   color="$RED" ;;
                    partial) color="$YELLOW" ;;
                esac
                printf "  %-4s %-20s %-20s %-20s ${color}%-8s${NC} %-4s %-4s\n" \
                    "$id" "$ts" "${path:0:20}" "${dest:0:20}" "$status" "$ok" "$fail"
            done <<< "$logs"
        else
            print_warn "No hay registros de ejecución"
        fi

        echo ""
        echo "  d) Ver detalle de ejecución"
        echo "  l) Ver log del sistema"
        echo "  v) Volver"
        echo ""
        echo -en "  ${CYAN}Opción:${NC} "
        read -r opt
        case "$opt" in
            d)
                read_input "ID del registro" log_id ""
                if [ -n "$log_id" ]; then
                    local detail
                    detail=$(db_query "SELECT timestamp, source_path, dest_label, status, files_processed, files_failed, message, details FROM execution_log WHERE id=$log_id")
                    if [ -n "$detail" ]; then
                        IFS='|' read -r ts path dest status ok fail msg details <<< "$detail"
                        echo ""
                        print_separator
                        echo -e "  Fecha:     ${WHITE}$ts${NC}"
                        echo -e "  Origen:    ${WHITE}$path${NC}"
                        echo -e "  Destino:   ${WHITE}$dest${NC}"
                        echo -e "  Estado:    ${WHITE}$status${NC}"
                        echo -e "  Archivos:  ${GREEN}$ok OK${NC} / ${RED}$fail fallidos${NC}"
                        echo -e "  Mensaje:   $msg"
                        echo ""
                        echo -e "  ${BOLD}Detalle:${NC}"
                        echo -e "  $details"
                    else
                        print_err "ID no encontrado"
                    fi
                fi
                pause
                ;;
            l)
                echo ""
                if [ -f "$LOGMASTER_LOG" ]; then
                    echo -e "  ${BOLD}Últimas 30 líneas del log:${NC}"
                    print_separator
                    tail -30 "$LOGMASTER_LOG" | while IFS= read -r line; do
                        echo "  $line"
                    done
                else
                    print_warn "No existe archivo de log"
                fi
                pause
                ;;
            v) return ;;
        esac
    done
}

# ============================================================
# EJECUCIÓN MANUAL
# ============================================================

manual_exec_menu() {
    clear
    print_header
    echo -e "  ${BOLD}EJECUCIÓN MANUAL${NC}"
    print_separator
    echo ""

    show_directories_tree

    print_separator
    echo ""
    echo "  Opciones:"
    echo "    [ID]  Ejecutar un directorio específico (todos sus destinos)"
    echo "    [0]   Ejecutar TODOS los directorios"
    echo "    [v]   Volver"
    echo ""
    read_input "Opción" exec_opt "v"

    [ "$exec_opt" = "v" ] && return

    if [ "$exec_opt" = "0" ]; then
        echo ""
        print_info "Ejecutando todas las transferencias..."
        echo ""
        "${SCRIPT_DIR}/logmaster.sh" 2>&1 | while IFS= read -r line; do
            echo "  $line"
        done
        print_ok "Ejecución completa"
    else
        local dir_id="$exec_opt"
        local src_path
        src_path=$(db_get "SELECT source_path FROM directories WHERE id=$dir_id AND active=1")
        [ -z "$src_path" ] && { print_err "Directorio no válido o inactivo"; pause; return; }

        # Obtener destinos
        local dests
        dests=$(db_query "
            SELECT dd.id FROM directory_destinations dd
            LEFT JOIN samba_targets st ON st.id = dd.samba_target_id
            WHERE dd.directory_id = $dir_id AND dd.active = 1
              AND (dd.dest_type = 'local' OR (dd.dest_type = 'samba' AND st.active = 1))
        ")

        if [ -z "$dests" ]; then
            print_err "Sin destinos activos para este directorio"
            pause
            return
        fi

        # Mostrar archivos
        local files
        files=$(find_matching_files "$src_path" "$dir_id")
        if [ -z "$files" ]; then
            print_warn "No se encontraron archivos en: $src_path"
            pause
            return
        fi

        local fcount=0
        while IFS= read -r _; do fcount=$((fcount + 1)); done <<< "$files"
        print_info "$fcount archivo(s) encontrados en $src_path"

        echo ""
        if ! confirm "¿Proceder con la transferencia a todos los destinos?"; then
            pause
            return
        fi

        echo ""

        while IFS= read -r dest_id; do
            [ -z "$dest_id" ] && continue

            local dest_label
            dest_label=$(get_dest_label "$dest_id")
            echo ""
            echo -e "  ${BOLD}Destino: $dest_label${NC}"
            print_separator

            local drow
            drow=$(db_query "
                SELECT dd.dest_type, dd.local_path, dd.remote_subdir, dd.action,
                       COALESCE(st.server,''), COALESCE(st.share,''), COALESCE(st.username,''),
                       COALESCE(st.password,''), COALESCE(st.domain,''), COALESCE(st.port,445),
                       COALESCE(st.remote_path,'')
                FROM directory_destinations dd
                LEFT JOIN samba_targets st ON st.id = dd.samba_target_id
                WHERE dd.id = $dest_id
            ")

            IFS='|' read -r dtype lpath subdir action server share user pass domain port rpath <<< "$drow"

            local ok=0 fail=0

            # Re-leer archivos (pueden haber sido movidos por destino anterior)
            files=$(find_matching_files "$src_path" "$dir_id")
            [ -z "$files" ] && { print_warn "  Sin archivos restantes"; continue; }

            while IFS= read -r filepath; do
                [ -z "$filepath" ] && continue
                local fname
                fname=$(basename "$filepath")
                echo -en "    $fname... "

                local transfer_ok=0

                if [ "$dtype" = "samba" ]; then
                    local full_remote="$rpath"
                    [ -n "$subdir" ] && full_remote="${rpath%/}/${subdir}"
                    if samba_upload_file "$server" "$share" "$user" "$pass" "$domain" "$port" "$full_remote" "$filepath"; then
                        transfer_ok=1
                    fi
                else
                    local full_local="$lpath"
                    [ -n "$subdir" ] && full_local="${lpath%/}/${subdir}"
                    if local_copy_file "$filepath" "$full_local"; then
                        transfer_ok=1
                    fi
                fi

                if [ "$transfer_ok" -eq 1 ]; then
                    echo -e "${GREEN}OK${NC}"
                    ok=$((ok + 1))
                    if [ "$action" = "move" ]; then
                        rm -f "$filepath" 2>/dev/null && echo -e "      ${DIM}(origen eliminado)${NC}"
                    fi
                else
                    echo -e "${RED}ERROR${NC}"
                    fail=$((fail + 1))
                fi
            done <<< "$files"

            echo ""
            echo -e "    Resultado: ${GREEN}$ok OK${NC} / ${RED}$fail fallidos${NC}"

            local status="success"
            [ "$fail" -gt 0 ] && [ "$ok" -gt 0 ] && status="partial"
            [ "$fail" -gt 0 ] && [ "$ok" -eq 0 ] && status="error"

            local safe_label
            safe_label=$(echo "$dest_label" | sed "s/'/''/g")
            db_exec "INSERT INTO execution_log (directory_id, destination_id, source_path, dest_label, status, files_processed, files_failed, message)
                     VALUES ($dir_id, $dest_id, '$src_path', '$safe_label', '$status', $ok, $fail, 'Manual: $ok OK, $fail fallidos')"

        done <<< "$dests"
    fi

    pause
}

# ============================================================
# CRON
# ============================================================

cron_menu() {
    while true; do
        clear
        print_header
        echo -e "  ${BOLD}GESTIÓN DE CRON${NC}"
        print_separator
        echo ""

        local cron_transfer="* * * * * ${SCRIPT_DIR}/logmaster.sh >> ${LOGMASTER_LOG} 2>&1"
        local cron_sync="* * * * * ${SCRIPT_DIR}/logmaster-sync.sh >> ${LOGMASTER_LOG} 2>&1"

        echo -e "  ${BOLD}Transferencias:${NC}"
        if crontab -l 2>/dev/null | grep -q "logmaster.sh"; then
            echo -e "    ${GREEN}INSTALADO${NC}"
            crontab -l 2>/dev/null | grep "logmaster.sh" | while IFS= read -r line; do
                echo -e "    ${DIM}$line${NC}"
            done
        else
            echo -e "    ${YELLOW}NO instalado${NC}"
        fi

        echo ""
        echo -e "  ${BOLD}Sincronización:${NC}"
        if crontab -l 2>/dev/null | grep -q "logmaster-sync.sh"; then
            echo -e "    ${GREEN}INSTALADO${NC}"
            crontab -l 2>/dev/null | grep "logmaster-sync.sh" | while IFS= read -r line; do
                echo -e "    ${DIM}$line${NC}"
            done
        else
            echo -e "    ${YELLOW}NO instalado${NC}"
        fi

        echo ""
        echo "  1) Instalar transferencias en crontab"
        echo "  2) Instalar sincronización en crontab"
        echo "  3) Instalar AMBOS en crontab"
        echo "  4) Desinstalar transferencias"
        echo "  5) Desinstalar sincronización"
        echo "  6) Desinstalar TODO"
        echo "  v) Volver"
        echo ""
        echo -en "  ${CYAN}Opción:${NC} "
        read -r opt
        case "$opt" in
            1)
                if crontab -l 2>/dev/null | grep -q "logmaster.sh"; then
                    print_warn "Transferencias ya instaladas"
                else
                    (crontab -l 2>/dev/null; echo "$cron_transfer") | crontab -
                    print_ok "Transferencias instaladas (cada 1 minuto)"
                    log_info "Cron transferencias instalado"
                fi
                pause ;;
            2)
                if crontab -l 2>/dev/null | grep -q "logmaster-sync.sh"; then
                    print_warn "Sincronización ya instalada"
                else
                    (crontab -l 2>/dev/null; echo "$cron_sync") | crontab -
                    print_ok "Sincronización instalada (cada 1 minuto)"
                    log_info "Cron sincronización instalado"
                fi
                pause ;;
            3)
                local changed=0
                if ! crontab -l 2>/dev/null | grep -q "logmaster.sh"; then
                    (crontab -l 2>/dev/null; echo "$cron_transfer") | crontab -
                    changed=1
                fi
                if ! crontab -l 2>/dev/null | grep -q "logmaster-sync.sh"; then
                    (crontab -l 2>/dev/null; echo "$cron_sync") | crontab -
                    changed=1
                fi
                [ "$changed" -eq 1 ] && print_ok "Ambos servicios instalados" || print_warn "Ya estaban instalados"
                pause ;;
            4)
                crontab -l 2>/dev/null | grep -v "logmaster.sh" | crontab -
                print_ok "Transferencias desinstaladas"
                pause ;;
            5)
                crontab -l 2>/dev/null | grep -v "logmaster-sync.sh" | crontab -
                print_ok "Sincronización desinstalada"
                pause ;;
            6)
                if confirm "¿Desinstalar TODO de crontab?"; then
                    crontab -l 2>/dev/null | grep -v "logmaster" | crontab -
                    print_ok "Todo desinstalado de crontab"
                fi
                pause ;;
            v) return ;;
        esac
    done
}

# ============================================================
# ESTADO DEL SISTEMA
# ============================================================

status_menu() {
    clear
    print_header
    echo -e "  ${BOLD}ESTADO DEL SISTEMA${NC}"
    print_separator
    echo ""

    if [ -f "$LOGMASTER_DB" ]; then
        local db_size
        db_size=$(du -h "$LOGMASTER_DB" | cut -f1)
        print_ok "Base de datos: $LOGMASTER_DB ($db_size)"
    else
        print_err "Base de datos no encontrada"
    fi

    if crontab -l 2>/dev/null | grep -q "logmaster.sh"; then
        print_ok "Cron: Instalado"
    else
        print_warn "Cron: No instalado"
    fi

    if [ -f "$LOGMASTER_LOCK" ]; then
        local pid
        pid=$(cat "$LOGMASTER_LOCK")
        if kill -0 "$pid" 2>/dev/null; then
            print_warn "Lock activo: PID $pid en ejecución"
        else
            print_warn "Lock huérfano (PID $pid no existe)"
        fi
    else
        print_ok "Lock: Libre"
    fi

    echo ""

    local n_targets n_dirs n_dests n_filters n_schedules n_logs
    n_targets=$(db_get "SELECT COUNT(*) FROM samba_targets")
    n_dirs=$(db_get "SELECT COUNT(*) FROM directories")
    n_dests=$(db_get "SELECT COUNT(*) FROM directory_destinations")
    n_filters=$(db_get "SELECT COUNT(*) FROM filters")
    n_schedules=$(db_get "SELECT COUNT(*) FROM schedules")
    n_logs=$(db_get "SELECT COUNT(*) FROM execution_log")

    echo -e "  ${BOLD}Estadísticas:${NC}"
    echo "  Catálogo Samba:     $n_targets"
    echo "  Directorios:        $n_dirs"
    echo "  Destinos asignados: $n_dests"
    echo "  Filtros:            $n_filters"
    echo "  Programaciones:     $n_schedules"
    echo "  Registros de log:   $n_logs"

    echo ""

    local last_ok last_err
    last_ok=$(db_get "SELECT timestamp FROM execution_log WHERE status='success' ORDER BY id DESC LIMIT 1")
    last_err=$(db_get "SELECT timestamp FROM execution_log WHERE status='error' ORDER BY id DESC LIMIT 1")

    echo -e "  Último éxito:  ${GREEN}${last_ok:-Ninguno}${NC}"
    echo -e "  Último error:  ${RED}${last_err:-Ninguno}${NC}"

    echo ""

    local upcoming
    upcoming=$(db_query "
        SELECT s.next_run, d.source_path
        FROM schedules s
        JOIN directories d ON d.id = s.directory_id
        WHERE s.active=1 AND d.active=1
        ORDER BY s.next_run
        LIMIT 5
    ")

    if [ -n "$upcoming" ]; then
        echo -e "  ${BOLD}Próximas ejecuciones:${NC}"
        while IFS='|' read -r next_run path; do
            echo -e "    ${CYAN}$next_run${NC} - $path"
        done <<< "$upcoming"
    fi

    echo ""
    echo -e "  ${BOLD}Dependencias:${NC}"
    for cmd in sqlite3 smbclient curl ssh scp; do
        if command -v "$cmd" &>/dev/null; then
            print_ok "$cmd: $(command -v "$cmd")"
        else
            print_err "$cmd: NO INSTALADO"
        fi
    done

    # Info de red
    echo ""
    local role node_name last_sync
    role=$(get_node_role)
    node_name=$(db_get "SELECT node_name FROM node_config WHERE id=1")
    last_sync=$(db_get "SELECT last_sync FROM node_config WHERE id=1")

    echo -e "  ${BOLD}Red:${NC}"
    echo -e "  Nodo:    ${WHITE}${node_name:-$(hostname)}${NC}"
    echo -e "  Rol:     ${WHITE}${role}${NC}"
    echo -e "  Últ.sync:${WHITE} ${last_sync:-Nunca}${NC}"

    if [ "$role" = "master" ]; then
        local n_nodes
        n_nodes=$(db_get "SELECT COUNT(*) FROM registered_nodes WHERE active=1")
        echo -e "  Slaves:  ${WHITE}${n_nodes}${NC}"
    fi

    pause
}

# ============================================================
# RED Y SINCRONIZACIÓN
# ============================================================

network_menu() {
    while true; do
        clear
        print_header
        echo -e "  ${BOLD}${MAGENTA}RED Y SINCRONIZACIÓN${NC}"
        print_separator
        echo ""

        # Mostrar config actual del nodo
        local nrow
        nrow=$(db_query "SELECT node_id, node_name, node_role, master_host, master_port,
                         master_user, sync_mode, sync_interval, last_sync,
                         sync_samba_catalog, push_status, autonomous_on_fail
                         FROM node_config WHERE id=1")

        if [ -n "$nrow" ]; then
            IFS='|' read -r nid nname nrole mhost mport muser smode sint lsync \
                ssamba spush sauto <<< "$nrow"

            local role_color
            case "$nrole" in
                master)     role_color="${GREEN}MASTER${NC}" ;;
                slave)      role_color="${YELLOW}SLAVE${NC}" ;;
                standalone) role_color="${CYAN}STANDALONE${NC}" ;;
            esac

            echo -e "  ID Nodo:        ${WHITE}${nid}${NC}"
            echo -e "  Nombre:         ${WHITE}${nname:-$(hostname)}${NC}"
            echo -e "  Rol:            ${role_color}"
            echo -e "  Última sync:    ${WHITE}${lsync:-Nunca}${NC}"

            if [ "$nrole" = "slave" ]; then
                echo ""
                echo -e "  ${BOLD}Conexión al Master:${NC}"
                echo -e "  Host:           ${WHITE}${mhost:-No configurado}${NC}"
                echo -e "  Puerto SSH:     ${WHITE}${mport}${NC}"
                echo -e "  Usuario SSH:    ${WHITE}${muser:-No configurado}${NC}"
                local smode_txt
                [ "$smode" = "mandatory" ] && smode_txt="${RED}OBLIGATORIA${NC}" || smode_txt="${GREEN}OPCIONAL${NC}"
                echo -e "  Sincronización: ${smode_txt}"
                echo -e "  Intervalo:      ${WHITE}${sint}min${NC}"
                echo -e "  Recibir Samba:  $([ "$ssamba" = "1" ] && echo "${GREEN}Sí${NC}" || echo "${YELLOW}No${NC}")"
                echo -e "  Enviar estado:  $([ "$spush" = "1" ] && echo "${GREEN}Sí${NC}" || echo "${YELLOW}No${NC}")"
                echo -e "  Autónomo:       $([ "$sauto" = "1" ] && echo "${GREEN}Sí${NC}" || echo "${YELLOW}No${NC}")"
            fi

            if [ "$nrole" = "master" ]; then
                echo ""
                echo -e "  ${BOLD}Slaves Registrados:${NC}"
                local slaves
                slaves=$(db_query "SELECT id, node_name, host, status, last_seen FROM registered_nodes WHERE active=1 ORDER BY id")
                if [ -n "$slaves" ]; then
                    printf "  ${WHITE}%-4s %-20s %-18s %-10s %-20s${NC}\n" "ID" "Nombre" "Host" "Estado" "Último contacto"
                    while IFS='|' read -r sid sname shost sstatus slast; do
                        local st_color
                        case "$sstatus" in
                            online)  st_color="$GREEN" ;;
                            offline) st_color="$RED" ;;
                            error)   st_color="$RED" ;;
                            *)       st_color="$YELLOW" ;;
                        esac
                        printf "  %-4s %-20s %-18s ${st_color}%-10s${NC} %-20s\n" "$sid" "$sname" "$shost" "$sstatus" "${slast:--}"
                    done <<< "$slaves"
                else
                    print_warn "  Sin slaves registrados"
                fi
            fi
        fi

        echo ""
        print_separator
        echo ""
        echo -e "  ${BOLD}Configuración:${NC}"
        echo "   1) Configurar identidad del nodo (rol, nombre)"
        if [ "$(get_node_role)" = "slave" ] || [ "$(get_node_role)" = "standalone" ]; then
            echo "   2) Configurar conexión al Master"
            echo "   3) Probar conexión al Master"
        fi
        if [ "$(get_node_role)" = "master" ]; then
            echo "   4) Registrar un slave"
            echo "   5) Eliminar un slave"
            echo "   6) Recolectar estado de todos los slaves"
            echo "   7) Distribuir catálogo Samba a slaves"
            echo "   8) Gestionar canales de comunicación"
            echo "   9) Ver estado detallado de un slave"
            echo -e "  ${YELLOW}13) Handoff: transferir master a otro nodo${NC}"
            echo "  14) Detectar conflicto de masters"
        fi
        echo "  10) Forzar sincronización ahora"
        echo "  11) Ver historial de sincronizaciones"
        echo "  12) Generar par de llaves SSH"
        echo "   v) Volver"
        echo ""
        echo -en "  ${CYAN}Opción:${NC} "
        read -r opt
        case "$opt" in
            1)  net_configure_node ;;
            2)  net_configure_master_conn ;;
            3)  net_test_master ;;
            4)  net_register_slave ;;
            5)  net_remove_slave ;;
            6)  net_collect_all ;;
            7)  net_push_samba_all ;;
            8)  channels_menu ;;
            9)  net_slave_detail ;;
            10) net_force_sync ;;
            11) net_sync_log ;;
            12) net_generate_ssh_key ;;
            13) net_handoff ;;
            14) net_detect_conflict ;;
            v)  return ;;
        esac
    done
}

net_configure_node() {
    echo ""
    echo -e "  ${BOLD}CONFIGURAR IDENTIDAD DEL NODO${NC}"
    print_separator

    local old_name old_role
    old_name=$(db_get "SELECT node_name FROM node_config WHERE id=1")
    old_role=$(db_get "SELECT node_role FROM node_config WHERE id=1")

    read_input "Nombre del nodo [$old_name]" node_name "${old_name:-$(hostname)}"

    # Actualizar nombre siempre
    db_exec "UPDATE node_config SET node_name='$node_name' WHERE id=1"

    echo ""
    echo "  Rol del nodo:"
    echo "    1) standalone - Opera de forma independiente (sin red)"
    echo "    2) master     - Central que coordina slaves"
    echo "    3) slave      - Nodo que reporta a un master"
    echo ""
    local role_opt
    case "$old_role" in
        standalone) echo -en "  Opción [1 = actual standalone]: "; read -r role_opt; role_opt="${role_opt:-1}" ;;
        master)     echo -en "  Opción [2 = actual master]: "; read -r role_opt; role_opt="${role_opt:-2}" ;;
        slave)      echo -en "  Opción [3 = actual slave]: "; read -r role_opt; role_opt="${role_opt:-3}" ;;
    esac

    local new_role
    case "$role_opt" in
        2) new_role="master" ;;
        3) new_role="slave" ;;
        *) new_role="standalone" ;;
    esac

    if [ "$old_role" = "$new_role" ]; then
        print_ok "Nodo actualizado: ${node_name} (sin cambio de rol)"
        pause
        return
    fi

    # Validación pre-cambio
    echo ""
    print_info "Validando cambio de rol: ${old_role} → ${new_role}..."

    local validation
    validation=$(role_change_validate "$old_role" "$new_role")
    local val_status="${validation%%:*}"
    local val_msg="${validation#*:}"

    case "$val_status" in
        ERROR)
            print_err "$val_msg"
            pause
            return
            ;;
        WARN)
            print_warn "$val_msg"
            if ! confirm "¿Continuar con el cambio de rol?"; then
                pause
                return
            fi
            ;;
        OK|SAME)
            ;;
    esac

    # Ejecutar cambio seguro
    echo ""
    print_info "Ejecutando cambio de rol..."
    role_change_execute "$old_role" "$new_role"

    print_ok "Rol cambiado: ${old_role} → ${new_role}"
    echo ""

    case "$new_role" in
        slave)
            if confirm "¿Configurar conexión al Master ahora?"; then
                net_configure_master_conn
                return
            fi
            ;;
        master)
            print_info "Registre slaves desde la opción 4 de este menú"
            ;;
    esac

    pause
}

net_configure_master_conn() {
    local role
    role=$(get_node_role)
    if [ "$role" != "slave" ]; then
        print_warn "Solo los nodos slave necesitan conexión al master"
        pause
        return
    fi

    echo ""
    echo -e "  ${BOLD}CONEXIÓN AL MASTER${NC}"
    print_separator

    local old_host old_port old_user old_key old_path old_smode old_sint old_ssamba old_spush old_sauto
    local orow
    orow=$(db_query "SELECT master_host, master_port, master_user, master_ssh_key, master_path,
                     sync_mode, sync_interval, sync_samba_catalog, push_status, autonomous_on_fail
                     FROM node_config WHERE id=1")
    IFS='|' read -r old_host old_port old_user old_key old_path old_smode old_sint old_ssamba old_spush old_sauto <<< "$orow"

    local host port user key path smode sint ssamba spush sauto

    read_input "Host del master (IP/hostname) [$old_host]" host "${old_host}"
    read_input "Puerto SSH [$old_port]" port "${old_port:-22}"
    read_input "Usuario SSH [$old_user]" user "${old_user}"
    read_input "Ruta llave SSH privada [$old_key]" key "${old_key:-$HOME/.ssh/id_rsa}"
    read_input "Ruta LogMaster en el master [$old_path]" path "${old_path}"

    echo ""
    echo "  Modo de sincronización:"
    echo "    1) optional  - Si el master no responde, sigue operando"
    echo "    2) mandatory - Requiere conexión al master"
    local smode_opt
    [ "$old_smode" = "mandatory" ] && smode_opt="2" || smode_opt="1"
    echo -en "  Opción [$smode_opt]: "
    read -r smode_in
    smode_in="${smode_in:-$smode_opt}"
    [ "$smode_in" = "2" ] && smode="mandatory" || smode="optional"

    read_input "Intervalo sync en minutos [$old_sint]" sint "${old_sint:-5}"
    read_input "Recibir catálogo Samba del master (1/0) [$old_ssamba]" ssamba "${old_ssamba:-1}"
    read_input "Enviar estado al master (1/0) [$old_spush]" spush "${old_spush:-1}"
    read_input "Operar autónomamente si master falla (1/0) [$old_sauto]" sauto "${old_sauto:-1}"

    db_exec "UPDATE node_config SET
             master_host='$host', master_port=$port, master_user='$user',
             master_ssh_key='$key', master_path='$path',
             sync_mode='$smode', sync_interval=$sint,
             sync_samba_catalog=$ssamba, push_status=$spush, autonomous_on_fail=$sauto
             WHERE id=1"

    print_ok "Conexión al master configurada"
    pause
}

net_test_master() {
    echo ""
    local row
    row=$(db_query "SELECT master_host, master_port, master_user, master_ssh_key, master_path FROM node_config WHERE id=1")
    IFS='|' read -r host port user key path <<< "$row"

    if [ -z "$host" ] || [ -z "$user" ]; then
        print_err "Conexión al master no configurada"
        pause
        return
    fi

    print_info "Probando SSH a ${user}@${host}:${port}..."

    local result
    result=$(sync_test_connection "$host" "$port" "$user" "$key" "$path")

    if [ "$result" = "OK" ]; then
        print_ok "Conexión exitosa al master"
        # Obtener info del master
        local master_role
        master_role=$(ssh_exec "$host" "$port" "$user" "$key" \
            "sqlite3 '${path}/data/logmaster.db' \"SELECT node_role FROM node_config WHERE id=1\"" 2>/dev/null)
        if [ -n "$master_role" ]; then
            print_info "Rol remoto: $master_role"
        fi
    else
        print_err "$result"
    fi
    pause
}

net_register_slave() {
    local role
    role=$(get_node_role)
    [ "$role" != "master" ] && { print_warn "Solo el master puede registrar slaves"; pause; return; }

    echo ""
    echo -e "  ${BOLD}REGISTRAR NUEVO SLAVE${NC}"
    print_separator

    local sname host port user key rpath

    read_input "Nombre del slave" sname ""
    [ -z "$sname" ] && { print_err "Nombre requerido"; pause; return; }

    read_input "Host (IP o hostname)" host ""
    [ -z "$host" ] && { print_err "Host requerido"; pause; return; }

    read_input "Puerto SSH" port "22"
    read_input "Usuario SSH" user ""
    [ -z "$user" ] && { print_err "Usuario requerido"; pause; return; }

    read_input "Ruta llave SSH privada" key "$HOME/.ssh/id_rsa"
    read_input "Ruta LogMaster en el slave" rpath ""

    # Probar conexión
    print_info "Probando conexión..."
    local test_result
    test_result=$(sync_test_connection "$host" "$port" "$user" "$key" "$rpath")

    if [ "$test_result" != "OK" ]; then
        print_warn "Advertencia: $test_result"
        if ! confirm "¿Registrar de todas formas?"; then
            pause
            return
        fi
    else
        print_ok "Conexión verificada"
    fi

    # Obtener node_id del slave
    local remote_node_id=""
    if [ -n "$rpath" ]; then
        remote_node_id=$(ssh_exec "$host" "$port" "$user" "$key" \
            "sqlite3 '${rpath}/data/logmaster.db' \"SELECT node_id FROM node_config WHERE id=1\"" 2>/dev/null)
    fi

    if [ -z "$remote_node_id" ]; then
        remote_node_id=$(echo "$host" | md5sum | cut -c1-16)
        print_warn "No se pudo obtener node_id, usando hash: $remote_node_id"
    fi

    db_exec "INSERT INTO registered_nodes (node_id, node_name, host, port, ssh_user, ssh_key, remote_path, status)
             VALUES ('$remote_node_id', '$sname', '$host', $port, '$user', '$key', '$rpath', 'unknown')"

    print_ok "Slave '$sname' registrado ($host)"
    pause
}

net_remove_slave() {
    local role
    role=$(get_node_role)
    [ "$role" != "master" ] && { print_warn "Solo el master"; pause; return; }

    echo ""
    read_input "ID del slave a eliminar" del_id ""
    [ -z "$del_id" ] && return

    local sname
    sname=$(db_get "SELECT node_name FROM registered_nodes WHERE id=$del_id")
    [ -z "$sname" ] && { print_err "ID no encontrado"; pause; return; }

    if confirm "¿Eliminar slave '$sname'?"; then
        db_exec "DELETE FROM registered_nodes WHERE id=$del_id"
        print_ok "Slave eliminado"
    fi
    pause
}

net_collect_all() {
    local role
    role=$(get_node_role)
    [ "$role" != "master" ] && { print_warn "Solo el master"; pause; return; }

    echo ""
    print_info "Recolectando estado de todos los slaves..."
    echo ""

    sync_collect_all 2>&1 | while IFS= read -r line; do
        echo "  $line"
    done

    print_ok "Recolección completada"
    pause
}

net_push_samba_all() {
    local role
    role=$(get_node_role)
    [ "$role" != "master" ] && { print_warn "Solo el master"; pause; return; }

    echo ""
    print_info "Distribuyendo catálogo Samba a todos los slaves..."

    sync_push_samba_all

    print_ok "Distribución completada"
    pause
}

net_slave_detail() {
    local role
    role=$(get_node_role)
    [ "$role" != "master" ] && { print_warn "Solo el master"; pause; return; }

    echo ""
    read_input "ID del slave" slave_id ""
    [ -z "$slave_id" ] && return

    local srow
    srow=$(db_query "SELECT node_id, node_name, host, port, status, last_seen, last_sync
                     FROM registered_nodes WHERE id=$slave_id")
    [ -z "$srow" ] && { print_err "ID no encontrado"; pause; return; }

    IFS='|' read -r snid sname shost sport sstatus slast_seen slast_sync <<< "$srow"

    echo ""
    echo -e "  ${BOLD}DETALLE DE SLAVE: $sname${NC}"
    print_separator
    echo -e "  Node ID:    ${WHITE}$snid${NC}"
    echo -e "  Host:       ${WHITE}$shost:$sport${NC}"
    echo -e "  Estado:     ${WHITE}$sstatus${NC}"
    echo -e "  Visto:      ${WHITE}${slast_seen:-Nunca}${NC}"
    echo -e "  Sync:       ${WHITE}${slast_sync:-Nunca}${NC}"

    # Buscar último estado recibido
    local ns_row
    ns_row=$(db_query "SELECT hostname, uptime, dirs_count, dests_count, schedules_count,
                       last_exec_status, exec_ok_24h, exec_fail_24h, disk_usage, cron_installed, timestamp
                       FROM node_status WHERE node_id='$snid' ORDER BY id DESC LIMIT 1")

    if [ -n "$ns_row" ]; then
        IFS='|' read -r nhost nup ndirs ndests nscheds nlast nok nfail ndisk ncron nts <<< "$ns_row"
        echo ""
        echo -e "  ${BOLD}Último reporte (${nts}):${NC}"
        echo -e "  Hostname:     ${WHITE}$nhost${NC}"
        echo -e "  Uptime:       ${WHITE}$nup${NC}"
        echo -e "  Directorios:  ${WHITE}$ndirs${NC}"
        echo -e "  Destinos:     ${WHITE}$ndests${NC}"
        echo -e "  Schedules:    ${WHITE}$nscheds${NC}"
        echo -e "  Últ.ejecución:${WHITE} $nlast${NC}"
        echo -e "  OK 24h:       ${GREEN}$nok${NC}"
        echo -e "  Fallos 24h:   ${RED}$nfail${NC}"
        echo -e "  Disco:        ${WHITE}$ndisk${NC}"
        echo -e "  Cron:         $([ "$ncron" = "1" ] && echo "${GREEN}Instalado${NC}" || echo "${RED}No${NC}")"
    else
        print_warn "Sin reportes de estado recibidos"
    fi

    pause
}

net_force_sync() {
    echo ""
    print_info "Ejecutando sincronización manual..."
    echo ""

    "${SCRIPT_DIR}/logmaster-sync.sh" 2>&1 | while IFS= read -r line; do
        echo "  $line"
    done

    print_ok "Sincronización completada"
    pause
}

net_sync_log() {
    echo ""
    echo -e "  ${BOLD}HISTORIAL DE SINCRONIZACIONES${NC}"
    print_separator
    echo ""

    local slogs
    slogs=$(db_query "SELECT timestamp, direction, remote_host, status, items_synced, message
                      FROM sync_log ORDER BY id DESC LIMIT 20")

    if [ -n "$slogs" ]; then
        printf "  ${WHITE}%-20s %-8s %-18s %-8s %-6s %-25s${NC}\n" \
            "Fecha" "Dir" "Host" "Estado" "Items" "Mensaje"
        print_separator
        while IFS='|' read -r ts dir host status items msg; do
            local color
            [ "$status" = "success" ] && color="$GREEN" || color="$RED"
            printf "  %-20s %-8s %-18s ${color}%-8s${NC} %-6s %-25s\n" \
                "$ts" "$dir" "${host:0:18}" "$status" "$items" "${msg:0:25}"
        done <<< "$slogs"
    else
        print_warn "Sin registros de sincronización"
    fi

    pause
}

net_generate_ssh_key() {
    echo ""
    local key_path="$HOME/.ssh/logmaster_rsa"

    if [ -f "$key_path" ]; then
        print_warn "Ya existe una llave en: $key_path"
        if ! confirm "¿Regenerar?"; then
            echo ""
            echo -e "  Llave pública actual:"
            echo -e "  ${DIM}$(cat "${key_path}.pub" 2>/dev/null)${NC}"
            pause
            return
        fi
    fi

    print_info "Generando par de llaves SSH..."
    ssh-keygen -t rsa -b 4096 -f "$key_path" -N "" -C "logmaster@$(hostname)" 2>/dev/null

    if [ -f "$key_path" ]; then
        print_ok "Llaves generadas:"
        echo -e "  Privada: ${WHITE}${key_path}${NC}"
        echo -e "  Pública: ${WHITE}${key_path}.pub${NC}"
        echo ""
        echo -e "  ${BOLD}Copie esta llave pública en los servidores remotos:${NC}"
        echo -e "  ${CYAN}$(cat "${key_path}.pub")${NC}"
        echo ""
        echo -e "  Comando para copiar:"
        echo -e "  ${DIM}ssh-copy-id -i ${key_path}.pub usuario@servidor${NC}"
    else
        print_err "Error al generar llaves"
    fi
    pause
}

net_handoff() {
    local role
    role=$(get_node_role)
    [ "$role" != "master" ] && { print_warn "Solo el master puede hacer handoff"; pause; return; }

    echo ""
    echo -e "  ${BOLD}${YELLOW}HANDOFF: TRANSFERIR ROL DE MASTER${NC}"
    print_separator
    echo ""
    echo -e "  ${YELLOW}Esta operación transferirá el rol de master, los slaves registrados,${NC}"
    echo -e "  ${YELLOW}canales de comunicación y catálogo Samba compartido al nodo destino.${NC}"
    echo -e "  ${YELLOW}Este nodo se convertirá en slave del nuevo master.${NC}"
    echo ""

    # Mostrar slaves registrados como posibles destinos
    local slaves
    slaves=$(db_query "SELECT id, node_name, host, port, ssh_user, ssh_key, remote_path FROM registered_nodes WHERE active=1")

    if [ -n "$slaves" ]; then
        echo -e "  ${BOLD}Slaves registrados (posibles destinos):${NC}"
        while IFS='|' read -r sid sname shost sport suser skey spath; do
            echo "    [$sid] $sname ($shost)"
        done <<< "$slaves"
        echo ""
    fi

    echo "  Puede elegir un slave registrado o ingresar datos manualmente."
    echo -en "  ID de slave [o 'm' para manual]: "
    read -r handoff_opt

    local t_host t_port t_user t_key t_path

    if [ "$handoff_opt" = "m" ]; then
        read_input "Host destino" t_host ""
        read_input "Puerto SSH" t_port "22"
        read_input "Usuario SSH" t_user ""
        read_input "Llave SSH" t_key "$HOME/.ssh/logmaster_rsa"
        read_input "Ruta LogMaster en destino" t_path ""
    else
        local srow
        srow=$(db_query "SELECT host, port, ssh_user, ssh_key, remote_path FROM registered_nodes WHERE id=$handoff_opt AND active=1")
        [ -z "$srow" ] && { print_err "ID no válido"; pause; return; }
        IFS='|' read -r t_host t_port t_user t_key t_path <<< "$srow"
    fi

    [ -z "$t_host" ] || [ -z "$t_user" ] || [ -z "$t_path" ] && { print_err "Datos incompletos"; pause; return; }

    echo ""
    echo -e "  Destino: ${WHITE}${t_user}@${t_host}:${t_port}  ${t_path}${NC}"
    echo ""

    if ! confirm "¿CONFIRMAR HANDOFF? Este nodo dejará de ser master"; then
        pause
        return
    fi

    echo ""
    print_info "Ejecutando handoff..."

    if master_handoff "$t_host" "$t_port" "$t_user" "$t_key" "$t_path"; then
        echo ""
        print_ok "Handoff completado exitosamente"
        print_info "Nuevo master: $t_host"
        print_info "Este nodo ahora es: slave"
    else
        print_err "Error durante el handoff"
    fi

    pause
}

net_detect_conflict() {
    local role
    role=$(get_node_role)
    [ "$role" != "master" ] && { print_warn "Solo el master puede detectar conflictos"; pause; return; }

    echo ""
    print_info "Verificando integridad de la red..."
    echo ""

    local slaves
    slaves=$(db_query "SELECT node_name, host, port, ssh_user, ssh_key, remote_path
                       FROM registered_nodes WHERE active=1")

    if [ -z "$slaves" ]; then
        print_warn "Sin slaves registrados para verificar"
        pause
        return
    fi

    local my_host
    my_host=$(hostname -I 2>/dev/null | awk '{print $1}')
    local my_hostname
    my_hostname=$(hostname)
    local conflicts=0

    while IFS='|' read -r sname shost sport suser skey spath; do
        [ -z "$shost" ] && continue
        echo -en "  Verificando ${sname} (${shost})... "

        local remote_master
        remote_master=$(ssh_exec "$shost" "$sport" "$suser" "$skey" \
            "sqlite3 '${spath}/data/logmaster.db' \"SELECT master_host FROM node_config WHERE id=1\"" 2>/dev/null)

        if [ -z "$remote_master" ]; then
            echo -e "${YELLOW}Sin respuesta${NC}"
        elif [ "$remote_master" = "$my_host" ] || [ "$remote_master" = "$my_hostname" ]; then
            echo -e "${GREEN}OK${NC} (apunta a este master)"
        else
            echo -e "${RED}CONFLICTO${NC} → apunta a: ${remote_master}"
            conflicts=$((conflicts + 1))
        fi
    done <<< "$slaves"

    echo ""
    if [ "$conflicts" -gt 0 ]; then
        print_err "$conflicts slave(s) apuntan a otro master"
        echo ""
        echo -e "  ${YELLOW}Opciones para resolver:${NC}"
        echo "  - Verificar que no haya otro master activo en la red"
        echo "  - Los slaves afectados pueden ser reconfigurados:"
        echo "    menú 10 → opción 7 (Distribuir catálogo actualiza conexión)"
    else
        print_ok "Sin conflictos detectados. Todos los slaves apuntan a este master."
    fi

    pause
}

# ============================================================
# CANALES DE COMUNICACIÓN (master)
# ============================================================

channels_menu() {
    local role
    role=$(get_node_role)
    [ "$role" != "master" ] && { print_warn "Solo el master gestiona canales"; pause; return; }

    while true; do
        clear
        print_header
        echo -e "  ${BOLD}CANALES DE COMUNICACIÓN${NC}"
        print_separator
        echo ""

        local channels
        channels=$(db_query "SELECT id, name, channel_type, frequency, active, last_sent FROM comm_channels ORDER BY id")

        if [ -n "$channels" ]; then
            printf "  ${WHITE}%-4s %-20s %-10s %-10s %-8s %-20s${NC}\n" \
                "ID" "Nombre" "Tipo" "Frecuencia" "Estado" "Último envío"
            print_separator
            while IFS='|' read -r cid cname ctype cfreq cactive clast; do
                local estado
                [ "$cactive" = "1" ] && estado="${GREEN}Activo${NC}" || estado="${RED}Inactivo${NC}"
                printf "  %-4s %-20s %-10s %-10s ${estado}  %-20s\n" \
                    "$cid" "$cname" "$ctype" "$cfreq" "${clast:--}"
            done <<< "$channels"
        else
            print_warn "Sin canales configurados"
        fi

        echo ""
        echo "  a) Agregar canal"
        echo "  e) Editar canal"
        echo "  d) Eliminar canal"
        echo "  t) Enviar reporte de prueba"
        echo "  v) Volver"
        echo ""
        echo -en "  ${CYAN}Opción:${NC} "
        read -r opt
        case "$opt" in
            a) channel_add ;;
            e) channel_edit ;;
            d) channel_delete ;;
            t) channel_test ;;
            v) return ;;
        esac
    done
}

channel_add() {
    echo ""
    echo -e "  ${BOLD}NUEVO CANAL DE COMUNICACIÓN${NC}"
    print_separator

    local name ctype

    read_input "Nombre del canal" name ""
    [ -z "$name" ] && { print_err "Nombre requerido"; pause; return; }

    echo "  Tipo:"
    echo "    1) email   - Reporte por correo"
    echo "    2) file    - Reporte en archivo"
    echo "    3) webhook - Envío a URL"
    echo -en "  Opción: "
    read -r type_opt

    local to_email="" output_path="" webhook_url=""

    case "$type_opt" in
        1) ctype="email";   read_input "Email(s) destinatario" to_email "" ;;
        2) ctype="file";    read_input "Ruta del archivo de salida" output_path "" ;;
        3) ctype="webhook"; read_input "URL del webhook" webhook_url "" ;;
        *) print_err "Tipo inválido"; pause; return ;;
    esac

    echo ""
    echo "  Frecuencia:"
    echo "    1) realtime - Cada ciclo de sync"
    echo "    2) hourly   - Cada hora"
    echo "    3) daily    - Una vez al día"
    echo "    4) weekly   - Una vez a la semana"
    echo -en "  Opción [3]: "
    read -r freq_opt

    local frequency report_time report_day
    case "$freq_opt" in
        1) frequency="realtime"; report_time=""; report_day="" ;;
        2) frequency="hourly"; report_time=""; report_day="" ;;
        4) frequency="weekly"
           read_input "Hora (HH:MM)" report_time "08:00"
           echo "  Día: 1=Lun 2=Mar 3=Mié 4=Jue 5=Vie 6=Sáb 7=Dom"
           read_input "Día" report_day "1"
           ;;
        *) frequency="daily"
           read_input "Hora (HH:MM)" report_time "08:00"
           report_day=""
           ;;
    esac

    read_input "Nodos a incluir (* = todos, o CSV de node_ids)" include_nodes "*"

    db_exec "INSERT INTO comm_channels (name, channel_type, to_email, output_path, webhook_url,
             include_nodes, frequency, report_time, report_day)
             VALUES ('$name', '$ctype', '$to_email', '$output_path', '$webhook_url',
             '$include_nodes', '$frequency', '${report_time:-00:00}', '${report_day:-1}')"

    print_ok "Canal '$name' creado"
    pause
}

channel_edit() {
    echo ""
    read_input "ID del canal a editar" edit_id ""
    [ -z "$edit_id" ] && return

    local active
    local old_active
    old_active=$(db_get "SELECT active FROM comm_channels WHERE id=$edit_id")
    [ -z "$old_active" ] && { print_err "ID no encontrado"; pause; return; }

    read_input "Activo (1/0) [$old_active]" active "$old_active"
    db_exec "UPDATE comm_channels SET active=$active WHERE id=$edit_id"

    print_ok "Canal actualizado"
    pause
}

channel_delete() {
    echo ""
    read_input "ID del canal a eliminar" del_id ""
    [ -z "$del_id" ] && return

    if confirm "¿Eliminar canal #$del_id?"; then
        db_exec "DELETE FROM comm_channels WHERE id=$del_id"
        print_ok "Canal eliminado"
    fi
    pause
}

channel_test() {
    echo ""
    read_input "ID del canal para enviar prueba" test_id ""
    [ -z "$test_id" ] && return

    print_info "Generando y enviando reporte..."
    send_channel_report "$test_id"
    print_ok "Reporte enviado"
    pause
}

# ============================================================
# INICIO
# ============================================================

main_menu

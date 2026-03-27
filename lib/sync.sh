#!/bin/bash
# ============================================================
# LogMaster v2.0 - Librería de Sincronización SSH
# Comunicación entre nodos Master / Slave
# ============================================================

# Depende de functions.sh (ya cargado por quien lo incluya)

SYNC_LOCK="/tmp/logmaster_sync.lock"

# ============================================================
# Utilidades SSH
# ============================================================

# Ejecutar comando remoto via SSH
ssh_exec() {
    local host="$1" port="$2" user="$3" key="$4" cmd="$5"
    local ssh_opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

    if [ -n "$key" ] && [ -f "$key" ]; then
        ssh_opts="$ssh_opts -i $key"
    fi

    ssh $ssh_opts -p "$port" "${user}@${host}" "$cmd" 2>/dev/null
    return $?
}

# Copiar archivo a remoto via SCP
scp_to() {
    local host="$1" port="$2" user="$3" key="$4" local_file="$5" remote_file="$6"
    local ssh_opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

    if [ -n "$key" ] && [ -f "$key" ]; then
        ssh_opts="$ssh_opts -i $key"
    fi

    scp $ssh_opts -P "$port" "$local_file" "${user}@${host}:${remote_file}" 2>/dev/null
    return $?
}

# Copiar archivo desde remoto via SCP
scp_from() {
    local host="$1" port="$2" user="$3" key="$4" remote_file="$5" local_file="$6"
    local ssh_opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

    if [ -n "$key" ] && [ -f "$key" ]; then
        ssh_opts="$ssh_opts -i $key"
    fi

    scp $ssh_opts -P "$port" "${user}@${host}:${remote_file}" "$local_file" 2>/dev/null
    return $?
}

# ============================================================
# Obtener config del nodo local
# ============================================================

get_node_config() {
    db_query "SELECT node_id, node_name, node_role, master_host, master_port,
              master_user, master_ssh_key, master_path, sync_mode,
              sync_interval, sync_samba_catalog, push_status, autonomous_on_fail
              FROM node_config WHERE id=1"
}

get_node_id() {
    db_get "SELECT node_id FROM node_config WHERE id=1"
}

get_node_role() {
    db_get "SELECT node_role FROM node_config WHERE id=1"
}

# ============================================================
# TEST de conexión SSH
# ============================================================

sync_test_connection() {
    local host="$1" port="$2" user="$3" key="$4" remote_path="$5"

    # Test 1: SSH conecta
    if ! ssh_exec "$host" "$port" "$user" "$key" "echo OK" | grep -q "OK"; then
        echo "ERROR: No se pudo conectar via SSH a ${user}@${host}:${port}"
        return 1
    fi

    # Test 2: LogMaster existe en remoto
    if [ -n "$remote_path" ]; then
        if ! ssh_exec "$host" "$port" "$user" "$key" "test -f ${remote_path}/lib/functions.sh && echo OK" | grep -q "OK"; then
            echo "ERROR: LogMaster no encontrado en ${remote_path} del host remoto"
            return 2
        fi
    fi

    echo "OK"
    return 0
}

# ============================================================
# SLAVE: Generar payload de estado (JSON)
# ============================================================

generate_status_payload() {
    local node_id node_name
    node_id=$(get_node_id)
    node_name=$(db_get "SELECT node_name FROM node_config WHERE id=1")

    local dirs_count dests_count scheds_count
    dirs_count=$(db_get "SELECT COUNT(*) FROM directories WHERE active=1")
    dests_count=$(db_get "SELECT COUNT(*) FROM directory_destinations WHERE active=1")
    scheds_count=$(db_get "SELECT COUNT(*) FROM schedules WHERE active=1")

    local last_status last_time
    last_status=$(db_get "SELECT status FROM execution_log ORDER BY id DESC LIMIT 1")
    last_time=$(db_get "SELECT timestamp FROM execution_log ORDER BY id DESC LIMIT 1")

    local ok_24h fail_24h
    ok_24h=$(db_get "SELECT COALESCE(SUM(files_processed),0) FROM execution_log WHERE timestamp >= datetime('now','localtime','-1 day') AND status='success'")
    fail_24h=$(db_get "SELECT COUNT(*) FROM execution_log WHERE timestamp >= datetime('now','localtime','-1 day') AND status IN ('error','partial')")

    local cron_on=0
    crontab -l 2>/dev/null | grep -q "logmaster.sh" && cron_on=1

    local disk_usage
    disk_usage=$(df -h / 2>/dev/null | tail -1 | awk '{print $5}')

    local hostname_val
    hostname_val=$(hostname)

    local uptime_val
    uptime_val=$(uptime -p 2>/dev/null || uptime | sed 's/.*up /up /' | cut -d, -f1-2)

    # Últimas 50 ejecuciones
    local recent_logs
    recent_logs=$(db_query_csv "SELECT timestamp, source_path, dest_label, status, files_processed, files_failed, message FROM execution_log ORDER BY id DESC LIMIT 50" | sed 's/"/\\"/g')

    cat <<JSONEOF
{
  "node_id": "${node_id}",
  "node_name": "${node_name}",
  "hostname": "${hostname_val}",
  "uptime": "${uptime_val}",
  "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')",
  "dirs_count": ${dirs_count},
  "dests_count": ${dests_count},
  "schedules_count": ${scheds_count},
  "last_exec_status": "${last_status}",
  "last_exec_time": "${last_time}",
  "exec_ok_24h": ${ok_24h},
  "exec_fail_24h": ${fail_24h},
  "disk_usage": "${disk_usage}",
  "cron_installed": ${cron_on},
  "recent_logs": "${recent_logs}"
}
JSONEOF
}

# ============================================================
# SLAVE: Enviar estado al master (push)
# ============================================================

sync_push_status() {
    local row
    row=$(get_node_config)
    [ -z "$row" ] && return 1

    IFS='|' read -r node_id node_name role master_host master_port \
        master_user master_key master_path sync_mode \
        sync_interval sync_samba push_status autonomous <<< "$row"

    [ "$push_status" != "1" ] && return 0

    if [ -z "$master_host" ] || [ -z "$master_user" ] || [ -z "$master_path" ]; then
        log_warn "SYNC: Configuración del master incompleta"
        return 1
    fi

    log_info "SYNC: Enviando estado a master ${master_host}..."

    # Generar payload
    local tmpfile
    tmpfile=$(mktemp /tmp/logmaster_status_XXXXXX.json)
    generate_status_payload > "$tmpfile"

    # Enviar al master
    local remote_incoming="${master_path}/data/incoming"
    ssh_exec "$master_host" "$master_port" "$master_user" "$master_key" \
        "mkdir -p ${remote_incoming}"

    local remote_file="${remote_incoming}/status_${node_id}.json"
    if scp_to "$master_host" "$master_port" "$master_user" "$master_key" "$tmpfile" "$remote_file"; then
        log_info "SYNC: Estado enviado correctamente"
        db_exec "INSERT INTO sync_log (direction, remote_node_id, remote_host, status, message)
                 VALUES ('push', 'master', '$master_host', 'success', 'Estado enviado')"
        db_exec "UPDATE node_config SET last_sync=datetime('now','localtime') WHERE id=1"
        rm -f "$tmpfile"
        return 0
    else
        log_error "SYNC: Error al enviar estado al master"
        db_exec "INSERT INTO sync_log (direction, remote_node_id, remote_host, status, message)
                 VALUES ('push', 'master', '$master_host', 'error', 'Fallo SSH/SCP')"
        rm -f "$tmpfile"
        return 1
    fi
}

# ============================================================
# SLAVE: Recibir catálogo Samba del master (pull)
# ============================================================

sync_pull_samba_catalog() {
    local row
    row=$(get_node_config)
    [ -z "$row" ] && return 1

    IFS='|' read -r node_id node_name role master_host master_port \
        master_user master_key master_path sync_mode \
        sync_interval sync_samba push_status autonomous <<< "$row"

    [ "$sync_samba" != "1" ] && return 0

    if [ -z "$master_host" ] || [ -z "$master_user" ] || [ -z "$master_path" ]; then
        return 1
    fi

    log_info "SYNC: Descargando catálogo Samba del master..."

    # Obtener catálogo compartido del master via SSH + sqlite3
    local remote_db="${master_path}/data/logmaster.db"
    local catalog
    catalog=$(ssh_exec "$master_host" "$master_port" "$master_user" "$master_key" \
        "sqlite3 -separator '|' '${remote_db}' \"SELECT name,server,share,remote_path,username,password,domain,port FROM samba_targets WHERE shared=1 AND active=1\"")

    if [ -z "$catalog" ]; then
        log_info "SYNC: Sin destinos Samba compartidos en el master"
        return 0
    fi

    local count=0
    while IFS='|' read -r name server share rpath user pass domain port; do
        [ -z "$name" ] && continue

        # Insertar o actualizar (upsert)
        local exists
        exists=$(db_get "SELECT id FROM samba_targets WHERE name='$name' AND origin_node='master'")

        if [ -n "$exists" ]; then
            db_exec "UPDATE samba_targets SET server='$server', share='$share',
                     remote_path='$rpath', username='$user', password='$pass',
                     domain='$domain', port=$port, active=1
                     WHERE id=$exists"
        else
            db_exec "INSERT INTO samba_targets (name, server, share, remote_path, username, password, domain, port, origin_node, shared)
                     VALUES ('$name', '$server', '$share', '$rpath', '$user', '$pass', '$domain', $port, 'master', 0)"
        fi
        count=$((count + 1))
    done <<< "$catalog"

    log_info "SYNC: $count destinos Samba sincronizados del master"
    db_exec "INSERT INTO sync_log (direction, remote_node_id, remote_host, status, items_synced, message)
             VALUES ('pull', 'master', '$master_host', 'success', $count, 'Catálogo Samba actualizado')"

    return 0
}

# ============================================================
# MASTER: Recolectar estado de un slave
# ============================================================

sync_collect_from_node() {
    local reg_id="$1"

    local row
    row=$(db_query "SELECT node_id, node_name, host, port, ssh_user, ssh_key, remote_path
                    FROM registered_nodes WHERE id=$reg_id AND active=1")
    [ -z "$row" ] && return 1

    IFS='|' read -r rnode_id rnode_name rhost rport ruser rkey rpath <<< "$row"

    log_info "SYNC: Recolectando de slave '${rnode_name}' (${rhost})..."

    # Primero verificar si hay un archivo de estado en incoming
    local incoming_file="${LOGMASTER_DIR}/data/incoming/status_${rnode_id}.json"

    if [ -f "$incoming_file" ]; then
        # Procesar archivo push (el slave ya lo envió)
        _process_node_status "$rnode_id" "$incoming_file"
        rm -f "$incoming_file"
        db_exec "UPDATE registered_nodes SET last_seen=datetime('now','localtime'),
                 last_sync=datetime('now','localtime'), status='online' WHERE id=$reg_id"
        return 0
    fi

    # Si no hay push, hacer pull activo via SSH
    local remote_db="${rpath}/data/logmaster.db"
    local tmpfile
    tmpfile=$(mktemp /tmp/logmaster_pull_XXXXXX.json)

    # Ejecutar generación de status en el slave remoto
    local payload
    payload=$(ssh_exec "$rhost" "$rport" "$ruser" "$rkey" \
        "cd '${rpath}' && bash -c 'source lib/functions.sh && source lib/sync.sh && db_init && generate_status_payload'")

    if [ -z "$payload" ]; then
        log_error "SYNC: No se pudo obtener estado de ${rnode_name} (${rhost})"
        db_exec "UPDATE registered_nodes SET status='error', last_seen=datetime('now','localtime') WHERE id=$reg_id"
        db_exec "INSERT INTO sync_log (direction, remote_node_id, remote_host, status, message)
                 VALUES ('collect', '$rnode_id', '$rhost', 'error', 'Sin respuesta del slave')"
        rm -f "$tmpfile"
        return 1
    fi

    echo "$payload" > "$tmpfile"
    _process_node_status "$rnode_id" "$tmpfile"
    rm -f "$tmpfile"

    db_exec "UPDATE registered_nodes SET last_seen=datetime('now','localtime'),
             last_sync=datetime('now','localtime'), status='online' WHERE id=$reg_id"

    db_exec "INSERT INTO sync_log (direction, remote_node_id, remote_host, status, message)
             VALUES ('collect', '$rnode_id', '$rhost', 'success', 'Estado recolectado')"

    log_info "SYNC: Estado de '${rnode_name}' recolectado correctamente"
    return 0
}

# Procesar archivo JSON de estado de un nodo
_process_node_status() {
    local rnode_id="$1" json_file="$2"

    [ ! -f "$json_file" ] && return 1

    # Parsear JSON con herramientas básicas (sed/grep)
    local node_name hostname uptime dirs dests scheds
    local last_status last_time ok_24h fail_24h disk cron_on

    node_name=$(_json_val "$json_file" "node_name")
    hostname=$(_json_val "$json_file" "hostname")
    uptime=$(_json_val "$json_file" "uptime")
    dirs=$(_json_val "$json_file" "dirs_count")
    dests=$(_json_val "$json_file" "dests_count")
    scheds=$(_json_val "$json_file" "schedules_count")
    last_status=$(_json_val "$json_file" "last_exec_status")
    last_time=$(_json_val "$json_file" "last_exec_time")
    ok_24h=$(_json_val "$json_file" "exec_ok_24h")
    fail_24h=$(_json_val "$json_file" "exec_fail_24h")
    disk=$(_json_val "$json_file" "disk_usage")
    cron_on=$(_json_val "$json_file" "cron_installed")

    local raw_json
    raw_json=$(cat "$json_file" | sed "s/'/''/g")

    db_exec "INSERT INTO node_status (node_id, node_name, hostname, uptime,
             dirs_count, dests_count, schedules_count,
             last_exec_status, last_exec_time, exec_ok_24h, exec_fail_24h,
             disk_usage, cron_installed, raw_json)
             VALUES ('$rnode_id', '$node_name', '$hostname', '$uptime',
             ${dirs:-0}, ${dests:-0}, ${scheds:-0},
             '$last_status', '$last_time', ${ok_24h:-0}, ${fail_24h:-0},
             '$disk', ${cron_on:-0}, '$raw_json')"
}

# Extraer valor de JSON simple (sin jq)
_json_val() {
    local file="$1" key="$2"
    grep "\"${key}\"" "$file" 2>/dev/null | head -1 | sed 's/.*: *"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/'
}

# ============================================================
# MASTER: Recolectar de TODOS los slaves
# ============================================================

sync_collect_all() {
    local role
    role=$(get_node_role)
    [ "$role" != "master" ] && { log_warn "SYNC: Solo el master puede recolectar"; return 1; }

    mkdir -p "${LOGMASTER_DIR}/data/incoming"

    local nodes
    nodes=$(db_query "SELECT id FROM registered_nodes WHERE active=1")

    [ -z "$nodes" ] && { log_info "SYNC: Sin slaves registrados"; return 0; }

    local ok=0 fail=0
    while IFS= read -r nid; do
        [ -z "$nid" ] && continue
        if sync_collect_from_node "$nid"; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done <<< "$nodes"

    log_info "SYNC: Recolección completada: $ok OK, $fail fallidos"
    return 0
}

# ============================================================
# MASTER: Distribuir catálogo Samba a un slave
# ============================================================

sync_push_samba_to_node() {
    local reg_id="$1"

    local row
    row=$(db_query "SELECT node_id, host, port, ssh_user, ssh_key, remote_path
                    FROM registered_nodes WHERE id=$reg_id AND active=1")
    [ -z "$row" ] && return 1

    IFS='|' read -r rnode_id rhost rport ruser rkey rpath <<< "$row"

    # Generar archivo SQL con catálogo compartido
    local tmpfile
    tmpfile=$(mktemp /tmp/logmaster_samba_cat_XXXXXX.sql)

    local shared_samba
    shared_samba=$(db_query "SELECT name,server,share,remote_path,username,password,domain,port
                             FROM samba_targets WHERE shared=1 AND active=1")

    echo "-- LogMaster Samba catalog sync" > "$tmpfile"

    while IFS='|' read -r name server share rpath user pass domain port; do
        [ -z "$name" ] && continue
        cat >> "$tmpfile" <<SQLEOF
INSERT OR REPLACE INTO samba_targets (name, server, share, remote_path, username, password, domain, port, origin_node, active)
VALUES ('$name', '$server', '$share', '$rpath', '$user', '$pass', '$domain', $port, 'master', 1);
SQLEOF
    done <<< "$shared_samba"

    local remote_incoming="${rpath}/data/incoming"
    ssh_exec "$rhost" "$rport" "$ruser" "$rkey" "mkdir -p ${remote_incoming}"

    if scp_to "$rhost" "$rport" "$ruser" "$rkey" "$tmpfile" "${remote_incoming}/samba_catalog.sql"; then
        # Ejecutar SQL en el slave
        ssh_exec "$rhost" "$rport" "$ruser" "$rkey" \
            "sqlite3 '${rpath}/data/logmaster.db' < '${remote_incoming}/samba_catalog.sql' && rm -f '${remote_incoming}/samba_catalog.sql'"
        log_info "SYNC: Catálogo Samba enviado a $rhost"
        rm -f "$tmpfile"
        return 0
    else
        log_error "SYNC: Error enviando catálogo a $rhost"
        rm -f "$tmpfile"
        return 1
    fi
}

# ============================================================
# MASTER: Distribuir catálogo a TODOS los slaves
# ============================================================

sync_push_samba_all() {
    local role
    role=$(get_node_role)
    [ "$role" != "master" ] && return 1

    local nodes
    nodes=$(db_query "SELECT id FROM registered_nodes WHERE active=1")
    [ -z "$nodes" ] && return 0

    local ok=0 fail=0
    while IFS= read -r nid; do
        [ -z "$nid" ] && continue
        if sync_push_samba_to_node "$nid"; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done <<< "$nodes"

    log_info "SYNC: Catálogo distribuido: $ok OK, $fail fallidos"
}

# ============================================================
# MASTER: Generar reporte de canal de comunicación
# ============================================================

generate_channel_report() {
    local channel_id="$1"

    local crow
    crow=$(db_query "SELECT name, channel_type, to_email, output_path, webhook_url,
                     include_nodes, include_success, include_errors
                     FROM comm_channels WHERE id=$channel_id AND active=1")
    [ -z "$crow" ] && return 1

    IFS='|' read -r ch_name ch_type ch_email ch_file ch_webhook \
        ch_nodes ch_success ch_errors <<< "$crow"

    # Construir listado de nodos
    local node_filter=""
    if [ "$ch_nodes" != "*" ]; then
        local in_list
        in_list=$(echo "$ch_nodes" | sed "s/,/','/g")
        node_filter="AND ns.node_id IN ('${in_list}')"
    fi

    # Obtener último estado de cada nodo
    local report=""
    report+="╔══════════════════════════════════════════════════════════════╗\n"
    report+="║  LOGMASTER - Reporte de Red: ${ch_name}\n"
    report+="║  Generado: $(date '+%Y-%m-%d %H:%M:%S')\n"
    report+="╚══════════════════════════════════════════════════════════════╝\n\n"

    local nodes_data
    nodes_data=$(db_query "
        SELECT ns.node_id, ns.node_name, ns.hostname, ns.last_exec_status,
               ns.exec_ok_24h, ns.exec_fail_24h, ns.disk_usage, ns.cron_installed,
               rn.status, ns.timestamp
        FROM node_status ns
        JOIN registered_nodes rn ON rn.node_id = ns.node_id
        WHERE ns.id IN (SELECT MAX(id) FROM node_status GROUP BY node_id)
        ${node_filter}
        ORDER BY ns.node_name
    ")

    if [ -n "$nodes_data" ]; then
        report+="NODO                 HOST             ESTADO    OK/24h  FAIL/24h  DISCO   CRON\n"
        report+="─────────────────────────────────────────────────────────────────────────────\n"

        while IFS='|' read -r nid nname nhost last_st ok_24 fail_24 disk cron nstat nts; do
            local cron_txt="Sí"
            [ "$cron" != "1" ] && cron_txt="No"
            report+="$(printf '%-20s %-16s %-9s %-7s %-9s %-7s %s' "$nname" "$nhost" "$nstat" "$ok_24" "$fail_24" "$disk" "$cron_txt")\n"
        done <<< "$nodes_data"
    else
        report+="Sin datos de nodos disponibles.\n"
    fi

    report+="\n"

    echo -e "$report"
}

send_channel_report() {
    local channel_id="$1"

    local crow
    crow=$(db_query "SELECT channel_type, to_email, output_path, webhook_url, name
                     FROM comm_channels WHERE id=$channel_id AND active=1")
    [ -z "$crow" ] && return 1

    IFS='|' read -r ch_type ch_email ch_file ch_webhook ch_name <<< "$crow"

    local report
    report=$(generate_channel_report "$channel_id")

    case "$ch_type" in
        email)
            if [ -n "$ch_email" ]; then
                local html_report
                html_report="<html><body><pre style='font-family:monospace;font-size:13px;'>${report}</pre></body></html>"
                # Usar la función de envío existente con destinatario override
                local tmpfile
                tmpfile=$(mktemp /tmp/logmaster_report_XXXXXX.eml)
                local from_email
                from_email=$(db_get "SELECT from_email FROM email_config WHERE id=1")
                local smtp_server smtp_port use_tls username password
                local erow
                erow=$(db_query "SELECT smtp_server, smtp_port, use_tls, username, password FROM email_config WHERE id=1")
                IFS='|' read -r smtp_server smtp_port use_tls username password <<< "$erow"

                cat > "$tmpfile" <<EMLEOF
From: LogMaster <${from_email}>
To: ${ch_email}
Subject: [LogMaster] Reporte de Red - ${ch_name}
MIME-Version: 1.0
Content-Type: text/html; charset=UTF-8

${html_report}
EMLEOF

                local tls_flag=""
                [ "$use_tls" = "1" ] && tls_flag="--ssl-reqd"
                local curl_auth=""
                [ -n "$username" ] && [ -n "$password" ] && curl_auth="--user ${username}:${password}"
                local proto="smtp"
                [ "$use_tls" = "1" ] && [ "$smtp_port" = "465" ] && proto="smtps"

                curl --silent --max-time 30 \
                    --url "${proto}://${smtp_server}:${smtp_port}" \
                    $tls_flag --mail-from "$from_email" --mail-rcpt "$ch_email" \
                    $curl_auth -T "$tmpfile" 2>/dev/null

                rm -f "$tmpfile"
                log_info "CHANNEL: Reporte '${ch_name}' enviado a ${ch_email}"
            fi
            ;;
        file)
            if [ -n "$ch_file" ]; then
                mkdir -p "$(dirname "$ch_file")"
                echo -e "$report" > "$ch_file"
                log_info "CHANNEL: Reporte '${ch_name}' guardado en ${ch_file}"
            fi
            ;;
        webhook)
            if [ -n "$ch_webhook" ]; then
                local json_report
                json_report=$(echo -e "$report" | sed 's/"/\\"/g' | tr '\n' ' ')
                curl --silent --max-time 15 -X POST \
                    -H "Content-Type: application/json" \
                    -d "{\"channel\":\"${ch_name}\",\"report\":\"${json_report}\"}" \
                    "$ch_webhook" 2>/dev/null
                log_info "CHANNEL: Reporte '${ch_name}' enviado a webhook"
            fi
            ;;
    esac

    db_exec "UPDATE comm_channels SET last_sent=datetime('now','localtime') WHERE id=$channel_id"
}

# ============================================================
# MASTER: Procesar todos los canales pendientes
# ============================================================

process_channels() {
    local role
    role=$(get_node_role)
    [ "$role" != "master" ] && return 0

    local now_epoch hour minute dow
    now_epoch=$(date +%s)
    hour=$(date '+%H')
    minute=$(date '+%M')
    dow=$(date '+%u')

    local channels
    channels=$(db_query "SELECT id, frequency, report_time, report_day, last_sent FROM comm_channels WHERE active=1")

    while IFS='|' read -r ch_id freq rtime rday last_sent; do
        [ -z "$ch_id" ] && continue

        local should_send=0

        case "$freq" in
            realtime)
                should_send=1
                ;;
            hourly)
                if [ -z "$last_sent" ]; then
                    should_send=1
                else
                    local last_epoch
                    last_epoch=$(date -d "$last_sent" +%s 2>/dev/null || echo 0)
                    [ $((now_epoch - last_epoch)) -ge 3600 ] && should_send=1
                fi
                ;;
            daily)
                if [ "${hour}:${minute}" = "$rtime" ]; then
                    should_send=1
                fi
                ;;
            weekly)
                if [ "${hour}:${minute}" = "$rtime" ] && [ "$dow" = "$rday" ]; then
                    should_send=1
                fi
                ;;
        esac

        if [ "$should_send" -eq 1 ]; then
            send_channel_report "$ch_id"
        fi
    done <<< "$channels"
}

# ============================================================
# Lock de sincronización (separado del lock de transferencia)
# ============================================================

acquire_sync_lock() {
    if [ -f "$SYNC_LOCK" ]; then
        local lock_pid
        lock_pid=$(cat "$SYNC_LOCK" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            return 1
        fi
        rm -f "$SYNC_LOCK"
    fi
    echo $$ > "$SYNC_LOCK"
    return 0
}

release_sync_lock() {
    rm -f "$SYNC_LOCK"
}

# ============================================================
# ROTACIÓN SEGURA DE ROLES
# ============================================================

# Archivo de transición: el daemon sync lo respeta
ROLE_TRANSITION_FLAG="/tmp/logmaster_role_transition"

# Validar si es seguro cambiar de rol
role_change_validate() {
    local current_role="$1" new_role="$2"

    # Mismo rol: nada que hacer
    [ "$current_role" = "$new_role" ] && echo "SAME" && return 0

    # Verificar que no hay sync en curso
    if [ -f "$SYNC_LOCK" ]; then
        local lock_pid
        lock_pid=$(cat "$SYNC_LOCK" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "ERROR:Sincronización en curso (PID $lock_pid). Espere a que termine."
            return 1
        fi
    fi

    # Verificar que no hay transferencia en curso
    if [ -f "$LOGMASTER_LOCK" ]; then
        local lock_pid
        lock_pid=$(cat "$LOGMASTER_LOCK" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "ERROR:Transferencia en curso (PID $lock_pid). Espere a que termine."
            return 1
        fi
    fi

    # Validaciones específicas por transición
    case "${current_role}_to_${new_role}" in
        master_to_slave)
            local n_slaves
            n_slaves=$(db_get "SELECT COUNT(*) FROM registered_nodes WHERE active=1")
            if [ "$n_slaves" -gt 0 ]; then
                echo "WARN:Hay $n_slaves slaves registrados que perderán conexión con este master."
                return 0
            fi
            ;;
        slave_to_master)
            local master_host
            master_host=$(db_get "SELECT master_host FROM node_config WHERE id=1")
            if [ -n "$master_host" ]; then
                echo "WARN:Este nodo dejará de reportar al master ($master_host)."
                return 0
            fi
            ;;
    esac

    echo "OK"
    return 0
}

# Ejecutar cambio de rol con limpieza y notificación
role_change_execute() {
    local old_role="$1" new_role="$2"

    # Activar flag de transición (daemon sync lo respeta)
    echo "$(date '+%Y-%m-%d %H:%M:%S')|${old_role}|${new_role}" > "$ROLE_TRANSITION_FLAG"

    log_info "ROLE: Iniciando transición ${old_role} -> ${new_role}"

    # === PASO 1: Notificar a peers antes de cambiar ===

    case "$old_role" in
        master)
            # Notificar a todos los slaves que este master se va
            _notify_slaves_role_change "master_leaving"
            ;;
        slave)
            # Notificar al master que este slave cambia de rol
            _notify_master_role_change "slave_leaving" "$new_role"
            ;;
    esac

    # === PASO 2: Limpiar estado específico del rol anterior ===

    case "${old_role}_to_${new_role}" in
        master_to_slave)
            # Desactivar slaves registrados (no eliminar, por si vuelve a master)
            db_exec "UPDATE registered_nodes SET active=0, status='offline'"
            # Desactivar canales
            db_exec "UPDATE comm_channels SET active=0"
            log_info "ROLE: Slaves y canales desactivados (se conservan para posible retorno)"
            ;;
        master_to_standalone)
            db_exec "UPDATE registered_nodes SET active=0, status='offline'"
            db_exec "UPDATE comm_channels SET active=0"
            log_info "ROLE: Slaves y canales desactivados"
            ;;
        slave_to_master)
            # Limpiar config de conexión al master anterior (no borrar, desactivar)
            db_exec "UPDATE node_config SET push_status=0 WHERE id=1"
            # Reactivar slaves si los había (retorno a master)
            local had_slaves
            had_slaves=$(db_get "SELECT COUNT(*) FROM registered_nodes")
            if [ "$had_slaves" -gt 0 ]; then
                db_exec "UPDATE registered_nodes SET active=1, status='unknown'"
                log_info "ROLE: $had_slaves slaves anteriores reactivados"
            fi
            # Reactivar canales si los había
            local had_channels
            had_channels=$(db_get "SELECT COUNT(*) FROM comm_channels")
            if [ "$had_channels" -gt 0 ]; then
                db_exec "UPDATE comm_channels SET active=1"
                log_info "ROLE: $had_channels canales anteriores reactivados"
            fi
            ;;
        slave_to_standalone)
            db_exec "UPDATE node_config SET push_status=0 WHERE id=1"
            log_info "ROLE: Push de estado desactivado"
            ;;
        standalone_to_slave)
            db_exec "UPDATE node_config SET push_status=1 WHERE id=1"
            log_info "ROLE: Push de estado activado"
            ;;
        standalone_to_master)
            local had_slaves
            had_slaves=$(db_get "SELECT COUNT(*) FROM registered_nodes")
            if [ "$had_slaves" -gt 0 ]; then
                db_exec "UPDATE registered_nodes SET active=1, status='unknown'"
                log_info "ROLE: $had_slaves slaves anteriores reactivados"
            fi
            local had_channels
            had_channels=$(db_get "SELECT COUNT(*) FROM comm_channels")
            if [ "$had_channels" -gt 0 ]; then
                db_exec "UPDATE comm_channels SET active=1"
            fi
            ;;
    esac

    # === PASO 3: Cambiar el rol en la BD ===

    db_exec "UPDATE node_config SET node_role='$new_role' WHERE id=1"

    # === PASO 4: Registrar en sync_log ===

    db_exec "INSERT INTO sync_log (direction, status, message)
             VALUES ('push', 'success', 'Cambio de rol: ${old_role} -> ${new_role}')"

    # === PASO 5: Notificar a nuevos peers ===

    case "$new_role" in
        slave)
            # Intentar registrarse en el master
            _notify_master_role_change "slave_joining" "$new_role"
            ;;
        master)
            # Notificar a slaves que hay nuevo master
            _notify_slaves_role_change "new_master"
            ;;
    esac

    # Quitar flag de transición
    rm -f "$ROLE_TRANSITION_FLAG"

    log_info "ROLE: Transición completada -> $new_role"
    return 0
}

# Notificar al master sobre cambio de rol de este slave
_notify_master_role_change() {
    local event="$1" new_role="$2"

    local row
    row=$(db_query "SELECT master_host, master_port, master_user, master_ssh_key, master_path
                    FROM node_config WHERE id=1")
    [ -z "$row" ] && return

    IFS='|' read -r mhost mport muser mkey mpath <<< "$row"
    [ -z "$mhost" ] || [ -z "$muser" ] && return

    local node_id
    node_id=$(get_node_id)

    # Enviar notificación via SSH
    ssh_exec "$mhost" "$mport" "$muser" "$mkey" \
        "sqlite3 '${mpath}/data/logmaster.db' \"UPDATE registered_nodes SET status='offline' WHERE node_id='$node_id'\"" 2>/dev/null

    log_info "ROLE: Master notificado: $event"
}

# Notificar a slaves sobre cambio en este master
_notify_slaves_role_change() {
    local event="$1"

    local slaves
    slaves=$(db_query "SELECT host, port, ssh_user, ssh_key, remote_path, node_id
                       FROM registered_nodes WHERE active=1")
    [ -z "$slaves" ] && return

    while IFS='|' read -r shost sport suser skey spath snid; do
        [ -z "$shost" ] && continue

        case "$event" in
            master_leaving)
                # Poner flag en el slave de que master no disponible
                ssh_exec "$shost" "$sport" "$suser" "$skey" \
                    "sqlite3 '${spath}/data/logmaster.db' \"INSERT INTO sync_log (direction,status,message) VALUES ('pull','error','Master se desconectó')\"" 2>/dev/null
                ;;
            new_master)
                # Actualizar el master_host en el slave al host actual
                local my_host
                my_host=$(hostname -I 2>/dev/null | awk '{print $1}')
                [ -z "$my_host" ] && my_host=$(hostname)
                ssh_exec "$shost" "$sport" "$suser" "$skey" \
                    "sqlite3 '${spath}/data/logmaster.db' \"UPDATE node_config SET master_host='$my_host' WHERE id=1\"" 2>/dev/null
                ;;
        esac

        log_info "ROLE: Slave $shost notificado: $event"
    done <<< "$slaves"
}

# Verificar conflicto de dos masters (ejecutar desde slave o master)
detect_master_conflict() {
    local role
    role=$(get_node_role)

    if [ "$role" = "master" ]; then
        # Preguntar a cada slave quién es su master
        local slaves
        slaves=$(db_query "SELECT host, port, ssh_user, ssh_key, remote_path, node_name
                           FROM registered_nodes WHERE active=1")
        [ -z "$slaves" ] && return 0

        local my_id
        my_id=$(get_node_id)
        local conflict=0

        while IFS='|' read -r shost sport suser skey spath sname; do
            [ -z "$shost" ] && continue
            local remote_master_host
            remote_master_host=$(ssh_exec "$shost" "$sport" "$suser" "$skey" \
                "sqlite3 '${spath}/data/logmaster.db' \"SELECT master_host FROM node_config WHERE id=1\"" 2>/dev/null)

            local my_host
            my_host=$(hostname -I 2>/dev/null | awk '{print $1}')

            if [ -n "$remote_master_host" ] && [ "$remote_master_host" != "$my_host" ] && [ "$remote_master_host" != "$(hostname)" ]; then
                log_warn "CONFLICT: Slave '$sname' apunta a otro master: $remote_master_host"
                conflict=1
            fi
        done <<< "$slaves"

        return $conflict
    fi

    return 0
}

# Handoff: transferir rol de master a otro nodo
master_handoff() {
    local target_host="$1" target_port="$2" target_user="$3" target_key="$4" target_path="$5"

    local role
    role=$(get_node_role)
    [ "$role" != "master" ] && { echo "ERROR: Solo el master puede hacer handoff"; return 1; }

    log_info "HANDOFF: Iniciando transferencia de master a $target_host"

    # 1. Exportar registered_nodes al nuevo master
    local nodes_sql
    nodes_sql=$(mktemp /tmp/logmaster_handoff_XXXXXX.sql)

    echo "-- Handoff de slaves desde $(hostname)" > "$nodes_sql"
    local slaves
    slaves=$(db_query "SELECT node_id, node_name, host, port, ssh_user, ssh_key, remote_path
                       FROM registered_nodes WHERE active=1")

    while IFS='|' read -r nid nname nhost nport nuser nkey npath; do
        [ -z "$nid" ] && continue
        cat >> "$nodes_sql" <<SQLEOF
INSERT OR REPLACE INTO registered_nodes (node_id, node_name, host, port, ssh_user, ssh_key, remote_path, active, status)
VALUES ('$nid', '$nname', '$nhost', $nport, '$nuser', '$nkey', '$npath', 1, 'unknown');
SQLEOF
    done <<< "$slaves"

    # 2. Exportar canales de comunicación
    local channels
    channels=$(db_query "SELECT name, channel_type, to_email, output_path, webhook_url,
                         include_nodes, frequency, report_time, report_day
                         FROM comm_channels WHERE active=1")

    while IFS='|' read -r cname ctype cemail cpath cwh cnodes cfreq ctime cday; do
        [ -z "$cname" ] && continue
        cat >> "$nodes_sql" <<SQLEOF
INSERT OR REPLACE INTO comm_channels (name, channel_type, to_email, output_path, webhook_url, include_nodes, frequency, report_time, report_day, active)
VALUES ('$cname', '$ctype', '$cemail', '$cpath', '$cwh', '$cnodes', '$cfreq', '$ctime', '$cday', 1);
SQLEOF
    done <<< "$channels"

    # 3. Exportar catálogo Samba compartido
    local samba
    samba=$(db_query "SELECT name, server, share, remote_path, username, password, domain, port
                      FROM samba_targets WHERE shared=1 AND active=1")

    while IFS='|' read -r sname sserver sshare srpath suser spass sdomain sport; do
        [ -z "$sname" ] && continue
        cat >> "$nodes_sql" <<SQLEOF
INSERT OR REPLACE INTO samba_targets (name, server, share, remote_path, username, password, domain, port, shared, origin_node, active)
VALUES ('$sname', '$sserver', '$sshare', '$srpath', '$suser', '$spass', '$sdomain', $sport, 1, 'handoff', 1);
SQLEOF
    done <<< "$samba"

    # Establecer rol master en el destino
    echo "UPDATE node_config SET node_role='master' WHERE id=1;" >> "$nodes_sql"

    # 4. Enviar y ejecutar en destino
    local remote_incoming="${target_path}/data/incoming"
    ssh_exec "$target_host" "$target_port" "$target_user" "$target_key" "mkdir -p ${remote_incoming}"

    if scp_to "$target_host" "$target_port" "$target_user" "$target_key" \
              "$nodes_sql" "${remote_incoming}/handoff.sql"; then

        ssh_exec "$target_host" "$target_port" "$target_user" "$target_key" \
            "sqlite3 '${target_path}/data/logmaster.db' < '${remote_incoming}/handoff.sql' && rm -f '${remote_incoming}/handoff.sql'"

        log_info "HANDOFF: Datos transferidos a $target_host"

        # 5. Notificar a todos los slaves el nuevo master
        local new_master_ip
        new_master_ip=$(ssh_exec "$target_host" "$target_port" "$target_user" "$target_key" \
            "hostname -I 2>/dev/null | awk '{print \$1}'" 2>/dev/null)
        [ -z "$new_master_ip" ] && new_master_ip="$target_host"

        while IFS='|' read -r nid nname nhost nport nuser nkey npath; do
            [ -z "$nid" ] && continue
            ssh_exec "$nhost" "$nport" "$nuser" "$nkey" \
                "sqlite3 '${npath}/data/logmaster.db' \"UPDATE node_config SET master_host='$new_master_ip' WHERE id=1\"" 2>/dev/null
            log_info "HANDOFF: Slave $nname redirigido a $new_master_ip"
        done <<< "$slaves"

        # 6. Degradar este nodo a slave o standalone
        role_change_execute "master" "slave"
        db_exec "UPDATE node_config SET master_host='$new_master_ip',
                 master_port=$target_port, master_user='$target_user',
                 master_ssh_key='$target_key', master_path='$target_path',
                 push_status=1 WHERE id=1"

        log_info "HANDOFF: Completado. Nuevo master: $target_host, este nodo ahora es slave"
        rm -f "$nodes_sql"
        return 0
    else
        log_error "HANDOFF: Error al transferir datos a $target_host"
        rm -f "$nodes_sql"
        return 1
    fi
}

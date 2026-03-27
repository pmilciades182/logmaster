#!/bin/bash
# ============================================================
# LogMaster v2.0 - Daemon de Sincronización
# Ejecutado por cron junto al dispatcher principal
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/functions.sh"
source "${SCRIPT_DIR}/lib/sync.sh"

db_init

if ! acquire_sync_lock; then
    exit 0
fi

trap 'release_sync_lock' EXIT

log_info "=== SYNC: Inicio de ciclo ==="

# Obtener rol y config del nodo
ROLE=$(get_node_role)

case "$ROLE" in

# ============================================================
# STANDALONE: no hacer nada
# ============================================================
standalone)
    log_info "SYNC: Nodo standalone, sincronización desactivada"
    ;;

# ============================================================
# SLAVE: enviar estado + recibir catálogo
# ============================================================
slave)
    NODE_ROW=$(get_node_config)
    IFS='|' read -r node_id node_name role master_host master_port \
        master_user master_key master_path sync_mode \
        sync_interval sync_samba push_status autonomous <<< "$NODE_ROW"

    # Verificar si toca sincronizar (respeta sync_interval)
    LAST_SYNC=$(db_get "SELECT last_sync FROM node_config WHERE id=1")
    SHOULD_SYNC=0

    if [ -z "$LAST_SYNC" ]; then
        SHOULD_SYNC=1
    else
        LAST_EPOCH=$(date -d "$LAST_SYNC" +%s 2>/dev/null || echo 0)
        NOW_EPOCH=$(date +%s)
        ELAPSED=$(( (NOW_EPOCH - LAST_EPOCH) / 60 ))
        [ "$ELAPSED" -ge "${sync_interval:-5}" ] && SHOULD_SYNC=1
    fi

    if [ "$SHOULD_SYNC" -eq 0 ]; then
        log_info "SYNC: Aún no toca sincronizar (intervalo: ${sync_interval}min)"
        exit 0
    fi

    # Intentar conexión al master
    MASTER_OK=0
    if [ -n "$master_host" ] && [ -n "$master_user" ]; then
        TEST_RESULT=$(sync_test_connection "$master_host" "$master_port" "$master_user" "$master_key" "$master_path")
        if [ "$TEST_RESULT" = "OK" ]; then
            MASTER_OK=1
        else
            log_warn "SYNC: $TEST_RESULT"
        fi
    fi

    if [ "$MASTER_OK" -eq 1 ]; then
        # Enviar estado al master
        sync_push_status

        # Recibir catálogo Samba si está habilitado
        if [ "$sync_samba" = "1" ]; then
            sync_pull_samba_catalog
        fi

        # Procesar archivos incoming (catálogo enviado por master)
        INCOMING_SQL="${SCRIPT_DIR}/data/incoming/samba_catalog.sql"
        if [ -f "$INCOMING_SQL" ]; then
            log_info "SYNC: Aplicando catálogo Samba recibido del master"
            sqlite3 "$LOGMASTER_DB" < "$INCOMING_SQL" 2>/dev/null
            rm -f "$INCOMING_SQL"
        fi
    else
        if [ "$sync_mode" = "mandatory" ] && [ "$autonomous" != "1" ]; then
            log_error "SYNC: Master no disponible y sync es obligatorio. Deteniendo operaciones."
            # En modo mandatory sin autonomía, desactivar schedules
            # (se reactivarán cuando el master responda)
            # NO hacemos esto automáticamente, solo registramos el warning
            log_error "SYNC: ADVERTENCIA - modo mandatory, master inaccesible"
        elif [ "$sync_mode" = "mandatory" ] && [ "$autonomous" = "1" ]; then
            log_warn "SYNC: Master no disponible (mandatory + autónomo), continuando operación local"
        else
            log_info "SYNC: Master no disponible (sync opcional), operando independientemente"
        fi
    fi
    ;;

# ============================================================
# MASTER: recolectar de slaves + procesar canales
# ============================================================
master)
    mkdir -p "${SCRIPT_DIR}/data/incoming"

    # Recolectar estado de todos los slaves
    sync_collect_all

    # Distribuir catálogo Samba a slaves
    sync_push_samba_all

    # Procesar canales de comunicación (reportes)
    process_channels

    # Limpiar datos antiguos de node_status (30 días)
    RETENTION=$(db_get "SELECT value FROM config WHERE key='log_retention_days'")
    RETENTION=${RETENTION:-30}
    db_exec "DELETE FROM node_status WHERE timestamp < datetime('now','localtime','-${RETENTION} days')"
    db_exec "DELETE FROM sync_log WHERE timestamp < datetime('now','localtime','-${RETENTION} days')"
    ;;

esac

log_info "=== SYNC: Ciclo completado ==="

exit 0

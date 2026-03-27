-- ============================================================
-- LogMaster v2.0 - Schema de Base de Datos
-- Sistema de transferencia con arquitectura Master/Slave
-- ============================================================

PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

-- ============================================================
-- Configuración general clave-valor
-- ============================================================

CREATE TABLE IF NOT EXISTS config (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

INSERT OR IGNORE INTO config (key, value) VALUES
    ('version', '2.0.0'),
    ('log_retention_days', '30'),
    ('lock_timeout_minutes', '10'),
    ('temp_dir', '/tmp/logmaster');

-- ============================================================
-- Identidad y rol del nodo
-- ============================================================

CREATE TABLE IF NOT EXISTS node_config (
    id               INTEGER PRIMARY KEY CHECK(id = 1),
    node_id          TEXT NOT NULL DEFAULT '',          -- UUID único del nodo
    node_name        TEXT NOT NULL DEFAULT '',          -- Nombre legible (ej: srv-contabilidad)
    node_role        TEXT NOT NULL DEFAULT 'standalone' -- standalone | master | slave
                     CHECK(node_role IN ('standalone','master','slave')),
    -- Conexión al master (solo para slaves)
    master_host      TEXT DEFAULT '',
    master_port      INTEGER DEFAULT 22,
    master_user      TEXT DEFAULT '',
    master_ssh_key   TEXT DEFAULT '',                   -- Ruta a llave privada SSH
    master_path      TEXT DEFAULT '',                   -- Ruta de LogMaster en el master
    -- Comportamiento de sincronización
    sync_mode        TEXT DEFAULT 'optional'            -- optional | mandatory
                     CHECK(sync_mode IN ('optional','mandatory')),
    sync_interval    INTEGER DEFAULT 5,                 -- Minutos entre sincronizaciones
    last_sync        TEXT DEFAULT NULL,
    -- Flags
    sync_samba_catalog INTEGER DEFAULT 1,               -- Recibir catálogo Samba del master
    push_status       INTEGER DEFAULT 1,                -- Enviar estado al master
    autonomous_on_fail INTEGER DEFAULT 1                -- Seguir operando si el master no responde
);

INSERT OR IGNORE INTO node_config (id, node_id) VALUES (1, lower(hex(randomblob(8))));

-- ============================================================
-- Nodos registrados (solo en master)
-- ============================================================

CREATE TABLE IF NOT EXISTS registered_nodes (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    node_id         TEXT NOT NULL UNIQUE,               -- UUID del slave
    node_name       TEXT NOT NULL DEFAULT '',
    host            TEXT NOT NULL,                       -- IP o hostname del slave
    port            INTEGER DEFAULT 22,
    ssh_user        TEXT NOT NULL DEFAULT '',
    ssh_key         TEXT DEFAULT '',                     -- Ruta a llave privada SSH
    remote_path     TEXT DEFAULT '',                     -- Ruta de LogMaster en el slave
    active          INTEGER DEFAULT 1,
    last_seen       TEXT DEFAULT NULL,
    last_sync       TEXT DEFAULT NULL,
    status          TEXT DEFAULT 'unknown'               -- online | offline | error | unknown
                    CHECK(status IN ('online','offline','error','unknown')),
    created_at      TEXT DEFAULT (datetime('now','localtime'))
);

-- ============================================================
-- Canales de comunicación (master define, recibe resúmenes)
-- ============================================================

CREATE TABLE IF NOT EXISTS comm_channels (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT NOT NULL UNIQUE,
    channel_type    TEXT NOT NULL DEFAULT 'email'
                    CHECK(channel_type IN ('email','file','webhook')),
    -- Para email
    to_email        TEXT DEFAULT '',
    -- Para file (reporte en disco)
    output_path     TEXT DEFAULT '',
    -- Para webhook
    webhook_url     TEXT DEFAULT '',
    -- Configuración
    include_nodes   TEXT DEFAULT '*',                    -- * = todos, o lista CSV de node_ids
    frequency       TEXT DEFAULT 'daily'
                    CHECK(frequency IN ('realtime','hourly','daily','weekly')),
    report_time     TEXT DEFAULT '08:00',                -- HH:MM para daily/weekly
    report_day      TEXT DEFAULT '1',                    -- Día semana para weekly (1=Lun)
    include_success INTEGER DEFAULT 1,
    include_errors  INTEGER DEFAULT 1,
    active          INTEGER DEFAULT 1,
    last_sent       TEXT DEFAULT NULL,
    created_at      TEXT DEFAULT (datetime('now','localtime'))
);

-- ============================================================
-- Historial de sincronizaciones
-- ============================================================

CREATE TABLE IF NOT EXISTS sync_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp       TEXT DEFAULT (datetime('now','localtime')),
    direction       TEXT CHECK(direction IN ('push','pull','collect')),
    remote_node_id  TEXT,
    remote_host     TEXT,
    status          TEXT CHECK(status IN ('success','error')),
    items_synced    INTEGER DEFAULT 0,
    message         TEXT,
    details         TEXT
);

-- ============================================================
-- Estado recibido de slaves (almacenado en master)
-- ============================================================

CREATE TABLE IF NOT EXISTS node_status (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    node_id         TEXT NOT NULL,
    node_name       TEXT,
    timestamp       TEXT DEFAULT (datetime('now','localtime')),
    hostname        TEXT,
    uptime          TEXT,
    dirs_count      INTEGER DEFAULT 0,
    dests_count     INTEGER DEFAULT 0,
    schedules_count INTEGER DEFAULT 0,
    last_exec_status TEXT,
    last_exec_time  TEXT,
    exec_ok_24h     INTEGER DEFAULT 0,
    exec_fail_24h   INTEGER DEFAULT 0,
    disk_usage      TEXT,
    cron_installed  INTEGER DEFAULT 0,
    raw_json        TEXT                                 -- Payload completo en JSON
);

-- ============================================================
-- Catálogo Samba compartido (master puede distribuir a slaves)
-- ============================================================

CREATE TABLE IF NOT EXISTS samba_targets (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    server      TEXT NOT NULL,
    share       TEXT NOT NULL,
    remote_path TEXT DEFAULT '/',
    username    TEXT,
    password    TEXT,
    domain      TEXT DEFAULT '',
    port        INTEGER DEFAULT 445,
    shared      INTEGER DEFAULT 0,                      -- 1 = compartir con slaves
    origin_node TEXT DEFAULT 'local',                   -- Nodo que lo creó
    active      INTEGER DEFAULT 1,
    created_at  TEXT DEFAULT (datetime('now','localtime')),
    updated_at  TEXT DEFAULT (datetime('now','localtime'))
);

-- ============================================================
-- Directorios fuente (maestro)
-- ============================================================

CREATE TABLE IF NOT EXISTS directories (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    source_path TEXT NOT NULL,
    active      INTEGER DEFAULT 1,
    created_at  TEXT DEFAULT (datetime('now','localtime')),
    updated_at  TEXT DEFAULT (datetime('now','localtime'))
);

-- Destinos por directorio (detalle N:N)
CREATE TABLE IF NOT EXISTS directory_destinations (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    directory_id    INTEGER NOT NULL REFERENCES directories(id) ON DELETE CASCADE,
    dest_type       TEXT NOT NULL DEFAULT 'samba' CHECK(dest_type IN ('samba','local')),
    samba_target_id INTEGER REFERENCES samba_targets(id) ON DELETE SET NULL,
    local_path      TEXT,
    remote_subdir   TEXT DEFAULT '',
    action          TEXT DEFAULT 'copy' CHECK(action IN ('copy','move')),
    active          INTEGER DEFAULT 1,
    created_at      TEXT DEFAULT (datetime('now','localtime'))
);

-- Filtros de archivos (patrones glob por directorio)
CREATE TABLE IF NOT EXISTS filters (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    directory_id INTEGER NOT NULL REFERENCES directories(id) ON DELETE CASCADE,
    pattern      TEXT NOT NULL,
    active       INTEGER DEFAULT 1
);

-- Programación de ejecuciones
CREATE TABLE IF NOT EXISTS schedules (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    directory_id     INTEGER NOT NULL REFERENCES directories(id) ON DELETE CASCADE,
    schedule_type    TEXT DEFAULT 'interval' CHECK(schedule_type IN ('interval','daily','weekly')),
    interval_minutes INTEGER DEFAULT 60,
    run_at_time      TEXT DEFAULT NULL,
    days_of_week     TEXT DEFAULT '1,2,3,4,5,6,7',
    last_run         TEXT DEFAULT NULL,
    next_run         TEXT DEFAULT NULL,
    active           INTEGER DEFAULT 1
);

-- Configuración de correo electrónico
CREATE TABLE IF NOT EXISTS email_config (
    id             INTEGER PRIMARY KEY CHECK(id = 1),
    smtp_server    TEXT DEFAULT '',
    smtp_port      INTEGER DEFAULT 587,
    use_tls        INTEGER DEFAULT 1,
    from_email     TEXT DEFAULT '',
    to_email       TEXT DEFAULT '',
    username       TEXT DEFAULT '',
    password       TEXT DEFAULT '',
    notify_success INTEGER DEFAULT 0,
    notify_error   INTEGER DEFAULT 1
);

INSERT OR IGNORE INTO email_config (id) VALUES (1);

-- Historial de ejecuciones (con nodo de origen)
CREATE TABLE IF NOT EXISTS execution_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp       TEXT DEFAULT (datetime('now','localtime')),
    node_id         TEXT DEFAULT 'local',
    node_name       TEXT DEFAULT '',
    directory_id    INTEGER,
    destination_id  INTEGER,
    source_path     TEXT,
    dest_label      TEXT,
    status          TEXT CHECK(status IN ('success','error','partial')),
    files_processed INTEGER DEFAULT 0,
    files_failed    INTEGER DEFAULT 0,
    message         TEXT,
    details         TEXT
);

-- ============================================================
-- Triggers
-- ============================================================

CREATE TRIGGER IF NOT EXISTS trg_directories_update
AFTER UPDATE ON directories
BEGIN
    UPDATE directories SET updated_at = datetime('now','localtime') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_samba_targets_update
AFTER UPDATE ON samba_targets
BEGIN
    UPDATE samba_targets SET updated_at = datetime('now','localtime') WHERE id = NEW.id;
END;

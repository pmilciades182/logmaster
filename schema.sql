-- ============================================================
-- LogMaster - Schema de Base de Datos
-- Sistema de transferencia de archivos a Samba / Local
-- ============================================================

PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

-- Configuración general clave-valor
CREATE TABLE IF NOT EXISTS config (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

INSERT OR IGNORE INTO config (key, value) VALUES
    ('version', '1.1.0'),
    ('log_retention_days', '30'),
    ('lock_timeout_minutes', '10'),
    ('temp_dir', '/tmp/logmaster');

-- Destinos Samba (catálogo reutilizable)
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
    active      INTEGER DEFAULT 1,
    created_at  TEXT DEFAULT (datetime('now','localtime')),
    updated_at  TEXT DEFAULT (datetime('now','localtime'))
);

-- Directorios fuente a monitorear (maestro)
CREATE TABLE IF NOT EXISTS directories (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    source_path TEXT NOT NULL,
    active      INTEGER DEFAULT 1,
    created_at  TEXT DEFAULT (datetime('now','localtime')),
    updated_at  TEXT DEFAULT (datetime('now','localtime'))
);

-- Destinos por directorio (detalle N:N)
-- Cada directorio fuente puede tener múltiples destinos,
-- cada destino puede ser tipo 'samba' o 'local'
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

-- Programación de ejecuciones (por directorio fuente)
CREATE TABLE IF NOT EXISTS schedules (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    directory_id     INTEGER NOT NULL REFERENCES directories(id) ON DELETE CASCADE,
    schedule_type    TEXT DEFAULT 'interval' CHECK(schedule_type IN ('interval','daily','weekly')),
    interval_minutes INTEGER DEFAULT 60,
    run_at_time      TEXT DEFAULT NULL,       -- HH:MM para daily/weekly
    days_of_week     TEXT DEFAULT '1,2,3,4,5,6,7', -- 1=Lun..7=Dom
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

-- Historial de ejecuciones (ahora guarda destino específico)
CREATE TABLE IF NOT EXISTS execution_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp       TEXT DEFAULT (datetime('now','localtime')),
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

-- Triggers
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

# LogMaster v2.0

Sistema de transferencia y sincronización de archivos para entornos empresariales Linux, con arquitectura Master/Slave y gestión centralizada.

## Descripción

LogMaster automatiza la copia y movimiento de archivos desde directorios fuente hacia destinos **Samba** o **locales**, con programación interna, filtrado por patrones glob y notificaciones por correo electrónico. Soporta despliegue en múltiples servidores con sincronización SSH.

## Características

- **Múltiples directorios fuente** con N destinos cada uno (Samba y/o local)
- **Filtros glob** por directorio (`*.pdf`, `log-2024*`, etc.)
- **Programación interna**: por intervalo, diaria o semanal (cron ejecuta cada minuto, LogMaster decide internamente)
- **Acciones por destino**: copiar o mover archivos
- **Notificaciones por email** con plantillas HTML (éxito y error)
- **Arquitectura Master/Slave/Standalone**:
  - **Master**: recolecta estado de slaves, distribuye catálogo Samba, gestiona canales de comunicación
  - **Slave**: envía estado al master, recibe catálogo Samba, opera de forma autónoma si pierde conexión
  - **Standalone**: operación independiente sin sincronización
- **Rotación segura de roles** con validación, handoff y detección de conflictos
- **Frontend de consola** interactivo con vista de árbol de directorios/destinos

## Requisitos

- Bash 4+
- SQLite3
- smbclient (para destinos Samba)
- curl (para notificaciones email)
- openssh-client (para sincronización Master/Slave)
- crontab

## Instalación

```bash
# Instalación standalone (por defecto)
make install

# Instalación como master
make install-master

# Instalación como slave
make install-slave

# Solo verificar dependencias sin instalar
make check
```

## Uso

```bash
# Abrir consola de administración
./logmaster-cli.sh

# Instalar en cron (también disponible desde el CLI, opción 8)
make cron-install

# Ver estado del sistema
make status
```

## Menú Principal (CLI)

| Opción | Función |
|--------|---------|
| 1 | Ver árbol de directorios, destinos, filtros y schedules |
| 2 | Gestionar directorios fuente y sus destinos |
| 3 | Gestionar catálogo de servidores Samba |
| 4 | Gestionar filtros de archivos por directorio |
| 5 | Gestionar programaciones (interval/daily/weekly) |
| 6 | Configurar notificaciones por email (SMTP) |
| 7 | Ver log de ejecuciones |
| 8 | Gestionar cron (instalar/desinstalar daemons) |
| 9 | Ejecución manual de transferencias |
| 10 | Red y Sincronización (Master/Slave) |

## Estructura del Proyecto

```
logmaster/
├── logmaster.sh          # Dispatcher principal (cron)
├── logmaster-sync.sh     # Daemon de sincronización (cron)
├── logmaster-cli.sh      # Frontend de consola interactivo
├── schema.sql            # Esquema de base de datos SQLite
├── Makefile              # Instalación y gestión
├── lib/
│   ├── functions.sh      # Funciones comunes (DB, Samba, email, etc.)
│   └── sync.sh           # Funciones de sincronización y roles
├── templates/
│   ├── success.html      # Plantilla email de éxito
│   └── error.html        # Plantilla email de error
├── data/
│   ├── logmaster.db      # Base de datos SQLite (generada)
│   └── incoming/         # Archivos recibidos del master/slaves
└── logs/
    └── logmaster.log     # Log de ejecución (generado)
```

## Base de Datos

Tablas principales:

| Tabla | Descripción |
|-------|-------------|
| `config` | Configuración clave-valor del sistema |
| `node_config` | Identidad y rol del nodo |
| `samba_targets` | Catálogo de servidores Samba |
| `directories` | Directorios fuente a monitorear |
| `directory_destinations` | Destinos por directorio (N:N) |
| `filters` | Patrones glob por directorio |
| `schedules` | Programaciones de ejecución |
| `email_config` | Configuración SMTP |
| `execution_log` | Historial de transferencias |
| `registered_nodes` | Slaves registrados (solo master) |
| `comm_channels` | Canales de comunicación (solo master) |
| `sync_log` | Historial de sincronizaciones |
| `node_status` | Estado recibido de slaves (solo master) |

## Sincronización Master/Slave

```
┌─────────────┐       SSH        ┌─────────────┐
│   MASTER    │◄────────────────►│   SLAVE 1   │
│             │  estado/catálogo  │             │
│  - Recolecta│       SSH        ├─────────────┤
│  - Distribuye│◄───────────────►│   SLAVE 2   │
│  - Reportes │                  │             │
└─────────────┘                  └─────────────┘
```

- Los slaves envían su estado al master periódicamente
- El master distribuye el catálogo Samba compartido a los slaves
- Los canales de comunicación generan reportes consolidados
- Los slaves pueden operar autónomamente si pierden conexión (`sync_mode: optional`)
- Rotación de roles segura con handoff y detección de conflictos

## Comandos Make

```bash
make help            # Mostrar ayuda
make install         # Instalación standalone
make install-master  # Instalación como master
make install-slave   # Instalación como slave
make deps            # Instalar dependencias
make check           # Verificar dependencias
make setup           # Crear directorios y permisos
make db              # Inicializar base de datos
make db-reset        # Reiniciar BD (elimina datos)
make ssh-keygen      # Generar llaves SSH para LogMaster
make cron-install    # Instalar en crontab
make cron-uninstall  # Desinstalar de crontab
make status          # Ver estado del sistema
make clean           # Limpiar logs y temporales
make uninstall       # Desinstalación completa
```

## Licencia

Uso interno empresarial.

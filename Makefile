################################################################
# LogMaster v2.0 - Makefile
# Sistema de Transferencia con arquitectura Master/Slave
################################################################

SHELL     := /bin/bash
PREFIX    := $(shell pwd)
DB_FILE   := $(PREFIX)/data/logmaster.db
LOG_DIR   := $(PREFIX)/logs
DATA_DIR  := $(PREFIX)/data

.PHONY: help install install-master install-slave setup deps check db \
        cron-install cron-uninstall clean uninstall status

help: ## Mostrar esta ayuda
	@echo ""
	@echo "  LogMaster v2.0 - Sistema de Transferencia de Archivos"
	@echo "  ====================================================="
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""

install: deps setup db ## Instalación base (standalone por defecto)
	@echo ""
	@echo "  ✓ Instalación completada (modo: standalone)"
	@echo ""
	@echo "  Próximos pasos:"
	@echo "    1. Ejecutar:  ./logmaster-cli.sh"
	@echo "    2. Configurar rol en menú 10 (Red y Sincronización)"
	@echo "    3. Configurar destinos, directorios, filtros"
	@echo "    4. Instalar en cron desde el CLI (opción 8)"
	@echo ""

install-master: deps setup db ## Instalar como nodo MASTER
	@sqlite3 $(DB_FILE) "UPDATE node_config SET node_role='master', node_name='$$(hostname)' WHERE id=1"
	@echo ""
	@echo "  ✓ Instalación como MASTER completada"
	@echo ""
	@echo "  Próximos pasos:"
	@echo "    1. Ejecutar:  ./logmaster-cli.sh"
	@echo "    2. Registrar slaves en menú 10 → opción 4"
	@echo "    3. Marcar destinos Samba como 'shared' para distribuir"
	@echo "    4. Configurar canales de comunicación"
	@echo "    5. Instalar cron (transferencias + sincronización)"
	@echo ""

install-slave: deps setup db ## Instalar como nodo SLAVE
	@sqlite3 $(DB_FILE) "UPDATE node_config SET node_role='slave', node_name='$$(hostname)' WHERE id=1"
	@echo ""
	@echo "  ✓ Instalación como SLAVE completada"
	@echo ""
	@echo "  Próximos pasos:"
	@echo "    1. Ejecutar:  ./logmaster-cli.sh"
	@echo "    2. Configurar conexión al master en menú 10 → opción 2"
	@echo "    3. Probar conexión SSH al master"
	@echo "    4. Instalar cron (transferencias + sincronización)"
	@echo ""

deps: ## Instalar dependencias del sistema
	@echo "  → Verificando dependencias..."
	@which sqlite3 > /dev/null 2>&1 || { \
		echo "  → Instalando sqlite3..."; \
		sudo apt-get update -qq && sudo apt-get install -y -qq sqlite3; \
	}
	@which smbclient > /dev/null 2>&1 || { \
		echo "  → Instalando smbclient..."; \
		sudo apt-get update -qq && sudo apt-get install -y -qq smbclient; \
	}
	@which curl > /dev/null 2>&1 || { \
		echo "  → Instalando curl..."; \
		sudo apt-get update -qq && sudo apt-get install -y -qq curl; \
	}
	@which ssh > /dev/null 2>&1 || { \
		echo "  → Instalando openssh-client..."; \
		sudo apt-get update -qq && sudo apt-get install -y -qq openssh-client; \
	}
	@echo "  ✓ Dependencias OK"

check: ## Verificar dependencias sin instalar
	@echo "  Verificando dependencias:"
	@which sqlite3   > /dev/null 2>&1 && echo "  ✓ sqlite3"    || echo "  ✗ sqlite3 (falta)"
	@which smbclient > /dev/null 2>&1 && echo "  ✓ smbclient"  || echo "  ✗ smbclient (falta)"
	@which curl      > /dev/null 2>&1 && echo "  ✓ curl"       || echo "  ✗ curl (falta)"
	@which ssh       > /dev/null 2>&1 && echo "  ✓ ssh"        || echo "  ✗ ssh (falta)"
	@which scp       > /dev/null 2>&1 && echo "  ✓ scp"        || echo "  ✗ scp (falta)"
	@which crontab   > /dev/null 2>&1 && echo "  ✓ crontab"    || echo "  ✗ crontab (falta)"

setup: ## Crear directorios y establecer permisos
	@mkdir -p $(DATA_DIR) $(DATA_DIR)/incoming $(LOG_DIR)
	@chmod +x $(PREFIX)/logmaster.sh
	@chmod +x $(PREFIX)/logmaster-cli.sh
	@chmod +x $(PREFIX)/logmaster-sync.sh
	@chmod +x $(PREFIX)/lib/functions.sh
	@chmod +x $(PREFIX)/lib/sync.sh
	@echo "  ✓ Directorios y permisos configurados"

db: setup ## Inicializar base de datos SQLite
	@if [ ! -f $(DB_FILE) ]; then \
		sqlite3 $(DB_FILE) < $(PREFIX)/schema.sql; \
		echo "  ✓ Base de datos creada: $(DB_FILE)"; \
	else \
		echo "  → Base de datos ya existe: $(DB_FILE)"; \
	fi

db-reset: ## Reiniciar base de datos (¡ELIMINA DATOS!)
	@echo -n "  ¿Seguro que desea reiniciar la BD? (s/N): " && read ans && [ $${ans:-N} = s ]
	@rm -f $(DB_FILE)
	@sqlite3 $(DB_FILE) < $(PREFIX)/schema.sql
	@echo "  ✓ Base de datos reiniciada"

ssh-keygen: ## Generar par de llaves SSH para LogMaster
	@if [ -f $$HOME/.ssh/logmaster_rsa ]; then \
		echo "  → Llave ya existe: $$HOME/.ssh/logmaster_rsa"; \
		echo "  Pública:"; \
		cat $$HOME/.ssh/logmaster_rsa.pub; \
	else \
		ssh-keygen -t rsa -b 4096 -f $$HOME/.ssh/logmaster_rsa -N "" -C "logmaster@$$(hostname)"; \
		echo "  ✓ Llaves generadas"; \
		echo "  Copie la llave pública en los servidores remotos:"; \
		cat $$HOME/.ssh/logmaster_rsa.pub; \
	fi

cron-install: ## Instalar ambos servicios en crontab
	@(crontab -l 2>/dev/null | grep -v "logmaster"; \
		echo "* * * * * $(PREFIX)/logmaster.sh >> $(LOG_DIR)/logmaster.log 2>&1"; \
		echo "* * * * * $(PREFIX)/logmaster-sync.sh >> $(LOG_DIR)/logmaster.log 2>&1") | crontab -
	@echo "  ✓ Transferencias y sincronización instalados en crontab"

cron-uninstall: ## Desinstalar de crontab
	@crontab -l 2>/dev/null | grep -v "logmaster" | crontab -
	@echo "  ✓ Desinstalado de crontab"

status: ## Mostrar estado del sistema
	@echo ""
	@echo "  Estado de LogMaster v2.0"
	@echo "  ─────────────────────────────"
	@if [ -f $(DB_FILE) ]; then \
		echo "  BD: $(DB_FILE) ($$(du -h $(DB_FILE) | cut -f1))"; \
		echo "  Rol: $$(sqlite3 $(DB_FILE) 'SELECT node_role FROM node_config WHERE id=1')"; \
		echo "  Nodo: $$(sqlite3 $(DB_FILE) 'SELECT node_name FROM node_config WHERE id=1')"; \
		echo "  Destinos Samba:  $$(sqlite3 $(DB_FILE) 'SELECT COUNT(*) FROM samba_targets')"; \
		echo "  Directorios:     $$(sqlite3 $(DB_FILE) 'SELECT COUNT(*) FROM directories')"; \
		echo "  Destinos asig.:  $$(sqlite3 $(DB_FILE) 'SELECT COUNT(*) FROM directory_destinations')"; \
		echo "  Filtros:         $$(sqlite3 $(DB_FILE) 'SELECT COUNT(*) FROM filters')"; \
		echo "  Programaciones:  $$(sqlite3 $(DB_FILE) 'SELECT COUNT(*) FROM schedules')"; \
		echo "  Log ejecución:   $$(sqlite3 $(DB_FILE) 'SELECT COUNT(*) FROM execution_log')"; \
		echo "  Slaves reg.:     $$(sqlite3 $(DB_FILE) 'SELECT COUNT(*) FROM registered_nodes')"; \
		echo "  Log sync:        $$(sqlite3 $(DB_FILE) 'SELECT COUNT(*) FROM sync_log')"; \
	else \
		echo "  BD: No inicializada"; \
	fi
	@echo -n "  Cron transfer: " && (crontab -l 2>/dev/null | grep -q "logmaster.sh" && echo "Instalado" || echo "No")
	@echo -n "  Cron sync:     " && (crontab -l 2>/dev/null | grep -q "logmaster-sync.sh" && echo "Instalado" || echo "No")
	@echo ""

clean: ## Limpiar logs y archivos temporales
	@rm -f $(LOG_DIR)/*.log
	@rm -f /tmp/logmaster*
	@rm -rf $(DATA_DIR)/incoming/*
	@echo "  ✓ Logs y temporales limpiados"

uninstall: cron-uninstall ## Desinstalar completamente (cron + BD + logs)
	@echo -n "  ¿Eliminar TODA la configuración y datos? (s/N): " && read ans && [ $${ans:-N} = s ]
	@rm -f $(DB_FILE)
	@rm -rf $(LOG_DIR) $(DATA_DIR) /tmp/logmaster*
	@echo "  ✓ LogMaster desinstalado completamente"

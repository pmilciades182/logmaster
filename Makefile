################################################################
# LogMaster - Makefile
# Sistema de Transferencia de Archivos a Samba
################################################################

SHELL     := /bin/bash
PREFIX    := $(shell pwd)
DB_FILE   := $(PREFIX)/data/logmaster.db
LOG_DIR   := $(PREFIX)/logs
DATA_DIR  := $(PREFIX)/data

.PHONY: help install setup deps check db cron-install cron-uninstall clean uninstall status test-samba

help: ## Mostrar esta ayuda
	@echo ""
	@echo "  LogMaster - Sistema de Transferencia de Archivos"
	@echo "  ================================================"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""

install: deps setup db ## Instalación completa (dependencias + BD + permisos)
	@echo ""
	@echo "  ✓ Instalación completada"
	@echo ""
	@echo "  Próximos pasos:"
	@echo "    1. Ejecutar:  ./logmaster-cli.sh"
	@echo "    2. Configurar destinos Samba"
	@echo "    3. Agregar directorios y filtros"
	@echo "    4. Configurar programación"
	@echo "    5. Instalar en cron desde el CLI (opción 8)"
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
	@echo "  ✓ Dependencias OK"

check: ## Verificar dependencias sin instalar
	@echo "  Verificando dependencias:"
	@which sqlite3  > /dev/null 2>&1 && echo "  ✓ sqlite3"   || echo "  ✗ sqlite3 (falta)"
	@which smbclient > /dev/null 2>&1 && echo "  ✓ smbclient" || echo "  ✗ smbclient (falta)"
	@which curl     > /dev/null 2>&1 && echo "  ✓ curl"      || echo "  ✗ curl (falta)"
	@which crontab  > /dev/null 2>&1 && echo "  ✓ crontab"   || echo "  ✗ crontab (falta)"

setup: ## Crear directorios y establecer permisos
	@mkdir -p $(DATA_DIR) $(LOG_DIR)
	@chmod +x $(PREFIX)/logmaster.sh
	@chmod +x $(PREFIX)/logmaster-cli.sh
	@chmod +x $(PREFIX)/lib/functions.sh
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

cron-install: ## Instalar en crontab (cada 1 minuto)
	@(crontab -l 2>/dev/null | grep -v "logmaster.sh"; \
		echo "* * * * * $(PREFIX)/logmaster.sh >> $(LOG_DIR)/logmaster.log 2>&1") | crontab -
	@echo "  ✓ Instalado en crontab"

cron-uninstall: ## Desinstalar de crontab
	@crontab -l 2>/dev/null | grep -v "logmaster.sh" | crontab -
	@echo "  ✓ Desinstalado de crontab"

status: ## Mostrar estado del sistema
	@echo ""
	@echo "  Estado de LogMaster"
	@echo "  ─────────────────────────────"
	@if [ -f $(DB_FILE) ]; then \
		echo "  BD: $(DB_FILE) ($$(du -h $(DB_FILE) | cut -f1))"; \
		echo "  Destinos Samba: $$(sqlite3 $(DB_FILE) 'SELECT COUNT(*) FROM samba_targets')"; \
		echo "  Directorios:    $$(sqlite3 $(DB_FILE) 'SELECT COUNT(*) FROM directories')"; \
		echo "  Filtros:        $$(sqlite3 $(DB_FILE) 'SELECT COUNT(*) FROM filters')"; \
		echo "  Programaciones: $$(sqlite3 $(DB_FILE) 'SELECT COUNT(*) FROM schedules')"; \
		echo "  Log entradas:   $$(sqlite3 $(DB_FILE) 'SELECT COUNT(*) FROM execution_log')"; \
	else \
		echo "  BD: No inicializada"; \
	fi
	@echo -n "  Cron: " && (crontab -l 2>/dev/null | grep -q "logmaster.sh" && echo "Instalado" || echo "No instalado")
	@echo ""

clean: ## Limpiar logs y archivos temporales
	@rm -f $(LOG_DIR)/*.log
	@rm -f /tmp/logmaster*
	@echo "  ✓ Logs y temporales limpiados"

uninstall: cron-uninstall ## Desinstalar completamente (cron + BD + logs)
	@echo -n "  ¿Eliminar TODA la configuración y datos? (s/N): " && read ans && [ $${ans:-N} = s ]
	@rm -f $(DB_FILE)
	@rm -rf $(LOG_DIR) $(DATA_DIR) /tmp/logmaster*
	@echo "  ✓ LogMaster desinstalado completamente"

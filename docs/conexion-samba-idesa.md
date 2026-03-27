# Conexión Samba - IDESA

## Servidor

| Campo     | Valor            |
|-----------|------------------|
| Servidor  | 192.168.24.170   |
| Puerto    | 445              |
| Usuario   | idesasvr         |
| Dominio   | —                |

## Credenciales

Almacenadas en `/mnt/24.170/.credentials.pwd` en el servidor `mlidsvrwas01`.

> Las credenciales no se versionan. Configurarlas directamente en LogMaster via CLI (Samba → Editar destino).

## Recurso configurado en LogMaster

| ID | Nombre           | Recurso   | Ruta |
|----|------------------|-----------|------|
| 1  | IDESA - Facturas | facturas  | /    |

## Mounts disponibles en mlidsvrwas01 (/etc/fstab)

| Recurso compartido              | Punto de montaje                                    |
|---------------------------------|-----------------------------------------------------|
| `//192.168.24.170/facturas`     | `/var/MEDIA/IMAGENES/FacturasProveedores`           |
| `//192.168.24.170/ComunicacionSegmentada` | `/var/MEDIA/IMAGENES/comunicacionSegmentada` |
| `//192.168.24.170/LimpiezaLotes`| `/var/MEDIA/IMAGENES/LimpiezaLotes`                 |
| `//192.168.24.170/Electrificacion` | `/var/MEDIA/IMAGENES/Electrificacion`            |
| `//192.168.24.170/AutogestionImpuestos` | `/var/MEDIA/IMAGENES/AutogestionImpuestos`  |
| `//192.168.24.170/encuestas`    | `/var/MEDIA/ENCUESTAS`                              |
| `//192.168.24.170/Alquileres`   | `/var/MEDIA/IMAGENES/Alquileres`                    |
| `//192.168.24.170/Archivo`      | `/var/MEDIA/IMAGENES/Archivo`                       |
| `//192.168.24.170/LoteProgramado/contracts` | `/mnt/24.170/contracts`                 |
| `//192.168.24.170/LoteProgramado/attachments` | `/mnt/24.170/attachments`             |

## Notas

- Credenciales compartidas entre todos los mounts via `/mnt/24.170/.credentials.pwd`
- El share `facturas` también usa `/etc/samba/24.170-facturas.smb` para algunos mounts
- Conexión verificada el 2026-03-27

# Servicios

Ficha de cada pieza: qué resuelve, cómo está montada y qué hay que saber
para operarla.

---

## AdGuard Home — DNS con filtrado

**Resuelve:** publicidad y telemetría bloqueadas para toda la casa, en el
router y no en cada dispositivo. Una TV o un móvil ajeno no admiten un
bloqueador; el DNS sí los cubre.

| | |
|---|---|
| Imagen | `adguard/adguardhome:latest` |
| Red | `network_mode: host` |
| Puertos | `53/udp`, `53/tcp` (DNS) · `80/tcp` (interfaz web) |
| Datos | `./work`, `./conf` |

**Upstreams por DoH.** Quad9 y Cloudflare en modo `parallel`: se lanzan
las dos consultas y gana la que responda antes. Si un proveedor se cae, la
resolución no se detiene. DNSSEC activado, y `bootstrap_dns` en IP directa
porque hay que resolver el nombre de los propios upstreams antes de poder
usarlos.

**Split DNS hacia Tailscale.** `[/ts.net/]100.100.100.100` manda las
consultas `*.ts.net` al resolutor de Tailscale.

**Ojo con el puerto 80.** Al ir en modo host, la interfaz web de AdGuard
ocupa el 80 de la máquina entera. Ver [incidencias](incidencias.md).

---

## Vaultwarden — gestor de contraseñas

**Resuelve:** las contraseñas de la familia, sincronizadas entre
dispositivos, sin cuota mensual y sin que la bóveda viva en un servidor
ajeno. Compatible con los clientes oficiales de Bitwarden.

| | |
|---|---|
| Imagen | `vaultwarden/server:latest` |
| Puerto | `127.0.0.1:8080` → `80` del contenedor |
| Datos | `./vw-data` (SQLite + clave RSA + adjuntos) |
| Acceso | `https://<host>.<tailnet>.ts.net` vía `tailscale serve` |

**No habla TLS.** Escucha HTTP plano; quien termina TLS es tailscaled. Por
eso el puerto se publica en loopback: expuesto en `0.0.0.0` sería una
bóveda accesible sin cifrar desde toda la red local.

**Registro cerrado.** `SIGNUPS_ALLOWED=false`; las cuentas se crean por
invitación por correo (SMTP con contraseña de aplicación de Google).

**`DOMAIN` es crítico.** De ahí sale el RP ID de WebAuthn. Cambiarlo
invalida todas las passkeys registradas. Ver [incidencias](incidencias.md).

**Contenido de `/data`:**

| Fichero | Qué es | ¿Backup? |
|---|---|---|
| `db.sqlite3` (+ `-wal`, `-shm`) | La bóveda | Sí, con `.backup` |
| `rsa_key.pem` | Clave privada del servidor, firma los JWT | Sí |
| `attachments/` | Adjuntos de los ítems | Sí, si existe |
| `sends/` | Ficheros de Bitwarden Send | Sí, si existe |
| `config.json` | Ajustes del panel de administración | Sí, si existe |
| `icon_cache/`, `tmp/` | Caché | No, se regenera |

---

## Vault App — API de finanzas personales

**Resuelve:** el backend de una aplicación propia de finanzas personales
(la app móvil va en su propio repositorio). Sustituyó a un esquema de
exportar un JSON cifrado a mano, que solo estaba tan al día como la última
vez que uno se acordaba de hacerlo.

| | |
|---|---|
| Imagen | Build propia (Node 22 Alpine, Fastify) |
| Puerto | `127.0.0.1:3000` |
| Base de datos | PostgreSQL 16 Alpine, **sin puerto publicado** |
| Acceso | `https://<host>.<tailnet>.ts.net:8443` |

**HTTPS no es opcional.** Android bloquea el tráfico en claro desde la API
28. Un endpoint `http://` obligaría a una excepción en el manifiesto de la
app; `tailscale serve` da un certificado real y el problema desaparece.

**Trabajos programados en proceso.** La API lleva su propio planificador
(`node-cron`): cotizaciones cada 15 min, velas intradía cada hora,
mantenimiento diario a las 00:15 y `pg_dump` a las 03:30. Un segundo
contenedor solo para esto serían más piezas de las que el trabajo
justifica.

**Autenticación por token.** Cabecera `Authorization: Bearer`, token de 32
bytes en hexadecimal. Es un servicio de un solo usuario detrás de una VPN:
montar OAuth sería disfraz, no seguridad.

---

## Bot de Telegram — monitorización

**Resuelve:** saber que algo se ha caído sin tener que mirar. Es toda la
observabilidad del montaje.

| | |
|---|---|
| Ejecución | systemd (`homelab-bot.service`), venv de Python |
| Alertas | CPU, RAM, disco, temperatura, servicios caídos |
| Antirruido | Cooldown de 15 min por causa |

Documentación completa en [`bot/README.md`](../bot/README.md).

---

## Cockpit — panel del sistema

Interfaz web de administración del host en el `:9090`: logs, servicios,
almacenamiento, actualizaciones y terminal. Viene con Ubuntu y se activa
con `systemctl enable --now cockpit.socket`.

Es el único servicio que escucha en `0.0.0.0`, y es una decisión
consciente a medias: es cómodo desde la LAN, pero lo correcto sería
publicarlo también por `tailscale serve` y cerrarlo a loopback. Está en la
lista de pendientes.

---

## Tailscale — red y TLS

Ver [`tailscale/README.md`](../tailscale/README.md).

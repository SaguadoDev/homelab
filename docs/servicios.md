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

## openGym — entrenamientos y peso corporal

**Resuelve:** el registro de gimnasio de dos personas (series, repeticiones,
progresión y peso corporal) sin suscripción y sin que el historial viva en
el servidor de una empresa que puede cerrar. Sustituye a Hevy, del que
además importa el historial.

| | |
|---|---|
| Imágenes | `registry.gitlab.com/duartesantos8/opengym/{web,api}` |
| Puerto | `127.0.0.1:8081` → `80` del contenedor `web` |
| Datos | `./data` (JSON planos, sin base de datos) · `./media` (no se respalda) |
| Acceso | `https://<host>.<tailnet>.ts.net:8444` vía `tailscale serve` |

**El repositorio oficial está en GitLab, no en GitHub.** La cuenta
`DuarteSantos8` de GitHub fue suspendida y su mirror más difundido apunta a
imágenes en `ghcr.io` que ya no existen, así que `docker compose pull`
contra él falla. El origen bueno es `gitlab.com/DuarteSantos8/opengym`.

**Versión fijada, no `:latest`.** Ver
[decisiones §9](decisiones.md#9-opengym-con-la-versión-fijada).

**`RP_ID` es crítico**, igual que el `DOMAIN` de Vaultwarden: de ahí sale el
RP ID de WebAuthn y cambiarlo invalida todas las passkeys registradas.
`ORIGIN` sí lleva el puerto; `RP_ID` no. Ver [incidencias](incidencias.md).

**Un perfil es una passkey, y no se puede añadir una segunda.** La API solo
tiene `/api/register/*`, que crea un perfil nuevo; no existe ningún
endpoint para registrar otra credencial en uno existente. Tampoco hay
contraseña de recuperación. Así que la única resiliencia posible es que esa
passkey esté sincronizada en un gestor (Vaultwarden, el llavero del
sistema) — el respaldo salva los datos, no el acceso. Es el requisito de
operación más importante del servicio.

Si aun así se pierde, el historial se puede trasplantar a un perfil nuevo:
[operaciones → recuperar un perfil](operaciones.md#recuperar-un-perfil-cuya-passkey-se-ha-perdido).
Ojo con que `INVITE_ONLY=1` bloquea el registro y el admin que emite los
códigos es justo el que perdió la llave.

**El login usa `allowCredentials: []`** (flujo de credencial descubrible).
El servidor no manda ninguna lista de candidatas, así que el dispositivo
solo ofrece la passkey si su propio gestor de credenciales la tiene. En
Android eso significa Android 14+ con el gestor dado de alta como proveedor
de llaves de acceso; si no, la pantalla de login sale vacía y no hay nada
que elegir.

**Instancia cerrada.** `INVITE_ONLY=1`, `ALLOW_GUEST=0` y `ADMIN_UIDS` con
el id del administrador. Por defecto openGym trae registro abierto, sin
administrador y con botón de invitado; los tres valores hay que ponerlos a
mano. El id no existe hasta que hay un perfil, así que la primera vuelta se
levanta sin ellos. Procedimiento en `services/opengym/.env.example`.

**El administrador ve los datos de los demás perfiles**: historial de
entrenamientos y peso corporal. Es un panel de administración de instancia,
no de sistema, y conviene que quien comparta la instancia lo sepa.

**Tres contenedores, uno de ellos termina.** `opengym-media` descarga una
sola vez los ~140 MB de imágenes y GIFs de los ejercicios (que no viajan
dentro de la imagen: el proyecto no los redistribuye) y sale con código 0.
A partir de ahí quien los sirve es `web`, que los tiene montados en solo
lectura; por eso depende de él con `service_completed_successfully`. Su
estado sano es `Exited (0)`: el listado del bot lo marca en blanco, no en
rojo, y las alertas no lo vigilan a propósito.

**Las notificaciones push funcionan sin exponer nada.** La push sale del
servidor hacia FCM/APNs (conexión saliente) y el móvil la recibe por su
propia conexión. Para abrir la aplicación al tocarla sí hay que estar en el
tailnet.

**Contenido de `/data`:**

| Fichero | Qué es | ¿Backup? |
|---|---|---|
| `db.json` | Perfiles y claves **públicas** de las passkeys | Sí |
| `state-<uid>.json` | Plan, entrenamientos, peso y ajustes de cada usuario | Sí |
| `secret` | Clave con la que se firman las cookies de sesión | Sí |
| `vapid.json` | Claves de las notificaciones push | Sí |
| `audit.log` | Registro de actividad | Sí |
| `../media/` | Imágenes y GIFs de los ejercicios | No, se redescarga |

**Lo que no tiene, viniendo de Hevy:** medidas corporales, fotos de
progreso, notas por ejercicio, calculadora de discos, aplicación de reloj y
sincronización con Apple Health o Google Fit. Y el soporte sin conexión
está anunciado pero tiene una incidencia abierta en el proyecto: sin
tailnet, la aplicación no tira de caché.

---

## Armario — API del armario digital

**Resuelve:** el respaldo y la sincronización de una aplicación Android de
armario digital (dar de alta prendas con foto, componer conjuntos y
generarlos). La aplicación funciona entera sin red porque su SQLite local es
la fuente de verdad; esta API es **espejo y copia buena**, no fuente de
verdad.

| | |
|---|---|
| Imagen | construida aquí (`Dockerfile` en el repo de la aplicación) |
| Puerto | `127.0.0.1:3001` |
| Datos | base `armario` en la instancia PG16 compartida · `./data/prendas` (los WebP) |
| Acceso | `https://<host>.<tailnet>.ts.net:8445` vía `tailscale serve` |

**Reutiliza la instancia de PostgreSQL que ya existe**, con base de datos y
rol propios (`armario` / `armario_user`), en vez de levantar otro contenedor.
Un segundo Postgres duplicaría memoria en una máquina modesta y duplicaría la
ruta de copias.

**El despliegue vive dentro del clon del repo de la aplicación**, no en un
directorio aparte: el `docker-compose.yml` está versionado ahí y el `.env`,
`data/prendas/` y `logs/` cuelgan del mismo sitio, bloqueados por su
`.gitignore`. Es el patrón de Vault App. Se llegó a ello después de probar lo
contrario: con el compose en un directorio de despliegue y el código en otro
había **dos copias del mismo fichero**, y se desincronizaron a la primera.
Peaje: un `git clean -xfd` ahí dentro se lleva las fotos y el `.env`.

**Las imágenes van a disco y las filas guardan punteros.** Nada de base64 en
columnas: con las fotos dentro de las filas, el `pg_dump` nocturno pasaría de
~1 MB a ~40 MB cifrados y subidos a Drive cada noche, en lugar de copiar
ficheros que solo cambian cuando se cataloga algo.

**Las fotos las sirve la API con comprobación de JWT**, nunca
`tailscale serve` directamente. El tailnet no es la autenticación: estar
dentro de la red no es una credencial, y el endpoint de imágenes comprueba
además que la prenda sea de quien la pide, no solo que el fichero exista.

**JWT propio con refresh de larga duración, no passkeys.** Es una decisión
tomada *por* la cicatriz de este montaje: WebAuthn ata la credencial al RP ID
del origen y cambiar de URL las invalida sin migración. Para un armario no
compensa ese riesgo, y además la aplicación promete no volver a enseñar la
pantalla de acceso salvo reinstalación.

**Sin endpoint de registro.** La usuaria se crea a mano desde el servidor:

```bash
docker compose exec armario-api node dist/server/src/crear-usuario.js <usuario> '<contraseña>'
```

Lanzarlo otra vez con el mismo usuario cambia la contraseña. Una ruta pública
de alta sería una puerta más que vigilar en un servicio de una sola persona.

**Proxy a Gemini para etiquetar la ropa.** La clave vive en el `.env` del
servidor, nunca en el APK, que es donde acabaría con la aplicación llamando
directamente a la API de Google. De paso permite cambiar de modelo sin
recompilar. Es opcional por diseño: sin clave el endpoint responde `503` con
un motivo y la aplicación sigue con el formulario manual.

**El borrado es blando en la fila y duro en el fichero.** La fila se queda
con su `deleted_at` —es lo que propaga el borrado a un dispositivo que estuvo
semanas sin red—, pero el WebP se borra: los datos borrados no se reutilizan
y guardarlos engordaría la copia nocturna, que sube el directorio entero cada
noche. Hay un script para cuadrar disco y base si alguna vez se descuadran:

```bash
docker compose exec armario-api node dist/server/src/limpiar-huerfanas.js            # en seco
docker compose exec armario-api node dist/server/src/limpiar-huerfanas.js --de-verdad
```

**`/health` comprueba la base de datos**, no solo que el proceso responde. Un
contenedor vivo que no puede escribir es justo el fallo que un `200 OK` a
secas se traga, y el que dejaría al móvil sin sincronizar en silencio. El bot
lo distingue con un estado propio, `Sin base de datos 🟡`, que sí alerta.

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

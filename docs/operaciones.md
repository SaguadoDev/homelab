# Operaciones

Cómo hacer cada cosa. Escrito para el yo de dentro de seis meses, que no
se acordará de nada.

## Convenciones

Cada servicio vive en su directorio con su `docker-compose.yml`. Todos los
comandos se ejecutan desde ese directorio.

```
/home/homelab/
├── homelab/        <- este repo (configuración versionada)
├── adguard/        <- servicios en ejecución, con sus datos
├── vaultwarden/
├── vault_app/
├── opengym/
├── armario/        <- el clon del repo de la app: aquí SÍ coinciden
└── bot/
```

El repo **no** es el directorio de ejecución: aquí está la configuración
sin datos ni secretos. Al cambiar algo, se edita en el repo y se copia al
directorio de ejecución (o al revés, y se hace commit).

**Armario es la excepción**, y a propósito: su directorio de ejecución es el
clon del repo de su propia aplicación, con el `docker-compose.yml`
versionado ahí y el `.env`, `data/` y `logs/` ignorados por su `.gitignore`.
Se llegó a eso después de probar lo contrario y acabar con dos copias del
mismo compose que se desincronizaron a la primera. Lo que hay en
`services/armario/` de este repo es una copia de referencia, saneada. Peaje
del montaje: un `git clean -xfd` en ese clon se lleva las fotos y el `.env`.

---

## Estado general

```bash
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
systemctl status homelab-bot
tailscale status
tailscale serve status
ss -tlnp                       # quién escucha realmente, y en qué interfaz
```

Desde el móvil, `/servicios` en el bot da lo mismo resumido.

---

## Arrancar, parar, actualizar

```bash
cd ~/vaultwarden

docker compose up -d              # levantar o aplicar cambios del compose
docker compose restart            # reiniciar sin releer el compose
docker compose logs -f --tail=100 # seguir los logs
docker compose down               # parar y eliminar los contenedores
```

Actualizar a la última imagen:

```bash
docker compose pull && docker compose up -d
docker image prune -f             # limpiar las imágenes viejas
```

**Antes de actualizar Vaultwarden, lanza una copia a mano.** Una migración
de esquema no se deshace:

```bash
sudo ~/homelab/scripts/backup-vaultwarden.sh
```

---

## Publicar un servicio nuevo en el tailnet

1. Que escuche en loopback: `ports: - "127.0.0.1:PUERTO:PUERTO_INTERNO"`.
2. Elegir un puerto HTTPS libre en el tailnet (443, 8443, 8444 y 8445
   están cogidos).
3. Publicarlo:

```bash
sudo tailscale serve --bg --https=<PUERTO_TLS> http://127.0.0.1:<PUERTO>
tailscale serve status
```

4. Comprobar que el camino viejo está cerrado:

```bash
curl --max-time 5 http://<IP_LAN>:<PUERTO>/    # debe fallar
```

Quitar una publicación:

```bash
sudo tailscale serve --https=<PUERTO_TLS> off
```

---

## Añadir un dispositivo al tailnet

Instalar Tailscale en el dispositivo, `tailscale up` y autenticarse con la
misma cuenta. Aparece en `tailscale status` y ya resuelve
`<host>.<tailnet>.ts.net`.

Para salir a internet por casa (nodo de salida): en el cliente,
seleccionar el servidor como *exit node*. El servidor ya anuncia
`0.0.0.0/0` y `::/0`; la ruta tiene que estar aprobada en la consola de
administración de Tailscale.

---

## DNS

```bash
# ¿Resuelve AdGuard?
dig @<IP_LAN> ejemplo.com +short

# ¿Y los nombres del tailnet? (regla split-DNS)
dig @<IP_LAN> <host>.<tailnet>.ts.net +short

# El host NO usa AdGuard, a propósito
resolvectl status | grep -A2 "Current DNS Server"
```

Interfaz web de AdGuard: `http://<IP_LAN>` (puerto 80).

Si AdGuard se cae, la casa se queda sin DNS. El servidor no: resuelve por
1.1.1.1. Desde él se puede diagnosticar y levantar el contenedor.

---

## Base de datos de Vault App

```bash
cd ~/vault_app/server

# Consola
docker compose exec postgres psql -U vault -d vault

# Volcado manual
docker compose exec -T postgres \
  pg_dump --format=custom --no-owner -U vault -d vault > manual.dump

# Migraciones
docker compose exec api node dist/server/src/scripts/migrate.js
```

---

## openGym

### Primera instalación

El id de administrador no existe hasta que hay un perfil, así que la
instancia se cierra en dos vueltas:

```bash
cd ~/opengym                       # compose y .env vienen de services/opengym/

# 1ª vuelta: abierta, para poder registrarse
docker compose pull && docker compose up -d
#    el contenedor `media` descarga ~140 MB y termina; es normal que salga
#    como "Exited (0)" en docker ps -a

# Registrar el perfil propio desde https://<host>.<tailnet>.ts.net:8444
jq -r '.users[] | "\(.id)  \(.name)"' data/db.json

# 2ª vuelta: cerrarla
#   ADMIN_UIDS=<el id de arriba>
#   INVITE_ONLY=1
#   ALLOW_GUEST=0
docker compose up -d
```

El código de invitación para la segunda persona sale de **Ajustes → Panel
de administración**, ya dentro de la aplicación.

**`RP_ID` se decide antes de registrar nada.** Cambiarlo después invalida
todas las passkeys: no hay migración. Ver [incidencias](incidencias.md).

### Actualizar

openGym va con la versión fijada, no con `:latest`
([decisiones §9](decisiones.md#9-opengym-con-la-versión-fijada)), así que
un `docker compose pull` a secas no trae nada nuevo. El procedimiento es:

```bash
# 1. Leer qué cambia
#    https://gitlab.com/DuarteSantos8/opengym/-/releases
# 2. Copia a mano ANTES de tocar nada (root: los datos son root:root 0600)
sudo ~/opengym/backup-opengym.sh
# 3. Subir la etiqueta en docker-compose.yml (las dos, web y api)
docker compose pull && docker compose up -d
docker compose logs -f --tail=50
```

El origen bueno es **GitLab**. El repositorio de GitHub que más circula es
un mirror congelado cuyo compose apunta a imágenes de `ghcr.io` que ya no
existen.

### Si alguien no puede entrar

Casi siempre es una de tres:

1. **No está en el tailnet.** Sin Tailscale conectado el servidor no
   existe para ese dispositivo. `tailscale status` en el móvil.
2. **`RP_ID` u `ORIGIN` no cuadran** con la URL por la que se entra.
   `ORIGIN` lleva el puerto, `RP_ID` no.
3. **La passkey no está donde se registró.** No hay contraseña de
   recuperación. Si se perdió el dispositivo y la credencial no estaba
   sincronizada en un gestor, el único camino es borrar ese perfil desde
   el panel de administración y volver a registrarlo — el historial se
   pierde salvo que se restaure de una copia.

### Recuperar un perfil cuya passkey se ha perdido

**openGym no permite añadir una segunda passkey a un perfil.** La API solo
tiene `/api/register/*`, que crea uno nuevo: un perfil es una credencial,
para siempre. Si esa credencial desaparece no hay "olvidé mi contraseña",
pero los datos son ficheros planos y se pueden trasplantar.

Procedimiento probado de punta a punta en una instancia desechable.

**La trampa que hay que ver venir:** con `INVITE_ONLY=1` el registro
devuelve `403 a valid invite code is required`, y quien emite los códigos
es el administrador — es decir, justo quien acaba de perder la llave. La
instancia se cierra sobre sí misma. Por eso el primer paso es abrirla.

Todo lleva `sudo`: los contenedores escriben `./data` como `root:root` con
permisos `0600`.

```bash
cd ~/opengym

# 1. Copia antes de tocar nada, y anota el uid viejo
sudo ./backup-opengym.sh
sudo jq -r '.users[] | "\(.id)  \(.name)"' data/db.json

# 2. Abrir el registro: comentar INVITE_ONLY en .env
docker compose up -d

# 3. Registrar un perfil nuevo desde el navegador, con la passkey nueva.
#    Sale con un uid distinto: es aleatorio en cada registro.
sudo jq -r '.users[] | "\(.id)  \(.name)"' data/db.json

# 4. Trasplantar el historial. NO hace falta reiniciar: el estado se lee
#    de disco en cada petición. Basta con recargar la página.
sudo mv data/state-<uid-viejo>.json data/state-<uid-nuevo>.json

# 5. Volver a cerrar: ADMIN_UIDS=<uid-nuevo> e INVITE_ONLY=1 en .env
docker compose up -d
```

Queda un perfil huérfano —sin datos, con una credencial que ya no existe—
porque el panel de administración solo sabe *deshabilitar*, no borrar. Se
quita a mano, y esto **sí** necesita reinicio: `db.json` se lee una vez al
arrancar y vive en memoria.

```bash
OLD=<uid-viejo>
sudo cp -a data/db.json data/db.json.bak
sudo jq --arg old "$OLD" \
  'del(.users[] | select(.id==$old)) | del(.creds[] | select(.userId==$old))' \
  data/db.json.bak | sudo tee data/db.json >/dev/null
docker compose restart api
```

`tee` sobrescribe el fichero en lugar de recrearlo, así que conserva el
`root:root 0600`. El `.bak` se borra cuando la instancia arranque bien.

**Lo que este procedimiento no salva:** las notificaciones push del perfil
viejo (`subs` sigue apuntando al uid antiguo; se vuelven a activar desde
Ajustes) y el registro de actividad, que conserva el uid viejo en las
entradas anteriores. El historial de entrenamientos y el peso corporal
vuelven enteros.

---

## Armario

### Primera instalación

Reutiliza el Postgres que ya existe, así que empieza por la base:

```sql
CREATE ROLE armario_user WITH LOGIN PASSWORD '<generada, no inventada>';
CREATE DATABASE armario OWNER armario_user;
```

```bash
git clone <repo-de-la-app> ~/armario
cd ~/armario
mkdir -p data/prendas logs
cp .env.example .env        # DATABASE_URL, RED_DOCKER, JWT_SECRETO, GEMINI_API_KEY
#   openssl rand -base64 48   para el JWT_SECRETO
docker compose up -d --build
```

Las migraciones se aplican solas al arrancar, **antes** de que levante la
API: si fallan, el contenedor muere con un error claro en vez de servir
contra un esquema viejo.

La usuaria se crea a mano — no hay endpoint de registro:

```bash
docker compose exec armario-api node dist/server/src/crear-usuario.js <usuario> '<contraseña>'
```

Y se publica en el tailnet:

```bash
sudo tailscale serve --bg --https=8445 http://127.0.0.1:3001
curl -s http://127.0.0.1:3001/health      # {"ok":true,"bd":true,...}
```

**La URL del 8445 va compilada dentro del APK.** Cambiarla obliga a
recompilar e instalar de nuevo en el móvil, así que se decide antes de
instalar nada.

### Actualizar

```bash
cd ~/armario
git pull
docker compose up -d --build
docker compose logs -f armario-api
```

Como el despliegue es el propio clon, no hay nada que copiar de un sitio a
otro. Tras el `pull`, comprobar que el protocolo sigue entero:

```bash
node scripts/e2e-sync.mjs                 # contra 127.0.0.1:3001
bash scripts/e2e-limpiar.sh               # borra las usuarias de prueba
```

### Cuadrar disco y base de datos

Cada prenda viva tiene que tener su fichero, y no debería sobrar ninguno:

```bash
docker compose exec armario-api node dist/server/src/limpiar-huerfanas.js            # en seco
docker compose exec armario-api node dist/server/src/limpiar-huerfanas.js --de-verdad
```

Sin `--de-verdad` solo dice qué borraría. Es lo contrario de lo cómodo y es
a propósito: un fallo aquí borra fotos que no están en ningún otro sitio
salvo la copia nocturna.

---

## Logs

```bash
docker compose logs -f --tail=100      # por servicio
journalctl -u homelab-bot -f           # bot
journalctl -u tailscaled --since -1h   # tailscale (incluye ACME)
tail -f ~/bot/logs/bot.log             # log propio del bot, rotado a 5 MB
```

---

## Rotar un secreto

**Token de la API de Vault App**

```bash
openssl rand -hex 32                  # nuevo valor
$EDITOR ~/vault_app/server/.env       # VAULT_API_TOKEN=...
docker compose up -d                  # recrear la API
```
Después hay que actualizarlo en la app móvil, o dejará de autenticar.

**Passphrase de las copias**

Afecta a los dos sistemas. Las copias antiguas siguen necesitando la
passphrase antigua: **guárdala hasta que hayan rotado los 7 días**.

```bash
openssl rand -base64 36 | tr -d '\n' > ~/.config/vault/backup-passphrase.new
# probar un ciclo completo antes de sustituir la antigua
```

**Contraseña SMTP de Vaultwarden**

Se genera en la cuenta de Google como contraseña de aplicación. Editar el
compose y `docker compose up -d`.

---

## Tras un corte de luz

Todo debería volver solo: los contenedores llevan `restart: unless-stopped`
y el bot `Restart=always`. La comprobación son dos minutos:

```bash
uptime                                        # confirmar que reinició
docker ps --format '{{.Names}}\t{{.Status}}'  # los cuatro arriba
systemctl status homelab-bot
tailscale status
dig @<IP_LAN> ejemplo.com +short              # DNS de la casa
```

El bot manda un mensaje de arranque; si no llega, empezar por ahí.

---

## Espacio en disco

```bash
df -h /
docker system df
docker system prune -a --volumes    # OJO: --volumes borra volúmenes sin usar
du -sh ~/vault_app/server/backups   # 30 noches de pg_dump
```

El bot avisa al 90%.

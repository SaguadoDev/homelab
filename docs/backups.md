# Copias de seguridad

Tres sistemas con datos que no se pueden perder: la bóveda de contraseñas,
la base de datos financiera y el historial de entrenamientos. Cada uno
tiene una red remota cifrada y corta; la base financiera tiene además una
local, amplia y barata.

| | Vaultwarden | Vault App | openGym |
|---|---|---|---|
| Copia local | — | `pg_dump` a las 03:30, 30 días | — |
| Copia remota | 03:00 → Drive, 7 días | 04:30 → Drive, 7 días | 05:00 → Drive, 7 días |
| Formato | `tar.gz` cifrado GPG | `pg_dump -Fc` cifrado GPG | `tar.gz` cifrado GPG |
| Lanzador | cron de root | cron del usuario | cron de root |
| Cifrado | AES-256 simétrico | AES-256 simétrico | AES-256 simétrico |

Las tres remotas comparten passphrase. Ver
[decisiones §6](decisiones.md#6-copias-cifradas-antes-de-salir-de-la-máquina).

## Instalación

```bash
# Passphrase, fuera de cualquier repo y solo legible por su dueño
mkdir -p ~/.config/vault && chmod 700 ~/.config/vault
openssl rand -base64 36 | tr -d '\n' > ~/.config/vault/backup-passphrase
chmod 600 ~/.config/vault/backup-passphrase
```

**Guárdala en un gestor de contraseñas y en algo que no dependa de este
servidor.** Sin ella las copias de Drive son ruido. Y como una de las
cosas que respalda es precisamente el gestor de contraseñas, hace falta al
menos una copia fuera de él.

```bash
# Remoto de Google Drive
rclone config          # tipo: drive, scope: drive.file

# Programación
sudo crontab -e
#   0 3 * * *  /home/homelab/homelab/scripts/backup-vaultwarden.sh >> /var/log/backup-vw.log 2>&1
#   0 5 * * *  /home/homelab/opengym/backup-opengym.sh >> /var/log/backup-opengym.log 2>&1
crontab -e
#   30 4 * * * /home/homelab/homelab/scripts/backup-vault-app.sh >> ~/backups/backup-drive.log 2>&1
```

**openGym va en el cron de root, no en el del usuario.** Sus contenedores
escriben `./data` como root y con permisos `0600`, así que el usuario del
servicio no puede leer ni `secret` ni `vapid.json`: desde su cron el script
aborta en el primer `cp`. Vaultwarden está en el de root por lo mismo.

Las 03:00, las 04:30 y las 05:00 están separadas a propósito, y las tres
lejos del `pg_dump` interno de las 03:30, para que dos volcados no compitan
por las mismas conexiones.

## Qué entra y qué no

**Vaultwarden** — `db.sqlite3` (volcado en caliente con `.backup`, que
consolida el WAL), `rsa_key.pem`, y si existen `attachments/`, `sends/` y
`config.json`. Se incluye además el `docker-compose.yml`, porque sin él
restaurar significa reconstruir a mano el `DOMAIN` y el SMTP. Quedan fuera
`icon_cache/` y `tmp/`, que se regeneran.

**Vault App** — `pg_dump --format=custom --no-owner` de toda la base. El
script hace su propio volcado en lugar de subir el de las 03:30, para que
la copia remota no dependa de que el contenedor de la API esté vivo esa
noche. Solo necesita Postgres.

**openGym** — todo `./data`: `db.json` (perfiles y claves **públicas** de
las passkeys), un `state-<uid>.json` por usuario, `secret` (firma las
cookies de sesión), `vapid.json` y `audit.log`. Entran además el
`docker-compose.yml` y el `.env`, porque `RP_ID` y `ORIGIN` son los que
atan las passkeys a este hostname: restaurar los datos y levantar la
instancia bajo otra URL deja dentro unas credenciales que ya no valen.

Como la API escribe esos JSON de forma continua, un `tar` tomado a media
escritura puede llevarse un fichero cortado. El script los parsea todos en
el directorio de preparación y aborta si alguno no es JSON válido o si
`db.json` no tiene ningún usuario: es el equivalente aquí del
`integrity_check` de Vaultwarden.

Queda fuera `./media` (~140 MB de imágenes y GIFs de ejercicios): es
contenido de terceros que el contenedor `opengym-media` vuelve a descargar
solo en el primer arranque.

**Lo que ningún respaldo cubre: las claves privadas de las passkeys.** No
están en el servidor y no pueden estarlo — viven en el hardware seguro del
móvil o en el gestor de contraseñas. Si un dispositivo se pierde y la
credencial no estaba sincronizada, ese perfil se queda fuera y la copia no
lo arregla. Salva los datos, no el acceso.

**No se respalda** (y es una decisión, no un olvido): el sistema
operativo, las imágenes de Docker (se reconstruyen desde los compose), la
configuración de AdGuard (listas públicas, se rehace en minutos) y el
estado de tailscaled (un `tailscale up` y el nodo vuelve).

## Restaurar

### Vaultwarden

```bash
rclone copy gdrive:Vaultwarden_Backups/vaultwarden_FECHA.tar.gz.gpg .
gpg --batch --passphrase-file ~/.config/vault/backup-passphrase \
    --decrypt vaultwarden_FECHA.tar.gz.gpg > vw.tar.gz

mkdir vw-data && tar -xzf vw.tar.gz -C vw-data
mv vw-data/docker-compose.yml .          # sale dentro del tar
docker compose up -d
```

### Vault App

```bash
rclone copy gdrive:Vault_Backups/vault_FECHA.dump.gpg .
gpg --batch --passphrase-file ~/.config/vault/backup-passphrase \
    --decrypt vault_FECHA.dump.gpg > vault.dump

docker compose cp vault.dump postgres:/tmp/vault.dump
docker compose exec postgres \
  pg_restore -U vault -d vault --clean /tmp/vault.dump
```

### openGym

```bash
rclone copy gdrive:openGym_Backups/opengym_FECHA.tar.gz.gpg .
gpg --batch --passphrase-file ~/.config/vault/backup-passphrase \
    --decrypt opengym_FECHA.tar.gz.gpg > og.tar.gz

mkdir -p opengym && tar -xzf og.tar.gz -C opengym
cd opengym                                # data/, docker-compose.yml y .env
docker compose up -d                      # `media` rehace ./media solo
```

Comprobar antes de dar por buena la restauración que el `RP_ID` del `.env`
recuperado es el mismo bajo el que se registraron las passkeys. Si no lo
es, no hay sesión que salvar: hay que volver a registrarlas todas.

## Probar la restauración

Una copia que no se ha restaurado nunca es una hipótesis. La prueba no
consiste en descomprimir el fichero, sino en levantar el servicio con él:

```bash
# Vaultwarden en un contenedor desechable, en otro puerto
docker run -d --name vw-test -v "$PWD/vw-data":/data \
  -p 127.0.0.1:8099:80 vaultwarden/server:latest

curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8099/alive
curl -s -X POST http://127.0.0.1:8099/identity/accounts/prelogin \
  -H 'Content-Type: application/json' -d '{"email":"<tu-correo>"}'

docker rm -f vw-test
```

Qué hay que ver: `/alive` devuelve 200, `prelogin` devuelve los parámetros
KDF de la cuenta (prueba de que la tabla de usuarios está intacta) y el
`md5sum` de `rsa_key.pem` **no ha cambiado** tras arrancar — si cambia, es
que la clave no se restauró y el servidor generó una nueva, lo que
invalida todas las sesiones.

Para Vault App, la comprobación equivalente es leer el volcado sin
importarlo:

```bash
pg_restore --list vault.dump | grep -c "TABLE DATA"
```

Y para openGym, levantar la copia en un puerto desechable y comprobar que
la API responde y que los perfiles siguen ahí:

```bash
docker run -d --name og-test -v "$PWD/data":/data -e DATA_DIR=/data \
  -p 127.0.0.1:8098:3000 registry.gitlab.com/duartesantos8/opengym/api:1.2.11

curl -s http://127.0.0.1:8098/api/health          # {"ok":true,...}
jq '.users | length' data/db.json                 # los perfiles esperados
docker rm -f og-test
```

Lo que hay que ver: `/api/health` devuelve `ok`, el número de perfiles
cuadra y `data/secret` **no ha cambiado** tras arrancar — si el contenedor
lo regenera es que no se restauró, y todas las sesiones abiertas se caen.

## Deuda

- **Las restauraciones se prueban a mano.** Debería ser un script mensual
  que levante, verifique y avise por el bot.
- **Todo depende de una cuenta de Google.** Falta una tercera copia en un
  disco externo que se conecte de vez en cuando: es la única defensa real
  contra el borrado de la cuenta.

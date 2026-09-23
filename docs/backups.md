# Copias de seguridad

Cinco sistemas con datos que no se pueden perder: la bóveda de
contraseñas, la base de datos financiera, el historial de entrenamientos,
el armario digital y el registro de vuelos. Cada uno tiene una red remota cifrada y corta; la base
financiera tiene además una local, amplia y barata. Y una quinta copia
que no es de datos sino del **sistema**: lo que hace falta para volver a
montar la máquina que los sirve.

| | Vaultwarden | Vault App | openGym | Combina | Sistema | hexwatch |
|---|---|---|---|---|---|---|
| Copia local | — | `pg_dump` a las 03:30, 30 días | — | — | — | — |
| Copia remota | 03:00 → Drive, 7 días | 04:30 → Drive, 7 días | 05:00 → Drive, 7 días | 05:30 → Drive, 7 días | 06:00 → Drive, 7 días + mensual | 06:30 → Drive, 7 días |
| Formato | `tar.gz` cifrado GPG | `pg_dump -Fc` cifrado GPG | `tar.gz` cifrado GPG | `tar.gz` cifrado GPG | `tar.gz` cifrado GPG | `tar.gz` cifrado GPG |
| Lanzador | cron de root | cron del usuario | cron de root | cron del usuario | cron de root | cron del usuario |
| Cifrado | AES-256 simétrico | AES-256 simétrico | AES-256 simétrico | AES-256 simétrico | AES-256 simétrico | AES-256 simétrico |

Las seis remotas comparten passphrase. Ver
[decisiones §6](decisiones.md#6-copias-cifradas-antes-de-salir-de-la-máquina).
El bot las vigila: `/copias` muestra la edad de la última de cada carpeta
y avisa cada mañana si alguna pasa de 30 horas.

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
#   0 3 * * *  /home/server/vaultwarden/backup_vaultwarden.sh >> /var/log/vaultwarden_backup.log 2>&1
#   0 5 * * *  /home/server/opengym/backup-opengym.sh >> /var/log/backup-opengym.log 2>&1
#   0 6 * * *  /home/server/homelab/scripts/backup-sistema.sh >> /var/log/backup-sistema.log 2>&1
crontab -e
#   30 4 * * * /home/server/vault_app/server/scripts/backup-to-drive.sh >> /home/server/vault_app/server/backups/backup-drive.log 2>&1
#   30 5 * * * /home/server/Combina/server/scripts/backup-combina.sh >> /home/server/Combina/logs/backup.log 2>&1
#   30 6 * * * /home/server/homelab/scripts/backup-hexwatch.sh >> /home/server/.local/state/backup-hexwatch.log 2>&1
```

Los cuatro scripts de datos corren desde su copia viva (`~/vaultwarden`,
`~/opengym`, el clon de cada app); las de `scripts/` de este repo son la
versión saneada, con `/home/homelab` en vez del usuario real. El del
sistema y el de hexwatch corren directamente desde el repo.

**hexwatch va en el cron del usuario**: la base es suya y no hay docker de
por medio. Su script está en este repo aunque la aplicación viva en otro,
privado, que este no nombra: la ruta real la lee de
`~/.config/hexwatch.env` (`HEXWATCH_DIR=...`), fuera de cualquier repo. Ese
fichero entra en el tar del sistema, así que la restauración lo recupera
antes de necesitarlo.

**Combina va en el cron del usuario**, como Vault App: su bind mount de
imágenes es del usuario del servicio —el contenedor corre como `node`, uid
1000— y el volcado sale por `docker exec`, para lo que basta con estar en el
grupo `docker`. Su script vive en el repo de la aplicación, no en este, por
la misma razón por la que el despliegue vive ahí: una sola copia.

**openGym va en el cron de root, no en el del usuario.** Sus contenedores
escriben `./data` como root y con permisos `0600`, así que el usuario del
servicio no puede leer ni `secret` ni `vapid.json`: desde su cron el script
aborta en el primer `cp`. Vaultwarden está en el de root por lo mismo.

Las 03:00, las 04:30, las 05:00 y las 05:30 están separadas a propósito, y
las cuatro lejos del `pg_dump` interno de las 03:30, para que dos volcados no
compitan por las mismas conexiones. Combina y Vault App comparten instancia
de Postgres, así que ahí la separación no es cortesía sino necesidad.

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

**Combina** — `pg_dump --format=custom --no-owner` de la base `armario`, el
directorio `data/prendas/` con los WebP, y el `docker-compose.yml` con su
`.env`. El `.env` lleva la contraseña de Postgres y el secreto del JWT:
restaurar sin el secreto no pierde datos —el refresh es opaco y se valida
contra la tabla `sesiones`, no contra él—, pero sin la contraseña de la base
hay que rehacer el rol a mano.

La verificación no se conforma con el tamaño del fichero: el script pide el
índice del volcado con `pg_restore -l` (dentro del contenedor de Postgres,
que es donde está el cliente) y aborta si no aparecen las tablas que tienen
que aparecer. Además deja escrito en el log cuántas prendas vivas había esa
noche, para que una caída a cero se vea de un vistazo al mirar atrás.

Las fotos van **enteras cada noche**: son ~30 MB con 150 prendas, o sea
~210 MB en Drive con la rotación de siete días. Es asumible y está vigilado.
Si algún día molesta, lo que toca no es bajar la retención sino separar las
fotos (un `rclone sync` a su propio directorio) del volcado diario de la
base.

**Lo que ningún respaldo cubre: las claves privadas de las passkeys.** No
están en el servidor y no pueden estarlo — viven en el hardware seguro del
móvil o en el gestor de contraseñas. Si un dispositivo se pierde y la
credencial no estaba sincronizada, ese perfil se queda fuera y la copia no
lo arregla. Salva los datos, no el acceso.

**Sistema** — todo lo que no es dato de servicio ni se regenera desde un
repo, para que [`restaurar-servidor.sh`](recuperacion.md) pueda dejar una
Ubuntu limpia igual que esta: la identidad de Tailscale
(`tailscaled.state`: clave del nodo, IP, nombre, `serve`), la
configuración de AdGuard, los dos cron, los `.env` (y `~/.config/hexwatch.env`
con el `config.json` de hexwatch) y los composes **tal y
como corren** (no la versión saneada del repo), la red del host (netplan,
resolved, `daemon.json`, sysctl), las claves SSH del host, `rclone.conf`,
dotfiles y la memoria de Claude Code; más un manifiesto (paquetes, snaps,
imágenes con digest, estado de Tailscale) y `SHA256SUMS`. Unos 300 KB.
Corre en el cron de root porque casi todo eso es 0600 de root. En la misma
carpeta deja `repos/<nombre>-<hash>.bundle.gpg` (los cuatro repos enteros,
cifrados, renovados solo cuando cambia `HEAD`, ~3 MB) y un `LEEME.txt`:
con eso la restauración no necesita GitHub ni ningún token, solo la
passphrase y la cuenta de Google.

Antes de esto, AdGuard y tailscaled se daban por "rehacibles en minutos".
Dejó de ser verdad con la [decisión §13](decisiones.md#13-adguard-como-dns-del-tailnet-no-solo-de-la-lan):
la IP del nodo es el DNS del tailnet y el nombre MagicDNS ata las passkeys
y la URL del APK. Perder `tailscaled.state` obliga a tocar la consola y
puede obligar a re-registrar credenciales.

**No se respalda** (y es una decisión, no un olvido): el sistema operativo
y los paquetes (los instala el script de restauración), las imágenes de
Docker (se reconstruyen desde los compose), `opengym/media` (la baja el
contenedor) y **la passphrase**, que no puede ir en una copia cifrada con
ella misma: va en papel y en la bóveda de Bitwarden.

**hexwatch** — `hexwatch.db` (la flota, sondeos, eventos, avisos, estado y
archivo) y su `config.json` (la base y los parámetros del sondeo). La flota
va dentro de la base desde que se edita por la API: `config.json` solo la
sembró la primera vez, así que restaurar la base es lo que la recupera. La base está en WAL con el demonio escribiendo, así
que no se copia con `cp`: `VACUUM INTO` produce un único fichero
consistente sin pararlo ([incidencias §7](incidencias.md) es la misma
lección con Vaultwarden). La verificación es sobre la **copia**:
`PRAGMA integrity_check`, que estén las tablas `polls`, `events` y `state`,
y cuántos sondeos hubo en las últimas 24 h frente a los esperados (2.880
por aeronave y fuente), para que un demonio parado se vea en el log. Es la
única copia de datos que no se pueden volver a generar: las redes ADS-B no
publican histórico ([decisiones §17](decisiones.md#17-la-copia-de-hexwatch-entra-como-las-demás)).

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

### Combina

```bash
rclone copy gdrive:Armario_Backups/armario_FECHA.tar.gz.gpg .
gpg --batch --passphrase-file ~/.config/vault/backup-passphrase \
    --decrypt armario_FECHA.tar.gz.gpg > armario.tar.gz

mkdir -p armario && tar -xzf armario.tar.gz -C armario

# La base, en la instancia compartida
docker exec -i <contenedor-postgres> psql -U <superusuario> -d postgres \
  -c 'CREATE DATABASE armario OWNER armario_user;'
docker exec -i <contenedor-postgres> pg_restore -U armario_user -d armario \
  --no-owner < armario/armario.dump

cd armario                                # data/, docker-compose.yml y .env
docker compose up -d
```

Las fotos salen del tar ya en `data/prendas/`, que es justo donde las espera
el bind mount. Para comprobar que base y disco cuadran después de restaurar:
`docker compose exec armario-api node dist/server/src/limpiar-huerfanas.js`
(en seco) debe decir cero huérfanas.

### hexwatch

```bash
rclone copy gdrive:Hexwatch_Backups/hexwatch_FECHA.tar.gz.gpg .
gpg --batch --passphrase-file ~/.config/vault/backup-passphrase \
    --decrypt hexwatch_FECHA.tar.gz.gpg > hexwatch.tar.gz

mkdir -p hexwatch && tar -xzf hexwatch.tar.gz -C hexwatch
sqlite3 hexwatch/hexwatch.db 'PRAGMA integrity_check;'     # ok

. ~/.config/hexwatch.env                  # HEXWATCH_DIR
sudo systemctl stop hexwatch
rm -f "$HEXWATCH_DIR"/hexwatch.db-wal "$HEXWATCH_DIR"/hexwatch.db-shm
cp hexwatch/hexwatch.db hexwatch/config.json "$HEXWATCH_DIR/"
sudo systemctl start hexwatch
```

Parar el servicio y borrar sus `-wal`/`-shm` no es opcional: son del
fichero viejo, y SQLite los aplicaría sobre el restaurado.

Comprobar antes de dar por buena la restauración de openGym que el `RP_ID`
del `.env` recuperado es el mismo bajo el que se registraron las passkeys. Si no lo
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

**Combina, restaurado el 2 de septiembre de 2026.** Es hasta ahora el único
que se ha probado de las dos formas que importan.

La copia, a una base aparte para no tocar la buena:

```bash
docker exec -i <contenedor-postgres> psql -U <superusuario> -d postgres \
  -c 'CREATE DATABASE armario_restaurada OWNER armario_user;'
docker exec -i <contenedor-postgres> pg_restore -U armario_user \
  -d armario_restaurada --no-owner < armario/armario.dump

# Filas tabla por tabla contra la base viva
for t in usuarios prendas armarios outfits prenda_armarios outfit_prendas; do
  echo -n "$t "
  docker exec <contenedor-postgres> psql -tAq -U armario_user -d armario \
    -c "select count(*) from $t"
  docker exec <contenedor-postgres> psql -tAq -U armario_user \
    -d armario_restaurada -c "select count(*) from $t"
done

# Y los bytes de las fotos
md5sum armario/data/*.webp
```

Cuadraron las filas de las seis tablas y los `md5sum` de las fotos contra el
bind mount. La base de prueba se borró después.

**Y la aplicación**, que es la prueba que de verdad cuenta: borrando los
datos desde los ajustes de Android y trayéndolo todo del servidor. Volvieron
las prendas, sus conjuntos y sus fotos. Hasta hacer eso, la sincronización
era una hipótesis con muy buena pinta.

**hexwatch, restaurado el 23 de septiembre de 2026**, el mismo día de su
primera copia. Bajada de Drive, descifrada y restaurada en un directorio
aparte, sin tocar la base viva:

```bash
sqlite3 hexwatch/hexwatch.db 'PRAGMA integrity_check;'      # ok
for t in polls events state; do                             # copia vs viva
  echo "$t $(sqlite3 hexwatch/hexwatch.db "select count(*) from $t") \
           $(sqlite3 -readonly "$HEXWATCH_DIR/hexwatch.db" "select count(*) from $t")"
done
# config.json con db_path a la copia y otro api_port:
python3 -m hexwatch --config prueba.json status
python3 -m hexwatch --config prueba.json events --limit 5
```

Cuadraron eventos y estado; sondeos, todos menos los del tick que llegó
después de la copia. `config.json` idéntico, y `status`/`events` leyeron la
base restaurada sin quejarse.

### Sistema

No se restaura a mano: lo hace `scripts/restaurar-servidor.sh` fase a
fase, y la prueba es el ensayo en VM descrito en
[recuperacion.md](recuperacion.md#cómo-se-probó). Para mirar qué lleva un
tar sin restaurar nada:

```bash
rclone copy gdrive:Sistema_Backups/sistema_FECHA.tar.gz.gpg .
gpg --batch --passphrase-file ~/.config/vault/backup-passphrase \
    --decrypt sistema_FECHA.tar.gz.gpg | tar -tzv
```

## Deuda

- **Las restauraciones de datos se prueban a mano.** Debería ser un script
  mensual que levante, verifique y avise por el bot. El ensayo del sistema
  en VM cubre las seis de una vez, pero también se lanza a mano.
- **Todo depende de una cuenta de Google.** Datos, sistema y repos están
  en Drive y solo en Drive (y los repos, además, en GitHub). Falta una
  tercera copia en un disco externo que se conecte de vez en cuando: ya va
  todo cifrado, así que bastaría un `rclone sync gdrive: /media/disco`.

#!/bin/bash
#
# openGym — copia diaria cifrada a Google Drive
#
# Mismo esquema que backup-vaultwarden.sh: staging -> verificación ->
# tar.gz -> GPG -> Drive -> rotación a 7 días, y la rotación SOLO después
# de una subida correcta.
#
# Qué entra:
#   - data/db.json          perfiles y claves PÚBLICAS de las passkeys
#   - data/state-<uid>.json plan, entrenamientos, peso y ajustes de cada uno
#   - data/secret           clave con la que se firman las cookies de sesión
#   - data/vapid.json       claves de las notificaciones push
#   - data/audit.log        registro de actividad
#   - docker-compose.yml y .env
#
# El compose y el .env entran a propósito: RP_ID y ORIGIN son los que atan
# las passkeys a este hostname. Restaurar los datos sin ellos y levantar la
# instancia bajo otra URL deja dentro unas credenciales que ya no valen.
#
# Las claves PRIVADAS de las passkeys no están aquí ni pueden estarlo:
# viven en el hardware seguro del móvil o en el gestor de contraseñas. Este
# respaldo no sustituye a tenerlas sincronizadas — si se pierde el móvil y
# la passkey no estaba en un gestor, no hay contraseña de recuperación que
# valga y el perfil se queda fuera. La copia salva los datos, no el acceso.
#
# NO entra ./media (~140 MB de imágenes y GIFs de ejercicios): es contenido
# de terceros que el propio contenedor `media` vuelve a descargar solo.
#
# Verificación antes de subir: la API escribe JSON planos de forma continua,
# así que un tar tomado a media escritura puede llevarse un fichero cortado.
# El script parsea TODOS los JSON del staging y aborta si alguno no es
# válido — es el equivalente aquí del PRAGMA integrity_check de Vaultwarden.
#
# Restaurar:
#   rclone copy gdrive:openGym_Backups/opengym_FECHA.tar.gz.gpg .
#   gpg --batch --passphrase-file /home/homelab/.config/vault/backup-passphrase \
#       --decrypt opengym_FECHA.tar.gz.gpg > og.tar.gz
#   mkdir -p opengym && tar -xzf og.tar.gz -C opengym
#   # data/ es el /data del contenedor api; docker-compose.yml y .env salen al lado
#   docker compose up -d      # el contenedor `media` rehará ./media solo
#
# Sin la passphrase el fichero no se puede recuperar. Es la misma de los
# otros dos respaldos; guárdala en Vaultwarden y fuera de él.
#
# CORRE COMO ROOT, desde el cron de root. No es una preferencia: los
# contenedores escriben ./data como root y con permisos 0600, así que el
# usuario del servicio no puede ni leer `secret` ni `vapid.json`. Desde el
# cron del usuario el script aborta en el primer `cp`.

set -euo pipefail

OG_DIR="${OG_COMPOSE_DIR:-/home/homelab/opengym}"
OG_DATA="$OG_DIR/data"
REMOTE_RCLONE="${OG_BACKUP_REMOTE:-gdrive:openGym_Backups}"
RETENCION="${OG_BACKUP_RETENTION:-7d}"
PASSPHRASE_FILE="/home/homelab/.config/vault/backup-passphrase"

# Explícito porque esto corre desde el cron de ROOT: sin esto rclone buscaría
# su configuración en /root/.config y fallaría en silencio. El llavero de GPG
# no hace falta declararlo — más abajo se crea uno desechable.
export RCLONE_CONFIG="${RCLONE_CONFIG:-/home/homelab/.config/rclone/rclone.conf}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

FECHA=$(date +%Y-%m-%d_%H-%M)
TMP_DIR=$(mktemp -d /tmp/opengym_backup.XXXXXX)
ARCHIVO_SALIDA="$TMP_DIR/opengym_$FECHA.tar.gz.gpg"
STAGE="$TMP_DIR/stage"
trap 'rm -rf "$TMP_DIR"' EXIT

# Llavero desechable: el cifrado simétrico no necesita ninguno, y así el
# script no depende de que cron le haya resuelto un $HOME utilizable.
export GNUPGHOME="$TMP_DIR/gnupg"
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"

log "[INFO] Iniciando copia de seguridad: $FECHA"

[ -r "$PASSPHRASE_FILE" ] || { log "ERROR: no se puede leer $PASSPHRASE_FILE"; exit 1; }
[ -d "$OG_DATA" ]         || { log "ERROR: no existe $OG_DATA"; exit 1; }
[ -f "$OG_DATA/db.json" ] || { log "ERROR: no existe $OG_DATA/db.json"; exit 1; }

mkdir -p "$STAGE/data"

# -a para no seguir enlaces y conservar permisos: `secret` tiene que volver
# con los suyos.
cp -a "$OG_DATA/." "$STAGE/data/"

# Configuración del servicio. Sin ella, restaurar significa reconstruir a
# mano RP_ID y ORIGIN, que es justo lo que no se puede fallar.
[ -f "$OG_DIR/docker-compose.yml" ] && cp -a "$OG_DIR/docker-compose.yml" "$STAGE/"
[ -f "$OG_DIR/.env" ]               && cp -a "$OG_DIR/.env" "$STAGE/"

# Un JSON cortado a la mitad también se empaqueta y también se sube. Aquí es
# donde se detecta, no la noche que haya que restaurar.
python3 - "$STAGE/data" <<'PY'
import json, pathlib, sys

directorio = pathlib.Path(sys.argv[1])
malos = []
for fichero in sorted(directorio.glob('*.json')):
    try:
        json.loads(fichero.read_text())
    except Exception as e:
        malos.append(f"{fichero.name}: {e}")

if malos:
    print("JSON inválidos en el volcado:", file=sys.stderr)
    for m in malos:
        print("  -", m, file=sys.stderr)
    sys.exit(1)

usuarios = json.loads((directorio / 'db.json').read_text()).get('users') or []
if not usuarios:
    print("db.json no contiene ningún usuario", file=sys.stderr)
    sys.exit(1)

print(f"[INFO] Volcado verificado: {len(usuarios)} perfiles, "
      f"{len(list(directorio.glob('state-*.json')))} ficheros de estado")
PY

# El secreto de la cookie no es opcional: restaurar sin él no rompe las
# passkeys, pero cierra la sesión de todos los dispositivos.
[ -f "$STAGE/data/secret" ] || log "[AVISO] no se encontró data/secret"

tar -czf - -C "$STAGE" . \
  | gpg --batch --quiet --yes --symmetric --cipher-algo AES256 \
        --passphrase-file "$PASSPHRASE_FILE" --output "$ARCHIVO_SALIDA"

TAMANO=$(stat -c %s "$ARCHIVO_SALIDA")
[ "$TAMANO" -gt 1024 ] || { log "ERROR: archivo sospechosamente pequeño ($TAMANO bytes)"; exit 1; }
log "[INFO] Archivo listo: $(basename "$ARCHIVO_SALIDA") ($((TAMANO / 1024)) KB)"

rclone copy "$ARCHIVO_SALIDA" "$REMOTE_RCLONE/"
log "[INFO] Subido a $REMOTE_RCLONE"

# Purgar solo después de una subida correcta.
rclone delete "$REMOTE_RCLONE/" --min-age "$RETENCION"
log "[INFO] Copias en el remoto: $(rclone lsf "$REMOTE_RCLONE/" | wc -l)"

log "[INFO] Copia finalizada."

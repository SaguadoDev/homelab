#!/bin/bash
#
# Vaultwarden — copia diaria cifrada a Google Drive
#
# Reemplazo de backup_vaultwarden.sh. Mismo esquema (volcado en caliente ->
# tar.gz -> Drive -> rotación a 7 días), con los agujeros tapados:
#
#   - set -euo pipefail: si el volcado falla, el script PARA. El original
#     seguía adelante, subía un tar vacío y acto seguido rotaba las copias
#     buenas con --min-age 7d.
#   - Verifica el sqlite volcado (integrity_check) y el tamaño antes de subir.
#   - Copia también sends/ (adjuntos de Bitwarden Send) y config.json, que el
#     original no incluía.
#   - Incluye docker-compose.yml: sin él, restaurar significa reconstruir a
#     mano el DOMAIN y la configuración SMTP.
#   - Cifra con GPG antes de salir de la máquina. Ahora es obligatorio: el tar
#     lleva rsa_key.pem (la clave privada del servidor), los correos de los
#     usuarios, los secretos TOTP si algún día activas 2FA, y la contraseña de
#     aplicación de Gmail que va en el compose.
#   - mktemp -d en vez de una ruta fija reutilizada entre ejecuciones.
#
# Los ítems de la bóveda ya viajan cifrados de extremo a extremo con tu
# contraseña maestra; esto protege todo lo demás.
#
# Restaurar:
#   rclone copy gdrive:Vaultwarden_Backups/vaultwarden_FECHA.tar.gz.gpg .
#   gpg --batch --passphrase-file /home/homelab/.config/vault/backup-passphrase \
#       --decrypt vaultwarden_FECHA.tar.gz.gpg > vw.tar.gz
#   mkdir vw-data && tar -xzf vw.tar.gz -C vw-data
#   # docker-compose.yml sale dentro del tar; el resto es el /data del contenedor
#
# Sin la passphrase el fichero no se puede recuperar. Guárdala en la propia
# bóveda de Vaultwarden y en algún sitio fuera de ella.

set -euo pipefail

VW_DIR="/home/homelab/vaultwarden"
VW_DATA="$VW_DIR/vw-data"
REMOTE_RCLONE="${VW_BACKUP_REMOTE:-gdrive:Vaultwarden_Backups}"
RETENCION="7d"
PASSPHRASE_FILE="/home/homelab/.config/vault/backup-passphrase"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

FECHA=$(date +%Y-%m-%d_%H-%M)
TMP_DIR=$(mktemp -d /tmp/vaultwarden_backup.XXXXXX)
ARCHIVO_SALIDA="$TMP_DIR/vaultwarden_$FECHA.tar.gz.gpg"
STAGE="$TMP_DIR/data"
trap 'rm -rf "$TMP_DIR"' EXIT

# Llavero desechable: el cifrado simétrico no necesita ninguno, y así el
# script no depende de que cron le haya resuelto un $HOME utilizable.
export GNUPGHOME="$TMP_DIR/gnupg"
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"

log "[INFO] Iniciando copia de seguridad: $FECHA"

[ -r "$PASSPHRASE_FILE" ] || { log "ERROR: no se puede leer $PASSPHRASE_FILE"; exit 1; }
mkdir -p "$STAGE"

# Volcado en caliente. .backup usa la API de respaldo de SQLite, que consolida
# el WAL: copiar db.sqlite3 con cp perdería todo lo escrito desde el último
# checkpoint (ahora mismo, ~100 KB de datos reales).
sqlite3 "$VW_DATA/db.sqlite3" ".backup '$STAGE/db.sqlite3'"

# Un volcado corrupto que nadie mira es peor que no tener volcado.
RES=$(sqlite3 "$STAGE/db.sqlite3" "PRAGMA integrity_check;")
[ "$RES" = "ok" ] || { log "ERROR: integrity_check devolvió: $RES"; exit 1; }
log "[INFO] Volcado verificado: $(sqlite3 "$STAGE/db.sqlite3" 'SELECT COUNT(*) FROM ciphers;') ítems, $(sqlite3 "$STAGE/db.sqlite3" 'SELECT COUNT(*) FROM users;') usuarios"

# Clave privada del servidor. El glob cubre los dos nombres que ha usado
# Vaultwarden (rsa_key.* hasta 1.29, rsa_key.pem desde 1.30); sin errores
# silenciados, para enterarnos si un día cambia otra vez.
shopt -s nullglob
CLAVES=("$VW_DATA"/rsa_key* "$VW_DATA"/private_rsa_key*)
shopt -u nullglob
[ ${#CLAVES[@]} -gt 0 ] || { log "ERROR: no se encontró ninguna clave RSA en $VW_DATA"; exit 1; }
cp "${CLAVES[@]}" "$STAGE/"

# Opcionales: solo existen si se han usado. -d evita seguir enlaces.
[ -d "$VW_DATA/attachments" ] && cp -a "$VW_DATA/attachments" "$STAGE/"
[ -d "$VW_DATA/sends" ]       && cp -a "$VW_DATA/sends" "$STAGE/"
[ -f "$VW_DATA/config.json" ] && cp -a "$VW_DATA/config.json" "$STAGE/"

# Configuración del servicio: DOMAIN, SMTP, puertos. No está en /data.
[ -f "$VW_DIR/docker-compose.yml" ] && cp -a "$VW_DIR/docker-compose.yml" "$STAGE/"

# icon_cache/ y tmp/ quedan fuera a propósito: se regeneran solos.

tar -czf - -C "$STAGE" . \
  | gpg --batch --quiet --yes --symmetric --cipher-algo AES256 \
        --passphrase-file "$PASSPHRASE_FILE" --output "$ARCHIVO_SALIDA"

TAMANO=$(stat -c %s "$ARCHIVO_SALIDA")
[ "$TAMANO" -gt 4096 ] || { log "ERROR: archivo sospechosamente pequeño ($TAMANO bytes)"; exit 1; }
log "[INFO] Archivo listo: $(basename "$ARCHIVO_SALIDA") ($((TAMANO / 1024)) KB)"

rclone copy "$ARCHIVO_SALIDA" "$REMOTE_RCLONE/"
log "[INFO] Subido a $REMOTE_RCLONE"

# Purgar solo después de una subida correcta.
rclone delete "$REMOTE_RCLONE/" --min-age "$RETENCION"
log "[INFO] Copias en el remoto: $(rclone lsf "$REMOTE_RCLONE/" | wc -l)"

log "[INFO] Copia finalizada."

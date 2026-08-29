#!/usr/bin/env bash
#
# Vault Server — copia diaria cifrada a Google Drive
#
# El servidor ya escribe un pg_dump cada noche a las 03:30 en ./backups (ver
# src/jobs/backup.ts), pero ese fichero vive en la misma máquina que la base de
# datos: no protege contra el disco, el robo o el borrado accidental del
# directorio. Esto es la copia de fuera.
#
# Hace su propio volcado en lugar de subir el de las 03:30 a propósito: así la
# copia en Drive no depende de que el contenedor api esté vivo ni de que su
# cron interno haya corrido esa noche. Solo necesita Postgres.
#
# Cifrado con GPG simétrico antes de salir de la máquina. El dump lleva
# movimientos, cuentas y saldos en claro; el .dump local puede quedarse así
# porque no se mueve, pero lo que sube a una cuenta de Drive, no.
#
# Retención: rclone borra del remoto lo que pase de 7 días, igual que el script
# de Vaultwarden. Con una copia al día eso deja las 7 últimas.
#
# Restaurar:
#   rclone copy gdrive:Vault_Backups/vault_FECHA.dump.gpg .
#   gpg --batch --passphrase-file ~/.config/vault/backup-passphrase \
#       --decrypt vault_FECHA.dump.gpg > vault.dump
#   docker compose cp vault.dump postgres:/tmp/vault.dump
#   docker compose exec postgres pg_restore -U vault -d vault --clean /tmp/vault.dump
#
# Sin la passphrase el fichero no se puede recuperar. Guárdala en Vaultwarden.

set -euo pipefail

COMPOSE_DIR="${VAULT_COMPOSE_DIR:-/home/homelab/vault_app/server}"
REMOTE="${VAULT_BACKUP_REMOTE:-gdrive:Vault_Backups}"
RETENTION="${VAULT_BACKUP_REMOTE_RETENTION:-7d}"
PASSPHRASE_FILE="${VAULT_BACKUP_PASSPHRASE_FILE:-/home/homelab/.config/vault/backup-passphrase}"

# Explícito porque esto corre desde cron: sin HOME resuelto, rclone y gpg
# buscarían su configuración en el sitio equivocado y fallarían en silencio.
export RCLONE_CONFIG="${RCLONE_CONFIG:-/home/homelab/.config/rclone/rclone.conf}"
export GNUPGHOME="${GNUPGHOME:-/home/homelab/.gnupg}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

FECHA=$(date +%Y-%m-%d_%H-%M)
TMP_DIR=$(mktemp -d /tmp/vault_backup.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVO="$TMP_DIR/vault_$FECHA.dump.gpg"

log "Iniciando copia de seguridad: $FECHA"

[ -r "$PASSPHRASE_FILE" ] || { log "ERROR: no se puede leer $PASSPHRASE_FILE"; exit 1; }

# Credenciales de la propia base de datos, sin duplicarlas aquí.
set -a
# shellcheck source=/dev/null
source "$COMPOSE_DIR/.env"
set +a

# Volcado en caliente -> cifrado, sin tocar el disco en claro por el camino.
docker compose -f "$COMPOSE_DIR/docker-compose.yml" exec -T postgres \
  pg_dump --format=custom --no-owner -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  | gpg --batch --yes --symmetric --cipher-algo AES256 \
        --passphrase-file "$PASSPHRASE_FILE" --output "$ARCHIVO"

# Un pg_dump vacío también "termina bien"; sin este control subiríamos un
# fichero inútil y a los 7 días habríamos rotado los que sí servían.
TAMANO=$(stat -c %s "$ARCHIVO")
[ "$TAMANO" -gt 1024 ] || { log "ERROR: volcado sospechosamente pequeño ($TAMANO bytes)"; exit 1; }
log "Volcado cifrado: $(basename "$ARCHIVO") ($((TAMANO / 1024)) KB)"

rclone copy "$ARCHIVO" "$REMOTE/"
log "Subido a $REMOTE"

# Purgar del remoto lo que pase de la ventana de retención. Después de subir,
# nunca antes: si la subida falla, la noche mala no cuesta además una copia.
rclone delete "$REMOTE/" --min-age "$RETENTION"
log "Copias en $REMOTE: $(rclone lsf "$REMOTE/" | wc -l)"

log "Copia finalizada."

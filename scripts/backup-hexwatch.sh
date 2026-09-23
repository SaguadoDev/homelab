#!/bin/bash
#
# hexwatch — copia diaria cifrada a Google Drive.
#
# Mismo esquema que backup-combina.sh y los otros cuatro: staging ->
# verificación -> tar.gz -> GPG -> Drive -> rotación a 7 días, y la rotación
# SOLO después de una subida correcta.
#
# Horario: 06:30, detrás de las cinco que ya había (03:00 Vaultwarden, 04:30
# Vault App, 05:00 openGym, 05:30 Combina, 06:00 Sistema). Escalonado a
# propósito, igual que las demás, y antes de que el bot revise Drive (07:00).
#
# POR QUÉ ESTA COPIA NO ES COMO LAS OTRAS
#
# Las bases de Vaultwarden, Vault App, openGym y Combina guardan cosas que
# alguien introdujo y, en el peor caso, podría volver a introducir. Esta no.
# hexwatch guarda observaciones con marca de tiempo de redes ADS-B que **no
# publican histórico**: lo que el sondeo no capturase esa noche no existe en
# ningún otro sitio del mundo. No hay "lo vuelvo a bajar". Por eso entra en la
# rotación nocturna desde el primer día, aunque el fichero sea diminuto.
#
# Qué entra:
#   - hexwatch.db     sondeos, eventos y estado (~1 MB por día y aeronave)
#   - config.json     la flota (hex, nombre, base) y los parámetros: sin él la
#                     copia no se sabe a qué aeronaves se refiere
#
# El config.json entra porque contiene la configuración del sondeo. No lleva
# credenciales (hexwatch no usa ninguna: las dos APIs son abiertas), así que
# el riesgo de incluirlo es menor que el de restaurar una base sin saber a qué
# se refiere.
#
# CÓMO SE COPIA UNA SQLITE VIVA
#
# `cp` sobre una base en modo WAL da una copia corrupta o incompleta: el
# fichero principal puede estar a medio checkpoint y el -wal contiene
# transacciones que no están en él. Aquí se usa `VACUUM INTO`, que produce un
# único fichero consistente y compactado sin parar el demonio ni bloquear al
# escritor. Es lo mismo que hace `.backup`, pero compactando.
#
# DÓNDE ESTÁ hexwatch
#
# El repo de la aplicación es privado y este no lo nombra: la ruta real vive
# en ~/.config/hexwatch.env (HEXWATCH_DIR=...), fuera de cualquier repo. Ese
# fichero viaja en el tar de backup-sistema.sh, así que la restauración lo
# recupera antes de necesitarlo.
#
# Restaurar (a mano; restaurar-servidor.sh lo hace en su fase 11):
#   rclone copy gdrive:Hexwatch_Backups/hexwatch_FECHA.tar.gz.gpg .
#   gpg --batch --passphrase-file ~/.config/vault/backup-passphrase \
#       --decrypt hexwatch_FECHA.tar.gz.gpg > hexwatch.tar.gz
#   mkdir -p hexwatch && tar -xzf hexwatch.tar.gz -C hexwatch
#   sqlite3 hexwatch/hexwatch.db 'PRAGMA integrity_check;'     # ok
#   sudo systemctl stop hexwatch
#   rm -f "$HEXWATCH_DIR"/hexwatch.db-wal "$HEXWATCH_DIR"/hexwatch.db-shm
#   cp hexwatch/hexwatch.db hexwatch/config.json "$HEXWATCH_DIR/"
#   sudo systemctl start hexwatch
#
# Parar el servicio antes de sobrescribir no es opcional, y borrar sus -wal y
# -shm tampoco: son del fichero viejo, y SQLite los aplicaría sobre el nuevo.
#
# Sin la passphrase el fichero no se puede recuperar. Es la misma de las otras
# cinco copias; guárdala en Vaultwarden y fuera de él.
#
# Corre como el usuario del servicio, desde SU cron (no el de root), y
# directamente desde este repo, como backup-sistema.sh: la base es suya, no
# hace falta docker para nada y no hay copia viva que sincronizar.
#
#   crontab -e
#   30 6 * * * /home/server/homelab/scripts/backup-hexwatch.sh >> /home/server/.local/state/backup-hexwatch.log 2>&1

set -euo pipefail

USUARIO="server"
HOME_USR="/home/$USUARIO"
HEXWATCH_ENV="${HEXWATCH_ENV:-$HOME_USR/.config/hexwatch.env}"
REMOTO="${HEXWATCH_BACKUP_REMOTE:-gdrive:Hexwatch_Backups}"
RETENCION="${HEXWATCH_BACKUP_RETENTION:-7d}"
PASSPHRASE_FILE="$HOME_USR/.config/vault/backup-passphrase"

# Explícito porque esto corre desde cron, donde no hay entorno de sesión: sin
# esto rclone buscaría su configuración en otro sitio y fallaría en silencio.
export RCLONE_CONFIG="${RCLONE_CONFIG:-$HOME_USR/.config/rclone/rclone.conf}"

# La ruta real, del fichero de fuera del repo (o del entorno, para pruebas).
if [ -z "${HEXWATCH_DIR:-}" ] && [ -r "$HEXWATCH_ENV" ]; then
  # shellcheck disable=SC1090
  . "$HEXWATCH_ENV"
fi
[ -n "${HEXWATCH_DIR:-}" ] || { echo "ERROR: sin HEXWATCH_DIR (ni en el entorno ni en $HEXWATCH_ENV)"; exit 1; }
DIR_SERVICIO="$HEXWATCH_DIR"
BD="$DIR_SERVICIO/hexwatch.db"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

FECHA=$(date +%Y-%m-%d_%H-%M)
TMP_DIR=$(mktemp -d /tmp/hexwatch_backup.XXXXXX)
STAGE="$TMP_DIR/stage"
ARCHIVO="$TMP_DIR/hexwatch_$FECHA.tar.gz.gpg"
trap 'rm -rf "$TMP_DIR"' EXIT

# Llavero desechable: el cifrado simétrico no necesita ninguno, y así el
# script no depende de que cron le haya resuelto un $HOME utilizable.
export GNUPGHOME="$TMP_DIR/gnupg"
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"

log "[INFO] Iniciando copia de seguridad: $FECHA"

[ -r "$PASSPHRASE_FILE" ] || { log "ERROR: no se puede leer $PASSPHRASE_FILE"; exit 1; }
[ -f "$BD" ]              || { log "ERROR: no existe la base $BD"; exit 1; }
command -v sqlite3 >/dev/null || { log "ERROR: falta sqlite3 (apt install sqlite3)"; exit 1; }

mkdir -p "$STAGE"

# ---------------------------------------------------------------- la base
# VACUUM INTO: copia consistente de una base en WAL con el demonio escribiendo.
log "[INFO] Copiando la base con VACUUM INTO…"
sqlite3 "$BD" "VACUUM INTO '$STAGE/hexwatch.db'"

TAMANO_BD=$(stat -c %s "$STAGE/hexwatch.db")
[ "$TAMANO_BD" -gt 4096 ] \
  || { log "ERROR: base sospechosamente pequeña ($TAMANO_BD bytes)"; exit 1; }

# Una base corrupta también se copia sin dar error. Se comprueba la integridad
# sobre la COPIA, no sobre la original: es la copia la que hay que poder
# restaurar, y así el chequeo no compite con el demonio.
INTEGRIDAD=$(sqlite3 "$STAGE/hexwatch.db" 'PRAGMA integrity_check;')
[ "$INTEGRIDAD" = "ok" ] \
  || { log "ERROR: integrity_check dice: $INTEGRIDAD"; exit 1; }

# Que las tablas estén y tengan algo. Una base recién creada por un arranque
# fallido pasaría integrity_check perfectamente y no serviría de nada.
for tabla in polls events state; do
  sqlite3 "$STAGE/hexwatch.db" \
    "select name from sqlite_master where type='table' and name='$tabla';" \
    | grep -q "$tabla" || { log "ERROR: la copia no contiene la tabla $tabla"; exit 1; }
done

SONDEOS=$(sqlite3 "$STAGE/hexwatch.db" 'select count(*) from polls;')
EVENTOS=$(sqlite3 "$STAGE/hexwatch.db" 'select count(*) from events;')
ULTIMO=$(sqlite3 "$STAGE/hexwatch.db" \
  "select datetime(max(ts),'unixepoch') from polls;" 2>/dev/null || echo '?')

# La expectativa depende del tamaño de la flota, así que se deduce de la propia
# base en vez de estar escrita a mano: un sondeo cada 30 s son 2.880 ticks al día,
# y cada tick deja una fila POR AERONAVE Y FUENTE. El hex '-' son eventos de
# flota (cortes de datos), no una aeronave.
AERONAVES=$(sqlite3 "$STAGE/hexwatch.db" \
  "select count(distinct hex) from polls where hex <> '-';")
FUENTES=$(sqlite3 "$STAGE/hexwatch.db" 'select count(distinct source) from polls;')
[ "$AERONAVES" -gt 0 ] || { log "ERROR: la copia no tiene ninguna aeronave"; exit 1; }
ESPERADO=$(( 2880 * AERONAVES * FUENTES ))
MINIMO=$(( ESPERADO / 5 ))

RECIENTES=$(sqlite3 "$STAGE/hexwatch.db" \
  "select count(*) from polls where ts > strftime('%s','now') - 86400;")
log "[INFO] Copia verificada: $((TAMANO_BD / 1024)) KB, $SONDEOS sondeos, $EVENTOS eventos"
log "[INFO] Flota: $AERONAVES aeronave(s) x $FUENTES fuente(s)"
log "[INFO] Último sondeo: $ULTIMO · en las últimas 24 h: $RECIENTES (esperado ~$ESPERADO)"
[ "$RECIENTES" -gt "$MINIMO" ] \
  || log "[AVISO] muy pocos sondeos en 24 h ($RECIENTES < $MINIMO): ¿ha estado parado el demonio?"

# ------------------------------------------------------- la configuración
[ -f "$DIR_SERVICIO/config.json" ] && cp -a "$DIR_SERVICIO/config.json" "$STAGE/"
[ -f "$STAGE/config.json" ] \
  || log "[AVISO] no se encontró config.json: la copia no dice a qué aeronave se refiere"

# ------------------------------------------------------ empaquetar y subir
tar -czf - -C "$STAGE" . \
  | gpg --batch --quiet --yes --symmetric --cipher-algo AES256 \
        --passphrase-file "$PASSPHRASE_FILE" --output "$ARCHIVO"

TAMANO=$(stat -c %s "$ARCHIVO")
[ "$TAMANO" -gt 1024 ] || { log "ERROR: archivo sospechosamente pequeño ($TAMANO bytes)"; exit 1; }
log "[INFO] Archivo listo: $(basename "$ARCHIVO") ($((TAMANO / 1024)) KB)"

rclone copy "$ARCHIVO" "$REMOTO/"
log "[INFO] Subido a $REMOTO"

# Purgar solo después de una subida correcta. Si la subida falla, la noche
# mala no cuesta además una copia buena.
rclone delete "$REMOTO/" --min-age "$RETENCION"
log "[INFO] Copias en el remoto: $(rclone lsf "$REMOTO/" | wc -l)"

log "[INFO] Copia finalizada."

#!/bin/bash
#
# Armario — copia diaria cifrada a Google Drive (CLAUDE.md §6b).
#
# Mismo esquema que backup-vaultwarden.sh y backup-opengym.sh: staging ->
# verificación -> tar.gz -> GPG -> Drive -> rotación a 7 días, y la rotación
# SOLO después de una subida correcta. Un fallo silencioso durante siete
# noches vacía el historial entero, y ese es el error que este patrón ya
# aprendió por las malas.
#
# Horario: 05:30, detrás de los que ya había (03:00 Vaultwarden, 04:30 Vault
# App, 05:00 openGym). Escalonado a propósito: el m715q no da para dos
# volcados y dos subidas a la vez.
#
# Qué entra:
#   - pg_dump de la base `armario`   metadatos de prendas, outfits, armarios,
#                                    usuarias y sesiones (~1 MB con 150 prendas)
#   - data/prendas/                  los WebP (~30 MB con 150 prendas)
#   - docker-compose.yml y .env      para poder levantar el servicio otra vez
#
# El .env entra porque lleva la contraseña de Postgres y el JWT_SECRETO.
# Restaurar sin el secreto no pierde datos —el refresh token es opaco y se
# valida contra la tabla `sesiones`, no contra el secreto—, pero sí invalida
# los tokens cortos en vuelo. Con la contraseña de la BD es peor: sin ella hay
# que volver a crear el rol a mano.
#
# Las imágenes van ENTERAS cada noche: son ~30 MB, así que con rotación de 7
# días son ~210 MB en Drive. CLAUDE.md §8 lo da por aceptable y avisa de que
# conviene vigilarlo. Si algún día molesta, lo que toca NO es bajar la
# retención sino subir solo el diff (rclone sync a un directorio aparte para
# las fotos y volcado diario solo de la BD).
#
# Por qué NO hay base64 de las imágenes en la BD (§8): precisamente por esto.
# Con las fotos dentro de las filas, este volcado pasaría de ~1 MB a ~40 MB
# comprimidos y cifrados CADA noche, en lugar de copiar ficheros que solo
# cambian cuando la usuaria da de alta algo.
#
# Restaurar:
#   rclone copy gdrive:Armario_Backups/armario_FECHA.tar.gz.gpg .
#   gpg --batch --passphrase-file /home/homelab/.config/vault/backup-passphrase \
#       --decrypt armario_FECHA.tar.gz.gpg > armario.tar.gz
#   mkdir -p armario && tar -xzf armario.tar.gz -C armario
#   # la BD:
#   docker exec -i server-postgres-1 psql -U vault -d postgres \
#     -c 'CREATE DATABASE armario OWNER armario_user;'
#   docker exec -i server-postgres-1 pg_restore -U armario_user -d armario \
#     --no-owner < armario/armario.dump
#   # las fotos y la configuración salen ya en su sitio dentro de armario/
#   cd armario && docker compose up -d
#
# Sin la passphrase el fichero no se puede recuperar. Es la misma de los otros
# tres respaldos; guárdala en Vaultwarden y fuera de él.
#
# Corre como el usuario del servicio, desde SU cron (no el de root): el bind mount
# de las imágenes es suyo —el contenedor corre como `node`, uid 1000— y el
# volcado sale por `docker exec`, para lo que basta con estar en el grupo
# docker.
#
# **Un backup que nunca se ha restaurado no es un backup** (§6). Esto se ha
# probado en el sentido de que corre y sube; probar la restauración de verdad,
# a mano y contra una base vacía, sigue siendo deuda reconocida del homelab.

set -euo pipefail

DIR_SERVICIO="${ARMARIO_DIR:-/home/homelab/Combina}"
DIR_IMAGENES="$DIR_SERVICIO/data/prendas"
CONTENEDOR_PG="${ARMARIO_PG:-server-postgres-1}"
BD="${ARMARIO_BD:-armario}"
USUARIO_BD="${ARMARIO_BD_USER:-armario_user}"
REMOTO="${ARMARIO_BACKUP_REMOTE:-gdrive:Armario_Backups}"
RETENCION="${ARMARIO_BACKUP_RETENTION:-7d}"
PASSPHRASE_FILE="/home/homelab/.config/vault/backup-passphrase"

# Explícito porque esto corre desde cron, donde no hay entorno de sesión: sin
# esto rclone buscaría su configuración en otro sitio y fallaría en silencio.
export RCLONE_CONFIG="${RCLONE_CONFIG:-/home/homelab/.config/rclone/rclone.conf}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

FECHA=$(date +%Y-%m-%d_%H-%M)
TMP_DIR=$(mktemp -d /tmp/armario_backup.XXXXXX)
STAGE="$TMP_DIR/stage"
ARCHIVO="$TMP_DIR/armario_$FECHA.tar.gz.gpg"
trap 'rm -rf "$TMP_DIR"' EXIT

# Llavero desechable: el cifrado simétrico no necesita ninguno, y así el
# script no depende de que cron le haya resuelto un $HOME utilizable.
export GNUPGHOME="$TMP_DIR/gnupg"
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"

log "[INFO] Iniciando copia de seguridad: $FECHA"

[ -r "$PASSPHRASE_FILE" ] || { log "ERROR: no se puede leer $PASSPHRASE_FILE"; exit 1; }
[ -d "$DIR_SERVICIO" ]    || { log "ERROR: no existe $DIR_SERVICIO"; exit 1; }
docker inspect "$CONTENEDOR_PG" >/dev/null 2>&1 \
  || { log "ERROR: no está el contenedor de Postgres ($CONTENEDOR_PG)"; exit 1; }

mkdir -p "$STAGE/data"

# ---------------------------------------------------------------- la base
# Formato custom: permite pg_restore selectivo y comprime solo.
log "[INFO] Volcando la base $BD…"
docker exec "$CONTENEDOR_PG" \
  pg_dump --format=custom --no-owner -U "$USUARIO_BD" -d "$BD" > "$STAGE/armario.dump"

TAMANO_DUMP=$(stat -c %s "$STAGE/armario.dump")
[ "$TAMANO_DUMP" -gt 1024 ] \
  || { log "ERROR: volcado sospechosamente pequeño ($TAMANO_DUMP bytes)"; exit 1; }

# Un pg_dump de una base vacía también "termina bien". Sin esta comprobación
# subiríamos un fichero inútil y a los siete días habríamos rotado los que sí
# servían. Se exige que el volcado sea legible y que lleve las tablas que
# tiene que llevar.
# `pg_restore` se lanza DENTRO del contenedor: en el m715q no hay cliente de
# Postgres instalado, y meterlo solo para esto sería una dependencia más que
# mantener. Sin nombre de fichero, pg_restore lee de la entrada estándar.
INDICE=$(docker exec -i "$CONTENEDOR_PG" pg_restore -l < "$STAGE/armario.dump")
TABLAS=$(echo "$INDICE" | grep -c 'TABLE DATA' || true)
for tabla in prendas armarios outfits usuarios; do
  echo "$INDICE" | grep -q "TABLE DATA public $tabla " \
    || { log "ERROR: el volcado no contiene la tabla $tabla"; exit 1; }
done
log "[INFO] Volcado verificado: $((TAMANO_DUMP / 1024)) KB, $TABLAS tablas con datos"

# Cuántas prendas hay, para que el log sirva de algo cuando haya que mirar
# atrás: una noche en la que el número cae a cero se ve de un vistazo.
PRENDAS=$(docker exec "$CONTENEDOR_PG" psql -tAq -U "$USUARIO_BD" -d "$BD" \
  -c 'select count(*) from prendas where deleted_at is null' 2>/dev/null || echo '?')
log "[INFO] Prendas vivas en la base: $PRENDAS"

# -------------------------------------------------------------- las fotos
# El binario va a disco, no a la BD (§8): esta es la copia buena de las fotos,
# y la única que sobrevive a que se pierda el móvil Y el servidor.
if [ -d "$DIR_IMAGENES" ]; then
  cp -a "$DIR_IMAGENES/." "$STAGE/data/"
  FOTOS=$(find "$STAGE/data" -name '*.webp' | wc -l)
  BYTES_FOTOS=$(du -sh "$STAGE/data" | cut -f1)
  log "[INFO] Fotos: $FOTOS ficheros, $BYTES_FOTOS"
else
  log "[AVISO] no existe $DIR_IMAGENES: se copia solo la base"
  FOTOS=0
fi

# Ficheros a medio subir: la API escribe a `<id>.webp.subiendo` y renombra,
# así que si la copia cae justo en medio puede llevarse uno. No vale la pena
# guardarlo: la app lo vuelve a subir desde la cola.
find "$STAGE/data" -name '*.subiendo' -delete

# ------------------------------------------------------- la configuración
[ -f "$DIR_SERVICIO/docker-compose.yml" ] && cp -a "$DIR_SERVICIO/docker-compose.yml" "$STAGE/"
[ -f "$DIR_SERVICIO/.env" ]               && cp -a "$DIR_SERVICIO/.env" "$STAGE/"
[ -f "$STAGE/.env" ] || log "[AVISO] no se encontró el .env: la copia no basta para levantar el servicio"

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

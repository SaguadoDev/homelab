#!/bin/bash
#
# Sistema — copia diaria cifrada a Google Drive de TODO lo que no es dato de
# servicio ni se regenera desde un repo.
#
# Las otras cuatro copias salvan los datos (bóveda, bases, entrenamientos,
# armario). Esta salva lo que hace falta para volver a montar la máquina que
# los sirve: la identidad de Tailscale, la configuración de AdGuard, los
# .env con los secretos, los dos cron, los composes tal y como corren (no la
# versión saneada del repo), la red del host y los ficheros de /etc que se
# han tocado a mano. Con este tar, los repos de GitHub y las cuatro copias de
# datos, `restaurar-servidor.sh` deja una Ubuntu limpia igual que la de hoy.
#
# Qué entra (rutas reales del disco, no las del repo):
#   etc/        netplan (IP fija), resolved.conf, docker/daemon.json,
#               sysctl.d/99-tailscale.conf, default/tailscaled, gdm3/custom.conf,
#               hosts, hostname, ssh_host_* (identidad SSH del host)
#   tailscale/  tailscaled.state (clave del nodo, IP, serve, prefs) y certs/
#   adguard/    AdGuardHome.yaml (se lee la ruta real del bind mount) y compose
#   cron/       crontab de root y del usuario
#   home/       composes vivos, .env, scripts de backup, rclone.conf, dotfiles,
#               data/ de Vault App (exportaciones cifradas), memoria de Claude
#   manifiesto/ paquetes, snaps, imágenes Docker con digest, tailscale status,
#               serve, prefs, IPs, os-release — para saber qué había, no para
#               restaurarlo a ciegas
#   SHA256SUMS  de todo lo anterior; restaurar-servidor.sh lo verifica
#
# Qué NO entra, y es a propósito:
#   - ~/.config/vault/backup-passphrase: cifrar la passphrase con la propia
#     passphrase no es una copia. Va en papel (docs/recuperacion.md).
#   - Datos de servicios: tienen su copia (vw-data, pgdata, opengym/data,
#     Combina/data).
#   - venv, node_modules, imágenes Docker, opengym/media, los pg_dump locales
#     de vault_app/server/backups, logs, *.bak: se regeneran o no valen.
#
# Tamaño esperado: 100–300 KB. Mínimo para dar la copia por buena: 20 KB.
#
# Además del tar, en la misma carpeta de Drive:
#   repos/<nombre>-<hash>.bundle.gpg   git bundle de homelab, vault_app y Combina,
#                                      cifrado, renovado solo cuando cambia HEAD.
#                                      Con esto la restauración no necesita
#                                      GitHub ni ningún token: todo el kit es
#                                      "la passphrase en papel + la cuenta de
#                                      Google".
#   LEEME.txt                          los cuatro pasos, para quien abra la
#                                      carpeta dentro de tres años.
#
# Restaurar (a mano; lo normal es dejar que lo haga restaurar-servidor.sh):
#   rclone copy gdrive:Sistema_Backups/sistema_FECHA.tar.gz.gpg .
#   gpg --batch --passphrase-file /home/server/.config/vault/backup-passphrase \
#       --decrypt sistema_FECHA.tar.gz.gpg > sistema.tar.gz
#   mkdir sistema && tar -xzf sistema.tar.gz -C sistema && cd sistema
#   sha256sum -c SHA256SUMS
#   # etc/ va a /etc, tailscale/ a /var/lib/tailscale, home/ a /home/server,
#   # cron/root.txt con `crontab`, cron/server.txt con `crontab -u server`
#
# CORRE COMO ROOT, desde el cron de root: tailscaled.state, la configuración
# de AdGuard, netplan y el cron de root son 0600 de root.
#
#   sudo crontab -e
#   0 6 * * * /home/server/homelab/scripts/backup-sistema.sh >> /var/log/backup-sistema.log 2>&1
#
# A las 06:00, después de las otras cuatro, para no competir con ellas.
#
# --dry-run: lista lo que entraría, con tamaños, y lo que no se puede leer;
# no cifra ni sube nada. Sirve para probar el script sin ser root (dirá qué
# le falta) y para revisar la lista después de añadir un servicio.

set -euo pipefail

USUARIO="server"
HOME_USR="/home/$USUARIO"
REMOTE_RCLONE="${SIS_BACKUP_REMOTE:-gdrive:Sistema_Backups}"
RETENCION="${SIS_BACKUP_RETENTION:-7d}"
RETENCION_MENSUAL="${SIS_BACKUP_RETENTION_MENSUAL:-100d}"
PASSPHRASE_FILE="$HOME_USR/.config/vault/backup-passphrase"
TAMANO_MINIMO=20480

# Explícito porque corre desde el cron de ROOT: sin esto rclone buscaría su
# configuración en /root/.config y fallaría en silencio.
export RCLONE_CONFIG="${RCLONE_CONFIG:-$HOME_USR/.config/rclone/rclone.conf}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

FECHA=$(date +%Y-%m-%d_%H-%M)
TMP_DIR=$(mktemp -d /tmp/sistema_backup.XXXXXX)
chmod 700 "$TMP_DIR"
STAGE="$TMP_DIR/sistema"
ARCHIVO_SALIDA="$TMP_DIR/sistema_$FECHA.tar.gz.gpg"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$STAGE"

# Llavero desechable: el cifrado simétrico no necesita ninguno.
export GNUPGHOME="$TMP_DIR/gnupg"
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"

log "[INFO] Iniciando copia del sistema: $FECHA$( [ $DRY_RUN = 1 ] && echo ' (dry-run)')"

if [ $DRY_RUN = 0 ]; then
  [ "$(id -u)" = 0 ] || { log "ERROR: hay que ser root (cron de root o sudo)"; exit 1; }
  [ -r "$PASSPHRASE_FILE" ] || { log "ERROR: no se puede leer $PASSPHRASE_FILE"; exit 1; }
fi

FALTAN=0

# copiar ORIGEN DESTINO_RELATIVO — copia un fichero o un directorio entero al
# staging conservando permisos. Si no existe, lo dice y sigue: no todos los
# ficheros tienen por qué estar (certs/ de Tailscale, gdm3 en una Ubuntu
# Server). Si existe y no se puede leer, cuenta como fallo.
copiar() {
  local origen="$1" destino="$STAGE/$2"
  if [ ! -e "$origen" ]; then
    log "[WARN] no existe: $origen"
    return 0
  fi
  if [ ! -r "$origen" ]; then
    log "[ERROR] sin permiso de lectura: $origen"
    FALTAN=$((FALTAN + 1))
    return 0
  fi
  mkdir -p "$(dirname "$destino")"
  cp -a "$origen" "$destino"
}

# capturar DESTINO_RELATIVO COMANDO... — guarda la salida de un comando.
capturar() {
  local destino="$STAGE/$1"; shift
  mkdir -p "$(dirname "$destino")"
  if ! "$@" > "$destino" 2>/dev/null; then
    log "[WARN] falló: $*"
    echo "(no disponible: $*)" > "$destino"
  fi
}

# ── /etc ─────────────────────────────────────────────────────────────────
for f in /etc/netplan/*.yaml; do copiar "$f" "etc/netplan/$(basename "$f")"; done
copiar /etc/systemd/resolved.conf        etc/systemd/resolved.conf
copiar /etc/docker/daemon.json           etc/docker/daemon.json
copiar /etc/sysctl.d/99-tailscale.conf   etc/sysctl.d/99-tailscale.conf
copiar /etc/default/tailscaled           etc/default/tailscaled
copiar /etc/gdm3/custom.conf             etc/gdm3/custom.conf
copiar /etc/hosts                        etc/hosts
copiar /etc/hostname                     etc/hostname
for f in /etc/ssh/ssh_host_*; do copiar "$f" "etc/ssh/$(basename "$f")"; done

# ── Tailscale: identidad del nodo ────────────────────────────────────────
# Con este fichero el nodo restaurado vuelve con la misma IP, el mismo nombre
# MagicDNS, los mismos `serve` y sin reautenticar. Sin él hay que borrar el
# nodo viejo en la consola y cambiar el nameserver del tailnet.
copiar /var/lib/tailscale/tailscaled.state tailscale/tailscaled.state
copiar /var/lib/tailscale/certs            tailscale/certs

# ── AdGuard ──────────────────────────────────────────────────────────────
# La ruta del conf se lee del contenedor, no se asume: ha vivido en
# /path/to/your/conf (ruta de tutorial copiada literal) antes de normalizarse
# a ~/adguard/conf.
ADG_CONF=$(docker inspect adguardhome \
  --format '{{range .Mounts}}{{if eq .Destination "/opt/adguardhome/conf"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)
if [ -n "$ADG_CONF" ]; then
  copiar "$ADG_CONF/AdGuardHome.yaml" adguard/AdGuardHome.yaml
else
  log "[WARN] no se pudo leer el bind mount de adguardhome; se prueba ~/adguard/conf"
  copiar "$HOME_USR/adguard/conf/AdGuardHome.yaml" adguard/AdGuardHome.yaml
fi
copiar "$HOME_USR/adguard/docker-compose.yml" adguard/docker-compose.yml

# ── cron ─────────────────────────────────────────────────────────────────
if [ "$(id -u)" = 0 ]; then
  capturar cron/root.txt   crontab -l
  capturar cron/server.txt crontab -u "$USUARIO" -l
else
  log "[ERROR] sin root no se puede leer el cron de root"; FALTAN=$((FALTAN + 1))
  capturar cron/server.txt crontab -l
fi

# ── home ─────────────────────────────────────────────────────────────────
RUTAS_HOME=(
  vaultwarden/docker-compose.yml
  vaultwarden/backup_vaultwarden.sh
  opengym/docker-compose.yml
  opengym/.env
  opengym/backup-opengym.sh
  vault_app/server/.env
  vault_app/server/docker-compose.yml
  vault_app/server/scripts/backup-to-drive.sh
  vault_app/server/data
  Combina/.env
  Combina/docker-compose.yml
  bot/.env
  .config/rclone/rclone.conf
  .gitconfig
  .bashrc
  .ssh/authorized_keys
  .claude/settings.json
)
shopt -s nullglob
for d in "$HOME_USR"/.claude/projects/*/memory; do
  RUTAS_HOME+=("${d#"$HOME_USR"/}")
done
shopt -u nullglob
for r in "${RUTAS_HOME[@]}"; do copiar "$HOME_USR/$r" "home/$r"; done

# ── manifiesto ───────────────────────────────────────────────────────────
capturar manifiesto/apt-manual.txt       apt-mark showmanual
capturar manifiesto/snaps.txt            snap list
capturar manifiesto/docker-images.txt    docker images --digests --format '{{.Repository}}:{{.Tag}} {{.Digest}} {{.CreatedAt}}'
capturar manifiesto/docker-ps.txt        docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Label "com.docker.compose.project.working_dir"}}'
capturar manifiesto/docker-volumes.txt   docker volume ls
capturar manifiesto/tailscale-status.json tailscale status --json
capturar manifiesto/tailscale-serve.json  tailscale serve status --json
capturar manifiesto/tailscale-prefs.json  tailscale debug prefs
capturar manifiesto/tailscale-dns.txt     tailscale dns status
capturar manifiesto/ip-addr.txt          ip -4 -br addr
capturar manifiesto/ip-route.txt         ip route
capturar manifiesto/os-release.txt       cat /etc/os-release
capturar manifiesto/uname.txt            uname -a
capturar manifiesto/unidades.txt         systemctl list-unit-files --state=enabled --no-pager
capturar manifiesto/listen.txt           ss -ltnup
date -Is > "$STAGE/manifiesto/fecha.txt"

# ── sumas ────────────────────────────────────────────────────────────────
( cd "$STAGE" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )

if [ $DRY_RUN = 1 ]; then
  log "[INFO] Contenido que entraría ($(find "$STAGE" -type f | wc -l) ficheros, $(du -sk "$STAGE" | cut -f1) KB):"
  ( cd "$STAGE" && find . -type f -printf '%10s  %p\n' | sort -k2 )
  [ $FALTAN = 0 ] || log "[WARN] $FALTAN fichero(s) sin permiso de lectura: lánzalo como root para la copia real"
  log "[INFO] dry-run terminado; no se ha cifrado ni subido nada."
  exit 0
fi

# Un tar al que le falta la identidad de Tailscale o el cron de root no es
# una copia del sistema: mejor fallar y que el bot lo vea que subir algo que
# parece completo y no lo es.
[ $FALTAN = 0 ] || { log "ERROR: $FALTAN fichero(s) no se pudieron leer; no se sube"; exit 1; }
[ -f "$STAGE/tailscale/tailscaled.state" ] || { log "ERROR: falta tailscaled.state"; exit 1; }
[ -f "$STAGE/adguard/AdGuardHome.yaml" ]   || { log "ERROR: falta AdGuardHome.yaml"; exit 1; }

tar -czf - -C "$STAGE" . \
  | gpg --batch --quiet --yes --symmetric --cipher-algo AES256 \
        --passphrase-file "$PASSPHRASE_FILE" --output "$ARCHIVO_SALIDA"

TAMANO=$(stat -c %s "$ARCHIVO_SALIDA")
[ "$TAMANO" -gt "$TAMANO_MINIMO" ] || { log "ERROR: archivo sospechosamente pequeño ($TAMANO bytes)"; exit 1; }
log "[INFO] Archivo listo: $(basename "$ARCHIVO_SALIDA") ($((TAMANO / 1024)) KB, $(find "$STAGE" -type f | wc -l) ficheros)"

rclone copy "$ARCHIVO_SALIDA" "$REMOTE_RCLONE/"
log "[INFO] Subido a $REMOTE_RCLONE"

# Purgar solo después de una subida correcta.
rclone delete "$REMOTE_RCLONE/" --min-age "$RETENCION" --max-depth 1
log "[INFO] Copias en el remoto: $(rclone lsf "$REMOTE_RCLONE/" --files-only | wc -l)"

# Copia mensual aparte: 200 KB al mes que cubren el caso "un cambio malo pasó
# desapercibido más de una semana". Se guardan unos tres meses.
if [ "$(date +%d)" = "01" ]; then
  rclone copy "$ARCHIVO_SALIDA" "$REMOTE_RCLONE/mensual/"
  rclone delete "$REMOTE_RCLONE/mensual/" --min-age "$RETENCION_MENSUAL"
  log "[INFO] Copia mensual subida; mensuales en el remoto: $(rclone lsf "$REMOTE_RCLONE/mensual/" | wc -l)"
fi

# ── repos como git bundle ────────────────────────────────────────────────
# Los tres repos enteros (historia incluida), cifrados, solo cuando HEAD ha
# cambiado desde la última subida. Son ~3 MB en total. vault_app y Combina
# son privados en GitHub: sin esto, restaurar exigiría un token que habría
# que guardar en algún sitio; con esto, la única llave es la passphrase.
EXISTENTES=$(rclone lsf "$REMOTE_RCLONE/repos/" 2>/dev/null || true)
for repo in homelab vault_app Combina; do
  DIR="$HOME_USR/$repo"
  [ -d "$DIR/.git" ] || { log "[WARN] $DIR no es un repo; se omite"; continue; }
  HASH=$(git -c safe.directory='*' -C "$DIR" rev-parse --short=12 HEAD)
  NOMBRE="$repo-$HASH.bundle.gpg"
  if echo "$EXISTENTES" | grep -qx "$NOMBRE"; then
    continue
  fi
  git -c safe.directory='*' -C "$DIR" bundle create -q "$TMP_DIR/$repo.bundle" --all
  gpg --batch --quiet --yes --symmetric --cipher-algo AES256 \
      --passphrase-file "$PASSPHRASE_FILE" --output "$TMP_DIR/$NOMBRE" "$TMP_DIR/$repo.bundle"
  rclone copy "$TMP_DIR/$NOMBRE" "$REMOTE_RCLONE/repos/"
  # Borrar las versiones anteriores de este repo, solo tras subir la nueva.
  # (grep sin coincidencias devuelve 1 y con pipefail tumbaría el script.)
  VIEJOS=$(echo "$EXISTENTES" | grep -E "^$repo-[0-9a-f]+\.bundle\.gpg$" | grep -vx "$NOMBRE" || true)
  for viejo in $VIEJOS; do rclone deletefile "$REMOTE_RCLONE/repos/$viejo"; done
  log "[INFO] repos/$NOMBRE subido ($(( $(stat -c %s "$TMP_DIR/$NOMBRE") / 1024 )) KB)"
done

# ── LEEME ────────────────────────────────────────────────────────────────
cat > "$TMP_DIR/LEEME.txt" <<'LEEME'
Copias del sistema del servidor de casa. Para volver a montarlo entero
hace falta SOLO la passphrase (en papel) y esta carpeta.

1. Instalar Ubuntu 26.04 con usuario `server` y hostname `server`.
2. Descargar desde esta carpeta (drive.google.com, con el navegador) a
   una carpeta ~/kit de la máquina nueva:
     - el sistema_FECHA.tar.gz.gpg más reciente
     - repos/homelab-*.bundle.gpg, repos/vault_app-*.bundle.gpg,
       repos/Combina-*.bundle.gpg
3. Sacar el script (o `git clone https://github.com/SaguadoDev/homelab`):
     gpg -d ~/kit/homelab-*.bundle.gpg > ~/kit/homelab.bundle
     git clone ~/kit/homelab.bundle ~/homelab
4. sudo bash ~/homelab/scripts/restaurar-servidor.sh --kit ~/kit
   Pide la passphrase y nada más. Al acabar: reserva DHCP en el router
   para la MAC nueva si cambió la máquina.

Todo lo demás está en docs/recuperacion.md del repo homelab.
LEEME
rclone copy "$TMP_DIR/LEEME.txt" "$REMOTE_RCLONE/"

log "[INFO] Copia finalizada."

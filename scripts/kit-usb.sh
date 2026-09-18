#!/bin/bash
#
# Kit de recuperación — llena un USB con lo que hace falta para arrancar
# restaurar-servidor.sh cuando este disco ya no exista.
#
#   ./kit-usb.sh /media/server/KIT
#
# Deja en el USB:
#   rclone.conf              acceso a Drive (token + client_id/secret propios)
#   sistema_FECHA.tar.gz.gpg el último tar del sistema (por si Drive no está)
#   restaurar-servidor.sh    el script suelto, por si no se puede clonar el repo
#   repos/*.bundle           homelab, vault_app y Combina completos (git bundle)
#   github-token             NO lo escribe este script: lo pone el humano a mano
#                            (PAT de solo lectura sobre vault_app y Combina)
#   KIT-FECHA.txt            qué hay, cuándo se hizo y qué falta
#
# NO copia la passphrase. Va en papel, junto al USB, nunca en el mismo soporte
# que el tar que protege. Sin ella el USB es ruido; con ella y sin USB todavía
# se puede rehacer todo (rclone config + GitHub + Drive), solo más lento.
#
# Repetir cuando cambie algo del kit (token, rclone) y como mínimo cada tres
# meses: comprobar_copias() del bot avisa si el tar del sistema en Drive es
# viejo, pero nadie vigila el USB.

set -euo pipefail

DEST="${1:-}"
[ -n "$DEST" ] && [ -d "$DEST" ] || { echo "uso: $0 /ruta/al/usb"; exit 2; }
touch "$DEST/.kit-escribible" 2>/dev/null && rm -f "$DEST/.kit-escribible" || { echo "no se puede escribir en $DEST"; exit 1; }

HOME_USR="/home/server"
REMOTE_SISTEMA="gdrive:Sistema_Backups"
FECHA=$(date +%Y-%m-%d)
log() { echo "[$(date '+%H:%M:%S')] $*"; }

install -m 600 "$HOME_USR/.config/rclone/rclone.conf" "$DEST/rclone.conf"
log "rclone.conf copiado"

NOMBRE=$(rclone lsf "$REMOTE_SISTEMA/" --files-only --include 'sistema_*' | sort | tail -1)
if [ -n "$NOMBRE" ]; then
  rm -f "$DEST"/sistema_*.tar.gz.gpg
  rclone copy "$REMOTE_SISTEMA/$NOMBRE" "$DEST/"
  log "tar del sistema: $NOMBRE ($(stat -c %s "$DEST/$NOMBRE") bytes)"
else
  log "[WARN] no hay ningún tar del sistema en $REMOTE_SISTEMA"
fi

install -m 755 "$HOME_USR/homelab/scripts/restaurar-servidor.sh" "$DEST/restaurar-servidor.sh"
log "restaurar-servidor.sh copiado"

mkdir -p "$DEST/repos"
for r in homelab vault_app Combina; do
  if [ -d "$HOME_USR/$r/.git" ]; then
    git -C "$HOME_USR/$r" bundle create -q "$DEST/repos/$r.bundle" --all
    log "repos/$r.bundle ($(git -C "$HOME_USR/$r" rev-parse --short HEAD))"
  fi
done

if [ -s "$DEST/github-token" ]; then
  TOKEN_MSG="github-token: presente (comprobar que no ha caducado)"
else
  TOKEN_MSG="github-token: FALTA — crear un fine-grained PAT de solo lectura (Contents) sobre vault_app y Combina y guardarlo en $DEST/github-token"
fi

cat > "$DEST/KIT-$FECHA.txt" <<FIN
Kit de recuperación del servidor — $FECHA

Contenido:
  rclone.conf               acceso a Drive. Lleva client_id/client_secret propios
                            con scope drive.file: rehacerlo con otro cliente deja
                            las copias invisibles.
  ${NOMBRE:-sistema_*.tar.gz.gpg (no había)}
  restaurar-servidor.sh     sudo bash restaurar-servidor.sh --kit <este USB>
  repos/*.bundle            git clone repos/homelab.bundle homelab  (etc.)
  $TOKEN_MSG

NO está aquí, y es a propósito:
  - La passphrase de las copias: en papel, en otro sitio. Y en la bóveda de
    Bitwarden, que el móvil abre sin red.
  - El nombre del proyecto de Google Cloud del cliente OAuth de rclone: en el
    mismo papel.

Procedimiento completo: docs/recuperacion.md del repo homelab
(github.com/SaguadoDev/homelab, público) o dentro de repos/homelab.bundle.
FIN
rm -f "$DEST"/KIT-*.txt.old 2>/dev/null || true
ls "$DEST"/KIT-*.txt | grep -v "KIT-$FECHA.txt" | xargs -r rm -f
sync
log "listo: $DEST/KIT-$FECHA.txt"
[ -s "$DEST/github-token" ] || log "[WARN] $TOKEN_MSG"

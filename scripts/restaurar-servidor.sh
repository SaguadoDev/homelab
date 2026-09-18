#!/bin/bash
#
# De una Ubuntu 26.04 recién instalada al servidor completo.
#
# Lo que tiene que ver quien lo ejecuta (docs/recuperacion.md):
#
#   1. Instalar Ubuntu 26.04 con usuario `server` y hostname `server`.
#   2. git clone https://github.com/SaguadoDev/homelab
#      sudo bash homelab/scripts/restaurar-servidor.sh --kit /media/server/KIT
#   3. Cuando lo pida: la passphrase (del papel), rclone.conf (del USB) y el
#      token de GitHub para los dos repos privados. Nada más se teclea.
#   4. Si cambió la máquina: reserva DHCP en el router para la MAC nueva.
#
# Todo lo demás —.env, composes, cron, AdGuard, la identidad de Tailscale con
# su IP y sus `serve`, la red del host— sale del tar de `backup-sistema.sh`,
# y los datos, de las cuatro copias de siempre.
#
# Doce fases, en orden, idempotentes: cada una comprueba el estado antes de
# actuar y se puede relanzar. `--desde N` retoma desde una fase (por ejemplo
# tras perder la sesión SSH cuando la IP fija entra en vigor en la fase 3).
#
# Flags:
#   --kit DIR          directorio con backup-passphrase, rclone.conf,
#                      github-token (opcional) y sistema_*.tar.gz.gpg (opcional)
#   --tar FICHERO      tar del sistema concreto en vez del último de Drive
#   --desde N          empezar en la fase N
#   --solo N           ejecutar solo la fase N
#   --repos-desde DIR  clonar vault_app, Combina y homelab desde DIR/<nombre>
#                      en vez de GitHub (ensayo: clones locales montados)
#   --extras           instalar también brave-browser, npm y fastfetch
#   --con-backups      en la fase 12, lanzar los cinco scripts de copia
#   --ensayo           modo VM: no toca la IP fija ni el hostname, no restaura
#                      la identidad de Tailscale, no instala cron ni bot, y
#                      AdGuard escucha en la IP de la VM. Nunca en producción.
#   --con-tailscale    en ensayo, hacer `tailscale up` como nodo nuevo
#                      (server-ensayo) para probar los serve
#
# Se ejecuta con sudo. Deja un log en /home/server/restauracion-FECHA.log.

set -euo pipefail

USUARIO="server"
HOME_USR="/home/$USUARIO"
REPO_URL_HOMELAB="https://github.com/SaguadoDev/homelab.git"
REPO_URL_VAULT_APP="https://github.com/SaguadoDev/vault_app.git"
REPO_URL_COMBINA="https://github.com/SaguadoDev/Combina.git"
DOCKER_CODENAME="${DOCKER_CODENAME:-}"          # por si Docker aún no publica para esta Ubuntu
REMOTE_SISTEMA="gdrive:Sistema_Backups"
REMOTE_VW="gdrive:Vaultwarden_Backups"
REMOTE_VAULT="gdrive:Vault_Backups"
REMOTE_OG="gdrive:openGym_Backups"
REMOTE_ARM="gdrive:Armario_Backups"
TRABAJO="/root/restauracion"                    # tar descifrado y descargas; se borra en la fase 12
SIS="$TRABAJO/sistema"
PASSPHRASE_FILE="$HOME_USR/.config/vault/backup-passphrase"
RCLONE_CONF="$HOME_USR/.config/rclone/rclone.conf"
export RCLONE_CONFIG="$RCLONE_CONF"

KIT=""; TAR_SISTEMA=""; DESDE=1; SOLO=""; REPOS_DESDE=""; EXTRAS=0
CON_BACKUPS=0; ENSAYO=0; CON_TAILSCALE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --kit) KIT="$2"; shift 2 ;;
    --tar) TAR_SISTEMA="$2"; shift 2 ;;
    --desde) DESDE="$2"; shift 2 ;;
    --solo) SOLO="$2"; shift 2 ;;
    --repos-desde) REPOS_DESDE="$2"; shift 2 ;;
    --extras) EXTRAS=1; shift ;;
    --con-backups) CON_BACKUPS=1; shift ;;
    --ensayo) ENSAYO=1; shift ;;
    --con-tailscale) CON_TAILSCALE=1; shift ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "flag desconocido: $1"; exit 2 ;;
  esac
done

[ "$(id -u)" = 0 ] || { echo "Ejecutar con sudo."; exit 1; }
id "$USUARIO" >/dev/null 2>&1 || { echo "No existe el usuario $USUARIO: crear la Ubuntu con ese usuario."; exit 1; }

LOG="$HOME_USR/restauracion-$(date +%Y-%m-%d_%H-%M).log"
exec > >(tee -a "$LOG") 2>&1
chown "$USUARIO:$USUARIO" "$LOG" 2>/dev/null || true

log()   { echo "[$(date '+%H:%M:%S')] $*"; }
fase()  { echo; echo "══════════════════════════════════════════════════════"; echo " FASE $1 — $2"; echo "══════════════════════════════════════════════════════"; }
ok()    { echo "   ✔ $*"; }
fallo() { echo "   ✘ $*"; exit 1; }
como_usuario() { sudo -u "$USUARIO" -H env RCLONE_CONFIG="$RCLONE_CONF" "$@"; }
toca_fase() { # ¿hay que ejecutar la fase N?
  local n="$1"
  if [ -n "$SOLO" ]; then [ "$SOLO" = "$n" ]; else [ "$n" -ge "$DESDE" ]; fi
}
esperar() { # esperar "descripción" segundos comando...
  local desc="$1" seg="$2"; shift 2
  local i=0
  until "$@" >/dev/null 2>&1; do
    i=$((i + 1)); [ $i -le "$seg" ] || fallo "tiempo agotado esperando: $desc"
    sleep 1
  done
  ok "$desc"
}
ultimo_remoto() { # ultimo_remoto gdrive:Carpeta prefijo → nombre del fichero más reciente
  rclone lsf "$1/" --files-only --include "$2*" | sort | tail -1
}
descargar_y_descifrar() { # descargar_y_descifrar gdrive:Carpeta prefijo salida
  local remoto="$1" prefijo="$2" salida="$3" nombre
  nombre=$(ultimo_remoto "$remoto" "$prefijo")
  [ -n "$nombre" ] || fallo "no hay ningún $prefijo* en $remoto"
  log "descargando $nombre"
  rclone copy "$remoto/$nombre" "$TRABAJO/"
  descifrar "$TRABAJO/$nombre" "$salida"
}
descifrar() {
  local gnupg; gnupg=$(mktemp -d); chmod 700 "$gnupg"
  GNUPGHOME="$gnupg" gpg --batch --quiet --yes --passphrase-file "$PASSPHRASE_FILE" \
    --decrypt "$1" > "$2"
  rm -rf "$gnupg"
}
compose_healthy() { # compose_healthy contenedor
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null)" = "healthy" ]
}
ip_local() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1; }

mkdir -p "$TRABAJO" && chmod 700 "$TRABAJO"
echo "Restauración del servidor — $(date -Is) — log en $LOG"
[ $ENSAYO = 1 ] && echo "MODO ENSAYO: sin IP fija, sin hostname, sin identidad de Tailscale, sin cron, sin bot. AdGuard en la IP de la VM."
[ -n "$SOLO" ] && echo "Solo la fase $SOLO" || echo "Desde la fase $DESDE"

# ═════════════════════════════════════════════════════════════════════════
if toca_fase 1; then fase 1 "Paquetes"
  . /etc/os-release
  CODENAME="${DOCKER_CODENAME:-$VERSION_CODENAME}"
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.asc ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $CODENAME stable" \
      > /etc/apt/sources.list.d/docker.list
    ok "repo de Docker ($CODENAME)"
  fi
  if [ ! -f /usr/share/keyrings/tailscale-archive-keyring.gpg ]; then
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$VERSION_CODENAME.noarmor.gpg" -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$VERSION_CODENAME.tailscale-keyring.list" -o /etc/apt/sources.list.d/tailscale.list
    ok "repo de Tailscale"
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  # cockpit y pcp entran por decisión del usuario (decisiones.md §14): los usa
  # desde el PC y el móvil. Es la excepción consciente a "nada en la LAN".
  apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    tailscale rclone gnupg python3-venv sqlite3 bind9-dnsutils jq curl git \
    lm-sensors cockpit pcp
  if [ $EXTRAS = 1 ]; then
    if [ ! -f /etc/apt/sources.list.d/brave-browser-release.sources ]; then
      curl -fsS https://dl.brave.com/install.sh | sh || log "[WARN] brave no se pudo instalar"
    fi
    apt-get install -y -qq npm fastfetch || true
  fi
  usermod -aG docker "$USUARIO"
  systemctl enable --now docker cockpit.socket >/dev/null
  ok "docker $(docker version --format '{{.Server.Version}}'), tailscale $(tailscale version | head -1), rclone $(rclone version | head -1 | awk '{print $2}')"
fi

# ═════════════════════════════════════════════════════════════════════════
if toca_fase 2; then fase 2 "Kit y tar del sistema"
  # Passphrase
  if [ ! -s "$PASSPHRASE_FILE" ]; then
    install -d -m 700 -o "$USUARIO" -g "$USUARIO" "$HOME_USR/.config/vault"
    if [ -n "$KIT" ] && [ -s "$KIT/backup-passphrase" ]; then
      install -m 600 -o "$USUARIO" -g "$USUARIO" "$KIT/backup-passphrase" "$PASSPHRASE_FILE"
    else
      read -r -s -p "Passphrase de las copias (del papel): " PP; echo
      printf '%s' "$PP" > "$PASSPHRASE_FILE"; unset PP
      chown "$USUARIO:$USUARIO" "$PASSPHRASE_FILE"; chmod 600 "$PASSPHRASE_FILE"
    fi
  fi
  ok "passphrase en $PASSPHRASE_FILE"
  # rclone.conf
  if [ ! -s "$RCLONE_CONF" ]; then
    install -d -m 700 -o "$USUARIO" -g "$USUARIO" "$HOME_USR/.config/rclone"
    if [ -n "$KIT" ] && [ -s "$KIT/rclone.conf" ]; then
      install -m 600 -o "$USUARIO" -g "$USUARIO" "$KIT/rclone.conf" "$RCLONE_CONF"
    else
      read -r -p "Ruta a rclone.conf (vacío = rehacerlo con rclone config): " RUTA
      if [ -n "$RUTA" ]; then
        install -m 600 -o "$USUARIO" -g "$USUARIO" "$RUTA" "$RCLONE_CONF"
      else
        echo "Remoto: nombre gdrive, tipo drive, scope drive.file, y el MISMO client_id/client_secret del proyecto de Google Cloud (docs/recuperacion.md)."
        como_usuario rclone config
      fi
    fi
  fi
  rclone lsd gdrive: >/dev/null || fallo "rclone no llega a gdrive: — revisar rclone.conf"
  ok "rclone ve gdrive: ($(rclone lsd gdrive: | wc -l) carpetas)"
  # Token de GitHub (solo hace falta si se clona de GitHub)
  if [ -z "$REPOS_DESDE" ] && [ ! -s "$TRABAJO/github-token" ]; then
    if [ -n "$KIT" ] && [ -s "$KIT/github-token" ]; then
      install -m 600 "$KIT/github-token" "$TRABAJO/github-token"
    else
      read -r -s -p "Token de GitHub con lectura de vault_app y Combina: " TK; echo
      printf '%s' "$TK" > "$TRABAJO/github-token"; chmod 600 "$TRABAJO/github-token"; unset TK
    fi
  fi
  # Tar del sistema
  if [ ! -f "$SIS/SHA256SUMS" ]; then
    rm -rf "$SIS"; mkdir -p "$SIS"
    if [ -n "$TAR_SISTEMA" ]; then
      GPG_IN="$TAR_SISTEMA"
    elif [ -n "$KIT" ] && ls "$KIT"/sistema_*.tar.gz.gpg >/dev/null 2>&1 && ! rclone lsd "$REMOTE_SISTEMA" >/dev/null 2>&1; then
      GPG_IN=$(ls "$KIT"/sistema_*.tar.gz.gpg | sort | tail -1)
      log "[WARN] Drive no responde; se usa el tar del kit: $GPG_IN"
    else
      NOMBRE=$(ultimo_remoto "$REMOTE_SISTEMA" sistema_)
      [ -n "$NOMBRE" ] || fallo "no hay ningún sistema_*.tar.gz.gpg en $REMOTE_SISTEMA"
      rclone copy "$REMOTE_SISTEMA/$NOMBRE" "$TRABAJO/"
      GPG_IN="$TRABAJO/$NOMBRE"
    fi
    descifrar "$GPG_IN" "$TRABAJO/sistema.tar.gz"
    tar -xzf "$TRABAJO/sistema.tar.gz" -C "$SIS"
    ( cd "$SIS" && sha256sum -c --quiet SHA256SUMS ) || fallo "las sumas del tar del sistema no cuadran"
    ok "tar del sistema: $(basename "$GPG_IN"), $(find "$SIS" -type f | wc -l) ficheros, sumas correctas"
    echo "   fecha del tar: $(cat "$SIS/manifiesto/fecha.txt" 2>/dev/null)"
  else
    ok "tar del sistema ya extraído en $SIS"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════
if toca_fase 3; then fase 3 "/etc: red, DNS del host, Docker, sysctl"
  [ -d "$SIS/etc" ] || fallo "falta $SIS/etc: ejecutar la fase 2"
  install -m 644 "$SIS/etc/systemd/resolved.conf" /etc/systemd/resolved.conf
  systemctl restart systemd-resolved
  # Incidencia 9: tailscaled decide si resolved está en uso mirando a dónde
  # apunta /etc/resolv.conf. Tiene que ser el stub.
  ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  ok "resolved → $(resolvectl status 2>/dev/null | grep -m1 'DNS Servers' | sed 's/^ *//')"
  install -d /etc/docker && install -m 644 "$SIS/etc/docker/daemon.json" /etc/docker/daemon.json
  systemctl restart docker
  ok "docker daemon.json"
  install -m 644 "$SIS/etc/sysctl.d/99-tailscale.conf" /etc/sysctl.d/99-tailscale.conf
  sysctl --system >/dev/null
  ok "ip_forward=$(sysctl -n net.ipv4.ip_forward)"
  [ -f "$SIS/etc/default/tailscaled" ] && install -m 644 "$SIS/etc/default/tailscaled" /etc/default/tailscaled
  if [ $ENSAYO = 1 ]; then
    ok "ensayo: netplan, hostname, claves SSH y gdm3 NO se tocan"
  else
    if [ -d "$SIS/etc/gdm3" ] && [ -d /etc/gdm3 ]; then
      install -m 644 "$SIS/etc/gdm3/custom.conf" /etc/gdm3/custom.conf; ok "gdm3 (autologin)"
    fi
    if ls "$SIS"/etc/ssh/ssh_host_* >/dev/null 2>&1; then
      for f in "$SIS"/etc/ssh/ssh_host_*; do
        case "$f" in *.pub) install -m 644 "$f" /etc/ssh/;; *) install -m 600 "$f" /etc/ssh/;; esac
      done
      systemctl restart ssh; ok "identidad SSH del host restaurada"
    fi
    hostnamectl set-hostname "$(cat "$SIS/etc/hostname")"
    install -m 644 "$SIS/etc/hosts" /etc/hosts
    ok "hostname $(hostname)"
    if [ "$(ip_local)" != "192.168.1.50" ]; then
      echo
      echo "   ⚠ Ahora entra en vigor la IP fija 192.168.1.50. Si estás por SSH la sesión se"
      echo "     cortará: vuelve a entrar en 192.168.1.50 y relanza con --desde 4."
      sleep 3
    fi
    rm -f /etc/netplan/*.yaml
    for f in "$SIS"/etc/netplan/*.yaml; do install -m 600 "$f" /etc/netplan/; done
    netplan generate && netplan apply
    sleep 3
    [ "$(ip_local)" = "192.168.1.50" ] && ok "IP fija 192.168.1.50" || log "[WARN] la IP aún no es 192.168.1.50: $(ip_local)"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════
if toca_fase 4; then fase 4 "Repos, home, secretos, bot"
  [ -d "$SIS/home" ] || fallo "falta $SIS/home: ejecutar la fase 2"
  clonar() { # clonar nombre url destino
    local nombre="$1" url="$2" dest="$3"
    if [ -d "$dest/.git" ]; then ok "$nombre ya clonado"; return; fi
    if [ -n "$REPOS_DESDE" ]; then
      # Clones montados desde fuera (ensayo): git se niega si el dueño no es
      # quien clona; aquí es un origen de solo lectura y da igual.
      como_usuario git -c safe.directory='*' clone -q "$REPOS_DESDE/$nombre" "$dest"
    elif [ "$nombre" = homelab ]; then
      como_usuario git clone -q "$url" "$dest"
    else
      como_usuario git -c credential.helper="!f() { echo username=x-access-token; echo password=$(cat "$TRABAJO/github-token"); }; f" \
        clone -q "$url" "$dest"
    fi
    ok "$nombre clonado en $dest"
  }
  clonar homelab   "$REPO_URL_HOMELAB"   "$HOME_USR/homelab"
  clonar vault_app "$REPO_URL_VAULT_APP" "$HOME_USR/vault_app"
  clonar Combina   "$REPO_URL_COMBINA"   "$HOME_USR/Combina"

  # Ficheros vivos del tar → home, conservando la estructura. Pisa los del
  # repo (los del repo están saneados; los vivos son los que corren).
  como_usuario mkdir -p "$HOME_USR/vaultwarden" "$HOME_USR/adguard/work" "$HOME_USR/opengym" "$HOME_USR/bot"
  ( cd "$SIS/home" && find . -type f -print0 | while IFS= read -r -d '' f; do
      install -D -m "$(stat -c %a "$f")" -o "$USUARIO" -g "$USUARIO" "$f" "$HOME_USR/$f"
    done )
  for e in vault_app/server/.env opengym/.env Combina/.env bot/.env .config/rclone/rclone.conf; do
    [ -f "$HOME_USR/$e" ] && chmod 600 "$HOME_USR/$e"
  done
  ok "composes, .env, scripts de backup, dotfiles y memoria de Claude en su sitio"

  # AdGuard: conf a ~/adguard/conf (root, como lo escribe el contenedor) y el
  # compose siempre con ./conf y ./work aunque el tar venga de la época de
  # /path/to/your.
  install -d -m 755 "$HOME_USR/adguard/conf"
  install -m 600 "$SIS/adguard/AdGuardHome.yaml" "$HOME_USR/adguard/conf/AdGuardHome.yaml"
  sed -E 's#- .*:/opt/adguardhome/work#- ./work:/opt/adguardhome/work#; s#- .*:/opt/adguardhome/conf#- ./conf:/opt/adguardhome/conf#' \
    "$SIS/adguard/docker-compose.yml" > "$HOME_USR/adguard/docker-compose.yml"
  chown "$USUARIO:$USUARIO" "$HOME_USR/adguard/docker-compose.yml"
  ok "AdGuard: conf y compose"

  # Bot: el código es el del repo; el .env viene del tar; el venv se crea.
  como_usuario cp "$HOME_USR"/homelab/bot/*.py "$HOME_USR/homelab/bot/requirements.txt" "$HOME_USR/bot/"
  como_usuario mkdir -p "$HOME_USR/bot/logs"
  if [ ! -x "$HOME_USR/bot/venv/bin/python" ]; then
    como_usuario python3 -m venv "$HOME_USR/bot/venv"
    como_usuario "$HOME_USR/bot/venv/bin/pip" install -q -r "$HOME_USR/bot/requirements.txt"
  fi
  ok "bot en ~/bot con venv"
  [ -f "$HOME_USR/bot/.env" ] || log "[WARN] falta ~/bot/.env (no venía en el tar)"
fi

# ═════════════════════════════════════════════════════════════════════════
if toca_fase 5; then fase 5 "Tailscale"
  if [ $ENSAYO = 1 ] && [ $CON_TAILSCALE = 0 ]; then
    ok "ensayo: Tailscale no se toca (usa --con-tailscale para probar los serve como nodo nuevo)"
  else
    systemctl enable --now tailscaled >/dev/null
    if [ $ENSAYO = 0 ] && [ -f "$SIS/tailscale/tailscaled.state" ] && \
       [ "$(tailscale status --json 2>/dev/null | jq -r .BackendState)" != "Running" ]; then
      # Identidad restaurada: misma IP, mismo nombre, mismos serve, sin login.
      # Solo si el nodo viejo está muerto de verdad: dos máquinas con la misma
      # clave se pisan.
      systemctl stop tailscaled
      install -m 600 "$SIS/tailscale/tailscaled.state" /var/lib/tailscale/tailscaled.state
      if [ -d "$SIS/tailscale/certs" ]; then
        install -d -m 700 /var/lib/tailscale/certs
        cp -a "$SIS/tailscale/certs/." /var/lib/tailscale/certs/
      fi
      systemctl start tailscaled
      sleep 3
      ok "tailscaled.state restaurado"
    fi
    ESTADO=$(tailscale status --json 2>/dev/null | jq -r .BackendState)
    if [ "$ESTADO" != "Running" ]; then
      echo "   Tailscale necesita login (estado: $ESTADO). Abre el enlace que sale a continuación."
      if [ $ENSAYO = 1 ]; then
        tailscale up --hostname server-ensayo --accept-dns
      else
        echo "   Si el nodo 'server' viejo sigue en la consola, bórralo ANTES de autenticar para heredar el nombre."
        tailscale up --advertise-exit-node --accept-dns
      fi
    fi
    esperar "tailscale en Running" 60 sh -c '[ "$(tailscale status --json | jq -r .BackendState)" = Running ]'
    NOMBRE_TS=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
    IP_TS=$(tailscale ip -4)
    ok "nodo $NOMBRE_TS ($IP_TS)"
    if [ $ENSAYO = 0 ]; then
      case "$NOMBRE_TS" in server.*) ;; *) fallo "el nodo se llama $NOMBRE_TS, no server.<tailnet>: las passkeys de openGym y la URL del APK de Combina dependen del nombre. Borrar el nodo viejo en la consola y repetir la fase 5." ;; esac
    fi
    # serve: si el state venía con ellos ya están; si no, se aplican los del repo.
    if ! tailscale serve status 2>/dev/null | grep -q 'proxy'; then
      python3 - "$HOME_USR/homelab/tailscale/serve-config.json" "$NOMBRE_TS" <<'PY' | while read -r puerto destino; do tailscale serve --bg --https="$puerto" "$destino" >/dev/null; done
import json, sys
cfg = json.load(open(sys.argv[1]))
for host, v in cfg["Web"].items():
    puerto = host.rsplit(":", 1)[1]
    print(puerto, v["Handlers"]["/"]["Proxy"])
PY
      ok "serve aplicados desde tailscale/serve-config.json"
    fi
    tailscale serve status | grep -E '^https' | sed 's/^/     /'
  fi
fi

# ═════════════════════════════════════════════════════════════════════════
if toca_fase 6; then fase 6 "AdGuard Home"
  install -d /etc/systemd/system/docker.service.d
  ln -sfn "$HOME_USR/homelab/systemd/docker-after-tailscaled.conf" /etc/systemd/system/docker.service.d/after-tailscaled.conf
  systemctl daemon-reload
  ok "drop-in docker After=tailscaled"
  YAML="$HOME_USR/adguard/conf/AdGuardHome.yaml"
  if [ $ENSAYO = 1 ]; then
    # En la VM ni 192.168.1.50 ni la IP del tailnet existen; y 0.0.0.0 pisaría
    # el stub de resolved (incidencia 9). Se escucha en la IP de la VM.
    python3 - "$YAML" "$(ip_local)" <<'PY'
import re, sys
p, ip = sys.argv[1], sys.argv[2]
s = open(p).read()
s, n = re.subn(r'(\n  bind_hosts:\n)(?:    - [^\n]+\n)+', r'\1    - ' + ip + '\n', s, count=1)
assert n == 1, "bind_hosts no encontrado"
open(p, 'w').write(s)
PY
    ok "ensayo: bind_hosts → $(ip_local)"
  fi
  ( cd "$HOME_USR/adguard" && docker compose up -d --quiet-pull 2>&1 | sed 's/^/     /' )
  IP_DNS=$(grep -A1 'bind_hosts:' "$YAML" | tail -1 | awk '{print $2}')
  esperar "AdGuard responde en $IP_DNS" 60 dig +short +time=2 @"$IP_DNS" example.com
  R=$(dig +short +time=3 @"$IP_DNS" doubleclick.net | head -1)
  # En una máquina nueva AdGuard tarda un minuto en bajar las listas: la
  # primera consulta puede salir sin filtrar aunque la configuración sea la
  # buena. Se reintenta un rato antes de avisar.
  for _ in $(seq 1 24); do
    R=$(dig +short +time=3 @"$IP_DNS" doubleclick.net | head -1)
    [ "$R" = "0.0.0.0" ] && break
    sleep 5
  done
  [ "$R" = "0.0.0.0" ] && ok "filtrado activo (doubleclick.net → 0.0.0.0)" || log "[WARN] doubleclick.net → '$R' tras dos minutos: revisar las listas en la web de AdGuard"
  if [ $ENSAYO = 0 ]; then
    R=$(dig +short +time=3 @"$IP_DNS" "$(tailscale status --json | jq -r .Self.DNSName | sed 's/\.$//')" | head -1)
    [ "$R" = "$(tailscale ip -4)" ] && ok "split DNS ts.net → $R" || log "[WARN] split DNS: $R"
    grep -q "$(tailscale ip -4)" "$YAML" && ok "bind_hosts incluye la IP del tailnet" || log "[WARN] bind_hosts no incluye $(tailscale ip -4): el DNS del tailnet no funcionará (decisión §13)"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════
if toca_fase 7; then fase 7 "Vaultwarden"
  VW="$HOME_USR/vaultwarden"
  if [ -f "$VW/vw-data/db.sqlite3" ]; then
    ok "vw-data ya existe; no se pisa"
  else
    descargar_y_descifrar "$REMOTE_VW" vaultwarden_ "$TRABAJO/vw.tar.gz"
    install -d "$VW/vw-data"
    tar -xzf "$TRABAJO/vw.tar.gz" -C "$VW/vw-data"
    # El compose viaja dentro de la copia; el que manda es el del tar del sistema.
    rm -f "$VW/vw-data/docker-compose.yml"
    ok "vw-data restaurado ($(sqlite3 "$VW/vw-data/db.sqlite3" 'select count(*) from users') usuarios, $(sqlite3 "$VW/vw-data/db.sqlite3" 'select count(*) from ciphers') ítems)"
  fi
  MD5_ANTES=$(md5sum "$VW"/vw-data/rsa_key* 2>/dev/null | head -1 | awk '{print $1}')
  ( cd "$VW" && docker compose up -d --quiet-pull 2>&1 | sed 's/^/     /' )
  esperar "Vaultwarden /alive" 90 sh -c 'curl -sf http://127.0.0.1:8080/alive >/dev/null'
  MD5_DESPUES=$(md5sum "$VW"/vw-data/rsa_key* 2>/dev/null | head -1 | awk '{print $1}')
  [ "$MD5_ANTES" = "$MD5_DESPUES" ] && ok "rsa_key intacta" || fallo "rsa_key.pem cambió al arrancar: la clave no se restauró y las sesiones no valdrán"
  EMAIL=$(sqlite3 "$VW/vw-data/db.sqlite3" 'select email from users limit 1')
  KDF=$(curl -s -X POST http://127.0.0.1:8080/identity/accounts/prelogin -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\"}")
  echo "$KDF" | grep -q -i kdf && ok "prelogin devuelve KDF para $EMAIL" || log "[WARN] prelogin: $KDF"
fi

# ═════════════════════════════════════════════════════════════════════════
if toca_fase 8; then fase 8 "Vault App (Postgres compartido + API)"
  VA="$HOME_USR/vault_app/server"
  [ -f "$VA/.env" ] || fallo "falta $VA/.env"
  PG_USER=$(grep -m1 '^POSTGRES_USER=' "$VA/.env" | cut -d= -f2)
  PG_DB=$(grep -m1 '^POSTGRES_DB=' "$VA/.env" | cut -d= -f2)
  como_usuario mkdir -p "$VA/backups" "$VA/data"
  # Solo Postgres primero: si la API arrancara antes, sus migraciones crearían
  # las tablas y el pg_restore chocaría con ellas.
  ( cd "$VA" && como_usuario docker compose up -d --quiet-pull postgres 2>&1 | sed 's/^/     /' )
  esperar "postgres healthy" 120 compose_healthy server-postgres-1
  TABLAS=$(docker exec server-postgres-1 psql -tAq -U "$PG_USER" -d "$PG_DB" -c "select count(*) from information_schema.tables where table_schema='public'")
  if [ "${TABLAS:-0}" -gt 0 ]; then
    ok "la base $PG_DB ya tiene $TABLAS tablas; no se restaura encima"
  else
    descargar_y_descifrar "$REMOTE_VAULT" vault_ "$TRABAJO/vault.dump"
    docker cp "$TRABAJO/vault.dump" server-postgres-1:/tmp/vault.dump
    ESPERADAS=$(docker exec server-postgres-1 pg_restore --list /tmp/vault.dump | grep -c 'TABLE DATA')
    docker exec server-postgres-1 pg_restore -U "$PG_USER" -d "$PG_DB" --no-owner /tmp/vault.dump
    docker exec server-postgres-1 rm -f /tmp/vault.dump
    TABLAS=$(docker exec server-postgres-1 psql -tAq -U "$PG_USER" -d "$PG_DB" -c "select count(*) from information_schema.tables where table_schema='public'")
    ok "pg_restore: $TABLAS tablas ($ESPERADAS con datos en el volcado)"
  fi
  ( cd "$VA" && como_usuario docker compose up -d --build 2>&1 | tail -3 | sed 's/^/     /' )
  esperar "API de Vault App healthy" 180 compose_healthy server-api-1
fi

# ═════════════════════════════════════════════════════════════════════════
if toca_fase 9; then fase 9 "Combina (base armario en el Postgres compartido + API)"
  CB="$HOME_USR/Combina"
  [ -f "$CB/.env" ] || fallo "falta $CB/.env"
  VA="$HOME_USR/vault_app/server"
  PG_SUPER=$(grep -m1 '^POSTGRES_USER=' "$VA/.env" | cut -d= -f2)
  # postgres://usuario:contraseña@host:puerto/base
  URL=$(grep -m1 '^DATABASE_URL=' "$CB/.env" | cut -d= -f2-)
  ARM_USER=$(echo "$URL" | sed -E 's#^[a-z]+://([^:]+):.*#\1#')
  ARM_PASS=$(echo "$URL" | sed -E 's#^[a-z]+://[^:]+:([^@]+)@.*#\1#')
  ARM_DB=$(echo "$URL" | sed -E 's#.*/([^/?]+)(\?.*)?$#\1#')
  compose_healthy server-postgres-1 || fallo "server-postgres-1 no está healthy: ejecutar la fase 8"
  docker exec server-postgres-1 psql -tAq -U "$PG_SUPER" -d postgres -c "select 1 from pg_roles where rolname='$ARM_USER'" | grep -q 1 \
    || docker exec server-postgres-1 psql -q -U "$PG_SUPER" -d postgres -c "CREATE ROLE \"$ARM_USER\" LOGIN PASSWORD '$ARM_PASS';"
  docker exec server-postgres-1 psql -tAq -U "$PG_SUPER" -d postgres -c "select 1 from pg_database where datname='$ARM_DB'" | grep -q 1 \
    || docker exec server-postgres-1 psql -q -U "$PG_SUPER" -d postgres -c "CREATE DATABASE \"$ARM_DB\" OWNER \"$ARM_USER\";"
  ok "rol $ARM_USER y base $ARM_DB"
  TABLAS=$(docker exec server-postgres-1 psql -tAq -U "$ARM_USER" -d "$ARM_DB" -c "select count(*) from information_schema.tables where table_schema='public'")
  como_usuario mkdir -p "$CB/data/prendas" "$CB/logs"
  if [ "${TABLAS:-0}" -gt 0 ]; then
    ok "la base $ARM_DB ya tiene $TABLAS tablas; no se restaura encima"
  else
    descargar_y_descifrar "$REMOTE_ARM" armario_ "$TRABAJO/armario.tar.gz"
    mkdir -p "$TRABAJO/armario" && tar -xzf "$TRABAJO/armario.tar.gz" -C "$TRABAJO/armario"
    DUMP=$(find "$TRABAJO/armario" -name '*.dump' | head -1)
    [ -n "$DUMP" ] || fallo "la copia de Combina no trae ningún .dump"
    docker cp "$DUMP" server-postgres-1:/tmp/armario.dump
    docker exec server-postgres-1 pg_restore -U "$ARM_USER" -d "$ARM_DB" --no-owner /tmp/armario.dump
    docker exec server-postgres-1 rm -f /tmp/armario.dump
    if [ -d "$TRABAJO/armario/data/prendas" ]; then
      cp -a "$TRABAJO/armario/data/prendas/." "$CB/data/prendas/"
      chown -R "$USUARIO:$USUARIO" "$CB/data"
    fi
    ok "pg_restore de $ARM_DB, $(find "$CB/data/prendas" -type f | wc -l) fotos"
  fi
  ( cd "$CB" && como_usuario docker compose up -d --build 2>&1 | tail -3 | sed 's/^/     /' )
  esperar "API de Combina healthy" 180 compose_healthy combina-api
  N=$(docker exec server-postgres-1 psql -tAq -U "$ARM_USER" -d "$ARM_DB" -c "select count(*) from prendas" 2>/dev/null || echo '?')
  ok "prendas en la base: $N"
fi

# ═════════════════════════════════════════════════════════════════════════
if toca_fase 10; then fase 10 "openGym"
  OG="$HOME_USR/opengym"
  [ -f "$OG/.env" ] || fallo "falta $OG/.env"
  if [ -f "$OG/data/db.json" ]; then
    ok "data/ ya existe; no se pisa"
  else
    descargar_y_descifrar "$REMOTE_OG" opengym_ "$TRABAJO/og.tar.gz"
    mkdir -p "$TRABAJO/og" && tar -xzf "$TRABAJO/og.tar.gz" -C "$TRABAJO/og"
    install -d -m 755 "$OG/data"
    cp -a "$TRABAJO/og/data/." "$OG/data/"       # root y 0600, como los escribe el contenedor
    ok "data/ restaurado ($(jq '.users | length' "$OG/data/db.json") perfiles)"
  fi
  como_usuario mkdir -p "$OG/media/img" "$OG/media/gif"
  MD5_ANTES=$(md5sum "$OG/data/secret" 2>/dev/null | awk '{print $1}')
  ( cd "$OG" && docker compose up -d --quiet-pull 2>&1 | sed 's/^/     /' )
  # No se espera al healthcheck de la imagen: su intervalo es de 5 minutos y
  # la primera sonda tarda eso en llegar. Se pregunta a la API directamente.
  WEB_PORT=$(grep -m1 '^WEB_PORT=' "$OG/.env" | cut -d= -f2)
  esperar "API de openGym responde" 120 sh -c "curl -sf http://127.0.0.1:${WEB_PORT:-8081}/api/health | grep -q '\"ok\":true'"
  MD5_DESPUES=$(md5sum "$OG/data/secret" 2>/dev/null | awk '{print $1}')
  [ "$MD5_ANTES" = "$MD5_DESPUES" ] && ok "data/secret intacto (las sesiones siguen valiendo)" || fallo "data/secret cambió al arrancar: no se restauró"
  RP=$(grep -m1 '^RP_ID=' "$OG/.env" | cut -d= -f2)
  if [ $ENSAYO = 0 ]; then
    [ "$RP" = "$(tailscale status --json | jq -r .Self.DNSName | sed 's/\.$//')" ] && ok "RP_ID=$RP coincide con el nodo" || log "[WARN] RP_ID=$RP no coincide con el nombre del nodo: las passkeys no valdrán"
  fi
  echo "     media/ se descarga sola en segundo plano (~140 MB): docker logs -f opengym-media"
fi

# ═════════════════════════════════════════════════════════════════════════
if toca_fase 11; then fase 11 "Bot y cron"
  if [ $ENSAYO = 1 ]; then
    ok "ensayo: ni bot (dos bots con el mismo token se pisan) ni cron (subiría copias duplicadas a Drive)"
  else
    ln -sfn "$HOME_USR/homelab/systemd/server-bot.service" /etc/systemd/system/server-bot.service
    systemctl daemon-reload
    systemctl enable --now server-bot >/dev/null
    sleep 5
    systemctl is-active --quiet server-bot && ok "server-bot activo (mira Telegram)" || log "[WARN] server-bot no está activo: journalctl -u server-bot"
    if [ -f "$SIS/cron/root.txt" ] && ! grep -q 'no disponible' "$SIS/cron/root.txt"; then
      crontab "$SIS/cron/root.txt"
    fi
    grep -q backup-sistema.sh <(crontab -l 2>/dev/null) || \
      (crontab -l 2>/dev/null; echo "0 6 * * * $HOME_USR/homelab/scripts/backup-sistema.sh >> /var/log/backup-sistema.log 2>&1") | crontab -
    ok "cron de root: $(crontab -l | grep -c -v '^\s*#\|^\s*$') líneas"
    if [ -f "$SIS/cron/server.txt" ] && ! grep -q 'no disponible' "$SIS/cron/server.txt"; then
      crontab -u "$USUARIO" "$SIS/cron/server.txt"
      ok "cron de $USUARIO: $(crontab -u "$USUARIO" -l | grep -c -v '^\s*#\|^\s*$') líneas"
    fi
  fi
fi

# ═════════════════════════════════════════════════════════════════════════
if toca_fase 12; then fase 12 "Verificación"
  echo "   Contenedores:"
  docker ps -a --format '     {{.Names}}\t{{.Status}}' | sort
  # "starting" no es fallo: el healthcheck de openGym sondea cada 5 minutos.
  NO_SANOS=$(docker ps --format '{{.Names}} {{.Status}}' | grep -v -E 'healthy|starting|adguardhome' || true)
  [ -z "$NO_SANOS" ] && ok "todos los contenedores healthy (o arrancando)" || log "[WARN] sin healthy: $NO_SANOS"
  if [ $ENSAYO = 0 ] || [ $CON_TAILSCALE = 1 ]; then
    HOST_TS=$(tailscale status --json | jq -r .Self.DNSName | sed 's/\.$//')
    for p in 443 8443 8444 8445; do
      C=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://$HOST_TS:$p/" || echo 000)
      echo "     https://$HOST_TS:$p → HTTP $C"
    done
  fi
  if [ $CON_BACKUPS = 1 ] && [ $ENSAYO = 0 ]; then
    echo "   Lanzando las cinco copias a mano:"
    for s in "$HOME_USR/vaultwarden/backup_vaultwarden.sh" "$HOME_USR/opengym/backup-opengym.sh" "$HOME_USR/homelab/scripts/backup-sistema.sh"; do
      bash "$s" 2>&1 | tail -1 | sed 's/^/     /'
    done
    for s in "$HOME_USR/vault_app/server/scripts/backup-to-drive.sh" "$HOME_USR/Combina/server/scripts/backup-combina.sh"; do
      como_usuario bash "$s" 2>&1 | tail -1 | sed 's/^/     /'
    done
  fi
  rm -rf "$TRABAJO"
  ok "directorio de trabajo $TRABAJO borrado (llevaba los secretos descifrados)"
  cat <<FIN

   Queda fuera del servidor (docs/recuperacion.md §"Fuera del servidor"):
     1. Router: reserva DHCP de 192.168.1.50 para la MAC nueva; DNS de la LAN → 192.168.1.50.
     2. Consola de Tailscale, SOLO si el nodo salió con otra IP: nameserver global,
        exit node aprobado, nodo viejo borrado.
     3. Clientes: Bitwarden, openGym (passkeys) y el APK de Combina siguen si el
        nombre MagicDNS es el mismo. Si no, re-registrar passkeys y recompilar.
     4. Si no se restauraron las ssh_host_*: borrar la entrada vieja de known_hosts.

   Log completo: $LOG
FIN
fi

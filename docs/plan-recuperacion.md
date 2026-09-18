# Plan: copia y restauración del servidor entero

> **Ejecutado el 18 de septiembre de 2026.** Se conserva como registro del
> inventario y del razonamiento. Lo vigente es [recuperacion.md](recuperacion.md)
> (runbook), `scripts/backup-sistema.sh`, `scripts/restaurar-servidor.sh`,
> `scripts/kit-usb.sh` y la [decisión §14](decisiones.md#14-copia-del-sistema-reproducible-en-vez-de-imagen-de-disco).

Plan para que lo ejecute un agente. Escrito el 18 de septiembre de 2026
tras inventariar el servidor. Objetivo: que si mañana muere el disco (o
la máquina entera) se pueda dejar **todo igual que está ahora** en una
Ubuntu recién instalada, en menos de una hora, con un script y un kit de
recuperación que quepa en un bolsillo.

Convenciones de este documento: `<tailnet>` e `<IP_TAILSCALE>` son
marcadores (el repo es público); el agente los saca de `tailscale status`.
El usuario del sistema es `server`, el home `/home/server`, la IP de LAN
`192.168.1.50`, la pasarela `192.168.1.1`.

---

## 0. Resumen para el humano

Hoy hay copia de los **datos** de los cuatro servicios (Vaultwarden, Vault
App, openGym, Combina) y de nada más. Si muere el disco, los datos vuelven
pero hay que reconstruir a mano el sistema: paquetes, IP fija, DNS del
host, Docker, Tailscale con su identidad y sus `serve`, la configuración de
AdGuard, los `.env` con los secretos, los cuatro cron, el bot… Y hay al
menos tres cosas que hoy **no están en ningún sitio** salvo en este disco.

La estrategia no es una imagen de disco sino **reproducibilidad**: el
servidor es Ubuntu + una docena de ficheros de `/etc` + tres repos de
GitHub + un puñado de secretos + las copias de datos que ya existen. Todo
lo que no se puede regenerar (secretos, identidad de Tailscale, config de
AdGuard, cron, `.env`) cabe en un tar de ~200 KB que se cifra y sube a
Drive cada noche, y un único script lo vuelve a montar todo en orden.

Cuatro entregables:

1. `scripts/backup-sistema.sh` — la quinta copia nocturna: todo lo que no
   es dato de servicio ni se regenera.
2. `scripts/restaurar-servidor.sh` — de Ubuntu limpia a servidor completo,
   por fases, idempotente, con un modo `--ensayo` para probarlo en una VM
   sin tocar producción.
3. El **kit de recuperación** fuera del servidor: la passphrase en papel y
   un USB con lo mínimo para arrancar el proceso. Sin esto, lo demás es
   inútil: la passphrase y el acceso a Drive son lo único que no se puede
   respaldar con lo que protegen.
4. Docs (`docs/recuperacion.md`, `backups.md`, `decisiones.md`), bot
   (vigilancia de la edad de las cinco copias) y un **ensayo real** en una
   VM, porque una restauración que no se ha ejecutado nunca es una
   hipótesis.

**Así tiene que verse una restauración desde fuera** — es el criterio de
diseño de todo lo demás, y si el resultado exige más que esto, está mal:

```
1. Instalar Ubuntu 26.04 (usuario `server`, hostname `server`, cable de red).
2. git clone https://github.com/SaguadoDev/homelab && sudo bash homelab/scripts/restaurar-servidor.sh
3. Cuando lo pida: la passphrase (papel), el USB con rclone.conf (o login de
   Google en el navegador) y el token de GitHub. Nada más se teclea: los
   .env, los composes, el cron, AdGuard y la identidad de Tailscale vienen
   del tar del sistema.
4. Si cambió la máquina: reserva DHCP en el router para la MAC nueva. Fin.
```

Hay un límite práctico: las sesiones de Claude Code no tienen TTY y `sudo`
no puede pedir contraseña. El agente escribe los scripts; los pasos con
root los lanza el humano desde una terminal (SSH), como se hizo con el DNS
del tailnet. Ver §6.

---

## 1. Inventario: qué hay en el servidor y dónde está cubierto

Hecho con `find /etc -newermt`, `apt-mark showmanual`, `docker inspect`,
`crontab -l`, `tailscale status --json` y leyendo los repos. Legible sin
root; lo que exige root está marcado.

### 1.1 Cubierto hoy (copia nocturna cifrada en Drive)

| Qué | Dónde vive | Copia |
|---|---|---|
| Bóveda Vaultwarden | `~/vaultwarden/vw-data` | `Vaultwarden_Backups`, 03:00, cron **root** |
| Base Vault App (Postgres) | volumen `server_vault-pgdata` | `Vault_Backups`, 04:30, cron `server` |
| openGym (`data/` + compose + `.env`) | `~/opengym` | `openGym_Backups`, 05:00, cron **root** |
| Combina (base `armario` + fotos + compose + `.env`) | `~/Combina` | `Armario_Backups`, 05:30, cron `server` |

Las cuatro llegaron esta noche (comprobado con `rclone lsl`).

### 1.2 Regenerable desde un repo (con matices)

| Qué | Fuente | Matiz |
|---|---|---|
| Composes, scripts de backup, unidad del bot, código del bot | `github.com/SaguadoDev/homelab` (público) | El repo está **saneado**: `/home/homelab` en vez de `/home/server`, `<host>.<tailnet>` en vez del nombre real, sin `ADMIN_TOKEN` ni SMTP en el compose de Vaultwarden. Las copias vivas son distintas: `diff` confirma que **solo** difieren en eso. Para restaurar hay que usar las copias vivas (van en el tar del sistema) o des-sanear. |
| Vault App (API + Dockerfile) | `github.com/SaguadoDev/vault_app` (**privado**) | `server/scripts/backup-to-drive.sh` está **sin trackear** en ese repo: solo existe en este disco (y saneado en homelab). |
| Combina (API + Dockerfile + su script de backup) | `github.com/SaguadoDev/Combina` (**privado**) | El directorio de despliegue ES el clon. |
| Imágenes Docker | Registros públicos | `opengym` fijado a `1.2.11`; `adguard`, `vaultwarden`, `postgres:16-alpine` por tag flotante. `server-api` y `combina-api` se construyen en local desde los repos. |
| `~/bot` | `homelab/bot` | Idéntico al repo (`diff` limpio) + `.env` + `venv`. |
| `~/opengym/media` (137 MB) | El contenedor `opengym-media` lo vuelve a bajar | Documentado en backups.md. |

Los dos repos privados exigen credencial para clonar: no hay `gh`, ni
`~/.git-credentials`, ni claves SSH en el servidor. Hoy se hace a mano.

### 1.3 NO cubierto: solo existe en este disco

| Qué | Ruta | Root | Por qué importa |
|---|---|---|---|
| Passphrase de las copias | `~/.config/vault/backup-passphrase` | no | Sin ella, todo lo de Drive es ruido. **No puede ir en ninguna copia cifrada con ella misma.** Kit en papel. |
| Remoto de Drive | `~/.config/rclone/rclone.conf` (token OAuth) | no | Sin él no se baja nada. Se puede rehacer con `rclone config` + cuenta de Google en un navegador, pero conviene tenerlo en el USB. |
| Identidad de Tailscale | `/var/lib/tailscale/tailscaled.state` (+ `certs/`) | **sí** | Clave del nodo, `<IP_TAILSCALE>`, nombre `server`, los cuatro `serve`, exit node, certificados. Restaurando este fichero el nodo vuelve **con la misma IP y nombre**, sin reautenticar y sin tocar la consola. Sin él: nodo nuevo, IP nueva, hay que borrar el viejo en la consola para heredar el nombre `server`, volver a aprobar el exit node y **cambiar el nameserver global del tailnet** (apunta a `<IP_TAILSCALE>` desde el 12/09). |
| Configuración de AdGuard | `/path/to/your/conf/AdGuardHome.yaml` | **sí** | Hash de la contraseña admin, upstreams DoH, `bind_hosts` con las dos IPs, split DNS `[/ts.net/]`, listas, clientes con nombre, reescrituras. backups.md dice "se rehace en minutos"; ya no es verdad y son 10 KB. |
| Cron de root | `crontab -l` de root | **sí** | Vaultwarden 03:00 y openGym 05:00. backups.md lo documenta con `/var/log/backup-vw.log`, que **no existe**: el cron real difiere de la doc. Hay que capturar el real. |
| Cron de `server` | `crontab -l` | no | Vault App 04:30 y Combina 05:30. |
| Secretos de servicios | `~/vault_app/server/.env` (Postgres, `VAULT_API_TOKEN`), `~/opengym/.env` (`RP_ID`, `ORIGIN`), `~/Combina/.env` (Postgres, `JWT_SECRETO`, `GEMINI_API_KEY`), `~/bot/.env` (token y chat de Telegram), `~/vaultwarden/docker-compose.yml` (`ADMIN_TOKEN`, contraseña SMTP) | no | openGym y Combina ya van dentro de su copia; los demás no van en ninguna. |
| Red del host | `/etc/netplan/00-installer-config.yaml` (IP fija `192.168.1.50/24`, renderer NetworkManager, DNS `1.1.1.1,1.0.0.1`) | **sí** | Sin IP fija la casa se queda sin DNS aunque AdGuard esté vivo. |
| DNS del host | `/etc/systemd/resolved.conf` (`DNS=1.1.1.1 8.8.8.8`), `/etc/docker/daemon.json` (`{"dns": [...]}`) | sí | Decisión §2 e incidencia 9. |
| Exit node | `/etc/sysctl.d/99-tailscale.conf` (`ip_forward`) | sí | Sin esto el exit node no enruta. |
| Docker tras tailscaled | `/etc/systemd/system/docker.service.d/after-tailscaled.conf` → symlink al repo | sí | Decisión §13. |
| Bot | `/etc/systemd/system/server-bot.service` → symlink al repo | sí | |
| Escritorio | `/etc/gdm3/custom.conf` (autologin `server`, sin Wayland) | sí | Es Ubuntu **Desktop**, no Server. |
| Identidad SSH del host | `/etc/ssh/ssh_host_*` | sí | Opcional: evita el aviso "host key changed" en los clientes. |
| Vault App: exportaciones cifradas | `~/vault_app/server/data/*.enc.json` (300 KB) | no | Fuera del pg_dump. |
| Memoria de Claude Code | `~/.claude/projects/*/memory/`, `~/.claude/settings.json` | no | Pequeño y valioso para seguir trabajando con contexto. |
| Repos de apt | `docker.list`, `tailscale.list`, `brave-browser-release.sources` + keyrings | sí | Se regeneran en el script; no hace falta copiarlos. |

### 1.4 Paquetes instalados a mano (fuera de la base de Ubuntu Desktop)

`docker-ce docker-ce-cli containerd.io docker-buildx-plugin
docker-compose-plugin docker-ce-rootless-extras docker-model-plugin
tailscale rclone python3.14-venv sqlite3 npm fastfetch brave-browser cockpit
pcp`. Snaps: solo los de Ubuntu Desktop + `firefox`.

`bind9-dnsutils` (`dig`), `gnupg`, `lm-sensors`, `chrony`, `openssh-server`
y `ufw` (deshabilitado) ya vienen o son dependencias. El bot solo necesita
`psutil`, `python-telegram-bot` y `python-dotenv` en su `venv`.

### 1.5 Fuera del servidor (nadie lo respalda)

- **Router**: reserva DHCP de `192.168.1.50` para la MAC del servidor y DNS
  de la LAN apuntando a esa IP. Si muere la placa, la MAC cambia y hay que
  rehacer la reserva.
- **Consola de Tailscale**: nameserver global `<IP_TAILSCALE>` con
  *Override local DNS*, aprobación del exit node, ACLs, expiración de clave
  deshabilitada (`KeyExpiry: null`, comprobado).
- **Cuenta de Google**: Drive con las copias, y el login de Tailscale.
- **GitHub**: los tres repos y la credencial para los dos privados.
- **Claves privadas de las passkeys**: en el móvil. Ya está documentado que
  ninguna copia las cubre.

### 1.6 Hallazgos colaterales (decidir, no bloquean)

1. **AdGuard vive en `/path/to/your/{conf,work}`.** Es la ruta de ejemplo
   de un tutorial, copiada literal. `~/adguard/confdir` y `~/adguard/workdir`
   son restos del 5 de agosto sin uso, y el compose del repo dice `./conf`
   y `./work`. **Decidido: normalizar ya** a `~/adguard/conf` y
   `~/adguard/work`, corregir el compose vivo y borrar los restos (dos
   segundos sin DNS; paso 3 de §4). Aun así, el script de copia lee la ruta
   real con `docker inspect`, no la asume.
2. **Cockpit escucha en `*:9090` hacia toda la LAN** (`ss -ltn`), con `pcp`
   detrás. **Decidido por el usuario: se queda** — lo usa desde el PC y el
   móvil. Es una excepción consciente a "nada en la LAN"; se anota como tal
   en `decisiones.md` y el script de restauración instala `cockpit` y `pcp`
   por defecto, no como extra.
3. Restos inofensivos: `/etc/systemd/resolved.conf.d/adguard.conf.bak`,
   `/etc/netplan/*.bak`, `~/adguard/get-docker.sh`, `~/bot/*.bak-*`,
   `~/vaultwarden`/`~/adguard` `*.bak-2026-09-07`. No se copian.
4. Los cuatro scripts de backup del repo **no son ejecutables tal cual**
   (rutas `/home/homelab`). Mientras no se refactoricen a rutas relativas
   (`$(dirname "$0")`, `$HOME`), la fuente de verdad son las copias vivas.
5. `Combina/data/prendas` está vacío y el log dice `Prendas vivas en la
   base: 0`. Confirmado por el usuario: es esperado, todavía no hay datos.
   La restauración debe funcionar igual con la base vacía que con fotos.
6. No hay claves SSH autorizadas: el acceso es por contraseña. Sin efecto
   en el plan; anotado.

---

## 2. Estrategia: reproducible, no imagen de disco

**Descartado: imagen de disco** (Clonezilla, `dd`, Timeshift). Necesita un
segundo disco enchufado, envejece desde el día que se hace, arrastra 24 GB
de los que el 95 % se regenera, y si muere la máquina y no solo el disco,
la imagen de un m715q no arranca igual en otro hardware.

**Elegido: capas.**

```
Ubuntu 26.04 limpia
  + paquetes (lista fija en el script)
  + /etc (12 ficheros, del tar del sistema)
  + repos (homelab público; vault_app y Combina con token)
  + secretos e identidad (tar del sistema, cifrado, en Drive)
  + datos (las cuatro copias que ya existen)
  = el servidor de hoy
```

Cada capa tiene una fuente distinta y ninguna depende del disco que ha
muerto. El tar del sistema es la única pieza nueva. Todo lo demás son
las copias y los repos que ya hay, más un script que sabe el orden.

**El nudo que no se puede desatar con software:** para bajar el tar del
sistema hace falta `rclone.conf`; para descifrarlo, la passphrase. Ninguna
de las dos puede estar solo dentro de lo que protege. De ahí el kit físico
(§3.3). El móvil con la app de Bitwarden tiene una copia **offline** de la
bóveda y ahí debería estar ya la passphrase (backups.md lo pedía) — el
agente debe pedir al usuario que lo **compruebe**, no asumirlo.

---

## 3. Entregables

### 3.1 `scripts/backup-sistema.sh`

Mismo molde que los otros cuatro (leerlos antes): `set -euo pipefail`,
directorio de preparación temporal, tar → `gpg --symmetric --cipher-algo
AES256 --batch --passphrase-file`, comprobación de **tamaño mínimo antes de
rotar**, `rclone copy` a `gdrive:Sistema_Backups/`, retención 7, log con
fecha, y el bloque de comentario con el procedimiento de restauración.
Corre en el **cron de root** (lee `tailscaled.state`, la config de AdGuard
y el cron de root), a las **06:00**, después de las otras cuatro.

Entra (rutas reales, no las del repo):

```
etc/netplan/00-installer-config.yaml
etc/systemd/resolved.conf
etc/docker/daemon.json
etc/sysctl.d/99-tailscale.conf
etc/default/tailscaled
etc/gdm3/custom.conf
etc/hosts  etc/hostname
etc/ssh/ssh_host_*                       (identidad SSH del host)
var/lib/tailscale/tailscaled.state       (identidad, serve, prefs)
var/lib/tailscale/certs/                 (si existe)
adguard/AdGuardHome.yaml                 ← origen: docker inspect adguardhome (mount /opt/adguardhome/conf)
adguard/docker-compose.yml               ← ~/adguard/docker-compose.yml
cron/root.txt        ← crontab -l
cron/server.txt      ← crontab -u server -l
home/vaultwarden/docker-compose.yml  home/vaultwarden/backup_vaultwarden.sh
home/opengym/docker-compose.yml  home/opengym/.env  home/opengym/backup-opengym.sh
home/vault_app/server/.env  home/vault_app/server/docker-compose.yml
home/vault_app/server/scripts/backup-to-drive.sh  home/vault_app/server/data/
home/Combina/.env  home/Combina/docker-compose.yml
home/bot/.env
home/.config/rclone/rclone.conf
home/.gitconfig  home/.bashrc  home/.ssh/authorized_keys
home/.claude/settings.json  home/.claude/projects/*/memory/
manifiesto/apt-manual.txt      ← apt-mark showmanual
manifiesto/snaps.txt           ← snap list
manifiesto/docker-images.txt   ← docker images --digests  (qué "latest" corría)
manifiesto/tailscale-status.json, tailscale-serve.json, tailscale-prefs.json
manifiesto/ip-addr.txt  os-release  uname.txt
manifiesto/SHA256SUMS
```

**No entra, y es a propósito:** `backup-passphrase` (ver §2), datos de
servicios (tienen su copia), `venv`, `node_modules`, imágenes Docker,
`opengym/media`, `vault_app/server/backups` (los pg_dump locales), logs,
`.bak`. El tar debe rondar los 100–300 KB; tamaño mínimo para rotar: 20 KB.

Permisos: el tar se crea como root en un tmp `0700` y se borra al acabar,
como hacen los otros. El fichero cifrado resultante se sube y se elimina
del disco.

### 3.2 `scripts/restaurar-servidor.sh`

De Ubuntu 26.04 recién instalada (Desktop, como ahora, o Server: el script
no debe depender de que haya escritorio) con usuario `server` y hostname
`server`, a servidor completo. Se ejecuta con `sudo` desde una terminal.
**Idempotente**: cada fase comprueba el estado antes de actuar y se puede
relanzar. `--fase N` para ejecutar una sola; `--ensayo` para la VM (§3.5).

Entradas que pide al principio (y no vuelve a pedir):

- passphrase de las copias (del kit en papel) → `~/.config/vault/backup-passphrase`, `0600`
- `rclone.conf` (ruta al fichero del USB) o, si no lo hay, lanza `rclone config` y espera
- token de GitHub para `vault_app` y `Combina` (o clave SSH del USB)
- si se restaura la identidad de Tailscale (por defecto sí; en `--ensayo` nunca)

Fases, en este orden y no en otro:

| # | Fase | Qué hace | Aceptación |
|---|---|---|---|
| 1 | Paquetes | Repos apt de Docker y Tailscale + keyrings; `apt install` de la lista fija de §1.4, `cockpit` y `pcp` incluidos (`brave`, `npm`, `fastfetch` solo con `--extras`); `usermod -aG docker server` | `docker version`, `tailscale version`, `rclone version` responden; `cockpit.socket` activo |
| 2 | Tar del sistema | Coloca passphrase y `rclone.conf`; `rclone copy` del `sistema_*.tar.gz.gpg` más reciente; descifra a un tmp `0700`; verifica `SHA256SUMS` | tmp con el manifiesto y sumas correctas |
| 3 | `/etc` | Copia los ficheros de `etc/` del tar; `netplan apply`; `systemctl restart systemd-resolved`; `sysctl --system`; `/etc/resolv.conf` → `stub-resolv.conf` (incidencia 9) | `ip -4 addr` muestra `192.168.1.50`; `resolvectl status` da `1.1.1.1`; `resolv.conf` apunta a `127.0.0.53` |
| 4 | Repos y home | `git clone` de homelab en `~/homelab`; `vault_app` en `~/vault_app`; `Combina` en `~/Combina`; `~/bot` = copia de `homelab/bot` + `venv` + `pip install -r`; crea `~/vaultwarden ~/adguard ~/opengym`; vuelca del tar los composes, `.env`, scripts de backup, `data/` de Vault App, dotfiles y memoria de Claude; `chmod 600` a los `.env`; propietario `server` en todo lo del home | los seis directorios existen, `diff` entre composes del tar y del disco vacío |
| 5 | Tailscale | Si restaura identidad: `systemctl stop tailscaled`, copia `tailscaled.state` (+ `certs/`) a `/var/lib/tailscale`, `0600 root`, `systemctl start tailscaled`, `tailscale up` (los prefs vienen en el state). Si no: `tailscale up --advertise-exit-node --accept-dns` y el humano autentica en el navegador. Después, `tailscale serve reset` y los cuatro `serve` de `tailscale/README.md` (o `tailscale serve set-raw < serve-config.json` des-saneado) | `tailscale status` muestra `server` con `<IP_TAILSCALE>`; `tailscale serve status` lista 443/8443/8444/8445 |
| 6 | AdGuard | `~/adguard/conf/AdGuardHome.yaml` del tar (ruta normalizada, ver §1.6.1), compose corregido a `./conf` y `./work`; symlink del drop-in `docker.service.d/after-tailscaled.conf` + `daemon-reload`; `docker compose up -d` | `dig @192.168.1.50 doubleclick.net` → `0.0.0.0`; `dig @<IP_TAILSCALE> ejemplo.com` responde; `dig @192.168.1.50 server.<tailnet>.ts.net` → `<IP_TAILSCALE>` |
| 7 | Vaultwarden | Baja la última `vaultwarden_*.tar.gz.gpg`, descifra, extrae a `~/vaultwarden/vw-data` (el compose vivo ya está del tar del sistema; el que viene dentro de la copia se descarta si coincide); `docker compose up -d` | `curl 127.0.0.1:8080/alive` → 200; `prelogin` devuelve KDF; `md5sum rsa_key.pem` igual al de la copia |
| 8 | Vault App | `docker compose up -d --build` en `~/vault_app/server` (construye `server-api`, levanta Postgres); espera `healthy`; baja `vault_*.dump.gpg`, descifra, `pg_restore -U vault -d vault --clean` como en backups.md | `pg_restore --list` cuenta las mismas `TABLE DATA` que el volcado; `curl 127.0.0.1:3000` responde |
| 9 | Combina | `docker compose up -d --build` en `~/Combina`; baja `armario_*.tar.gz.gpg`; `CREATE DATABASE armario OWNER armario_user` (el rol lo crea la migración o hay que crearlo con la contraseña del `.env`: **comprobar en el repo de Combina cuál de las dos**); `pg_restore`; fotos a `data/prendas/` | `limpiar-huerfanas.js` en seco → 0; API en 3001 responde |
| 10 | openGym | compose + `.env` del tar (o de la copia, son los mismos); baja `opengym_*.tar.gz.gpg`; extrae `data/`; `docker compose up -d` (`opengym-media` rehace `media/` solo; **tarda**: ~140 MB de GitLab) | `/api/health` ok; `jq '.users\|length' data/db.json` cuadra; `data/secret` no cambia tras arrancar; `RP_ID` del `.env` = `server.<tailnet>.ts.net` |
| 11 | Bot y cron | `ln -sfn ~/homelab/systemd/server-bot.service /etc/systemd/system/`; `enable --now`; `crontab cron/root.txt` como root; `crontab -u server cron/server.txt`; añade la línea de `backup-sistema.sh` si falta | mensaje de arranque del bot en Telegram; `crontab -l` de ambos con las 5 líneas |
| 12 | Verificación final | `docker ps` todos `healthy`; los cuatro `curl -sk https://server.<tailnet>.ts.net[:puerto]` desde otro nodo del tailnet; lanza **a mano** los cinco scripts de backup y comprueba que suben; imprime la lista de §6.3 (lo que queda fuera del servidor) | informe en pantalla y en `~/restauracion-<fecha>.log` |

Detalles que el agente no debe olvidar al escribirlo:

- Orden AdGuard → Vaultwarden → Vault App → Combina → openGym → bot. AdGuard
  primero porque la casa está sin DNS mientras tanto; Combina después de
  Vault App porque comparte Postgres.
- Postgres compartido: Combina no levanta su propia base, usa
  `server-postgres-1` por la red `RED_DOCKER` del `.env`. Las redes de
  compose se recrean solas, pero el nombre de red tiene que coincidir.
- Los `.env` de openGym llevan `RP_ID`/`ORIGIN` y `~/Combina` tiene la URL
  compilada en el APK: si el nombre MagicDNS cambia (identidad nueva sin
  borrar el nodo viejo → `server-1`), **nada de esto vale**. Por eso la fase
  5 va antes que cualquier servicio y aborta si el nombre no es `server`.
- `docker compose up` de Vault App y Combina son `--build`: necesitan los
  repos clonados con todo, no solo el compose.
- `chmod`/`chown`: `opengym/data` y `vw-data` los escribe root dentro del
  contenedor; no forzar propietario `server` ahí.
- Nunca `0.0.0.0` en `bind_hosts` ni en `ports:` (decisiones §4 y §2).

### 3.3 Kit de recuperación (fuera del servidor)

Lo que hace falta **antes** de poder ejecutar nada. Sin kit no hay plan.

**En papel, en un cajón:**

- La passphrase de las copias (`cat ~/.config/vault/backup-passphrase`,
  48 caracteres). Es la única pieza que no admite copia digital dentro del
  sistema.
- Qué cuenta de Google tiene el Drive y el login de Tailscale.
- Una línea: "Procedimiento en `github.com/SaguadoDev/homelab`,
  `docs/recuperacion.md`".

**En un USB (o dos), cifrado o no según lo que el usuario acepte:**

- `rclone.conf` (`~/.config/rclone/rclone.conf`). Lleva el *refresh token*
  y, además, un `client_id`/`client_secret` **propios** con
  `scope = drive.file`. Ese scope solo ve los ficheros subidos por ese
  mismo cliente OAuth: rehacer el remoto con el cliente por defecto de
  rclone deja las copias invisibles aunque el login sea correcto. Si se
  pierde el fichero, `rclone config` con **el mismo** `client_id` y
  `client_secret` (están en el proyecto de Google Cloud del usuario, en
  Credenciales) y login en el navegador. Apuntar en el papel el nombre de
  ese proyecto.
- El último `sistema_*.tar.gz.gpg` (por si Drive no está: cuenta borrada,
  sin red…). Va cifrado, así que el USB puede ser "en claro".
- Un *fine-grained PAT* de GitHub de **solo lectura** sobre `vault_app` y
  `Combina`, o una clave SSH de despliegue. Con caducidad larga y apuntada
  la fecha.
- `git bundle` de los tres repos (opcional; GitHub es fiable, pero cuesta
  nada).
- Una copia de `restaurar-servidor.sh` suelto, por si el repo no se puede
  clonar en ese momento.

**Cadencia:** refrescar el USB cuando cambie algo del kit (token, rclone)
y como mínimo cada tres meses. Un `scripts/kit-usb.sh` que, dado el punto
de montaje, copie lo anterior y escriba `KIT-<fecha>.txt` hace que sea un
comando y no una lista mental. Opcional, pero barato.

**Comprobar, no asumir:** que la passphrase está en la bóveda de
Bitwarden y que la app del móvil la abre **sin red** (modo avión). Es la
copia offline más probable de todas.

### 3.4 Bot, docs y repo (las cuatro piezas de la convención)

- **Bot** — `comprobar_copias()` en `bot/servicios.py`: para cada una de
  las cinco carpetas de `gdrive:` (`rclone lsl`, corre como `server`, cuya
  `rclone.conf` ya sirve), edad del fichero más reciente; aviso si supera
  30 h o si el tamaño del último es menor que la mitad de la mediana de
  los últimos 7. Cierra la primera "deuda" de backups.md sin montar nada
  nuevo. Una vez al día, no en cada ciclo.
- **`docs/recuperacion.md`** — el runbook: kit, instalar Ubuntu, ejecutar el
  script fase a fase, lista de lo que hay que hacer fuera del servidor
  (§6.3), y cómo se probó (fecha del ensayo, qué falló).
- **`docs/backups.md`** — añadir la quinta columna (Sistema, 06:00, cron
  root, 7 días) y **corregir** el párrafo "No se respalda": AdGuard y
  tailscaled ahora sí; también corregir la línea del cron de root con lo
  que diga el cron real.
- **`docs/decisiones.md` §14** — "Copia del sistema: reproducible en vez de
  imagen de disco", con las alternativas descartadas y el nudo de la
  passphrase.
- **`docs/operaciones.md`** — sección "Tras un desastre" que remita a
  `recuperacion.md`, y en "Tras un corte de luz" añadir la comprobación de
  `Sistema_Backups`.
- **`README.md`** — fila en la tabla de servicios/copias, nodo
  `Sistema_Backups` en el diagrama si hay uno de copias.
- **`.gitignore`** — nada nuevo si el script no escribe en el repo. El tar
  nunca se crea dentro de `~/homelab`.
- Saneado del repo: el script y las docs usan `/home/server` como hace ya
  `systemd/server-bot.service`; los marcadores `<host>.<tailnet>` siguen
  igual. **Ningún secreto, ninguna `100.x`, ningún token.**

### 3.5 Ensayo en una VM (obligatorio antes de dar el plan por hecho)

El servidor tiene 8 núcleos, 14 GB y virtualización activa: cabe una VM de
ensayo sin apagar nada. `snap install multipass`, `multipass launch 26.04
--name ensayo --cpus 2 --memory 4G --disk 25G`, usuario `server` dentro,
copiar dentro el kit (passphrase, `rclone.conf`, token) y ejecutar
`restaurar-servidor.sh --ensayo`.

`--ensayo` cambia exactamente esto, y el script lo imprime al arrancar:

- **No** toca netplan ni la IP (la VM usa la suya por DHCP de multipass).
- **No** restaura `tailscaled.state` (dos nodos con la misma identidad
  rompen el real). Hace `tailscale up --hostname server-ensayo` o, con
  `--sin-tailscale`, salta la fase 5 entera y solo verifica puertos
  locales.
- **No** instala cron. Si los scripts de backup corrieran desde la VM
  subirían ficheros con los mismos nombres a las mismas carpetas y la
  rotación por número podría borrar copias reales.
- Reescribe `bind_hosts` de AdGuard a la IP de la VM.
- `.env` de openGym: `RP_ID`/`ORIGIN` intactos (las passkeys no se van a
  probar; la API arranca igual).

Se verifica dentro con los mismos criterios de aceptación de §3.2 (fases
6–10) y se anota en `docs/recuperacion.md`: fecha, duración, qué hubo que
retocar. Después `multipass delete --purge ensayo`. Repetir el ensayo
cuando cambie el script o se añada un servicio.

---

## 4. Pasos para el agente ejecutor, en orden

1. Leer `README.md`, `docs/*.md`, `tailscale/README.md` y los cuatro
   scripts de `scripts/`. Adoptar su estilo (español, `set -euo pipefail`,
   log con fecha, tamaño mínimo antes de rotar, bloque de restauración).
2. Reunir con el humano lo que exige root (§6.1) o pactar un `sudoers`
   temporal. Sin `cron de root`, `AdGuardHome.yaml` y `tailscaled.state`
   no se puede validar el tar.
3. Normalizar AdGuard (root, lo lanza el humano): `docker compose down`
   en `~/adguard`, mover `/path/to/your/conf` y `/path/to/your/work` a
   `~/adguard/conf` y `~/adguard/work`, compose vivo con `./conf` y
   `./work` (igual que el del repo), borrar `confdir/`, `workdir/`,
   `get-docker.sh` y los `.bak`; `up -d`; verificar con los tres `dig` de la
   fase 6. Actualizar la ficha de `servicios.md` si menciona rutas.
4. Escribir `scripts/backup-sistema.sh`. Probarlo con `--dry-run` (lista lo
   que entraría y el tamaño) y luego en real una vez, a mano. Descifrar el
   resultado en un tmp y comprobar el manifiesto y las sumas. Añadir la
   línea de cron de root (06:00) — la instala el humano.
5. Escribir `scripts/restaurar-servidor.sh` con las 12 fases y los flags.
   `bash -n` y `shellcheck` limpios. Cada fase con su comprobación de
   aceptación como código, no como comentario.
6. Bot: `comprobar_copias()`; reiniciar `server-bot` (root) y ver el aviso
   de prueba forzando un umbral de 0 h.
7. Docs: `recuperacion.md` nuevo; `backups.md`, `decisiones.md` §14,
   `operaciones.md`, `README.md`. Revisar que no se cuela ningún secreto ni
   IP del tailnet.
8. Ensayo en multipass (§3.5). Corregir el script con lo que falle. Volver
   a ensayar hasta que las fases 6–10 pasen limpias de una tirada.
9. Kit: generar el PAT de solo lectura (lo hace el humano en GitHub),
   `kit-usb.sh` opcional, y una checklist impresa. Pedir al humano que
   confirme la passphrase en Bitwarden offline.
10. Commit por pieza (script de copia; script de restauración; bot; docs),
   mensajes en español como los del repo. Sin push si el humano no lo
   pide.
11. Decisiones abiertas (§7): dejarlas escritas en `recuperacion.md` como
    "pendiente" si el humano no responde; no decidir por él.

---

## 5. Criterios de "hecho"

- Cinco ficheros nuevos en Drive cada noche, y `Sistema_Backups` con 7.
- Un tar del sistema descifrado en un tmp contiene el manifiesto, las
  sumas cuadran y no contiene `backup-passphrase`.
- El ensayo en VM levanta AdGuard, Vaultwarden, Vault App, Combina y
  openGym con datos reales de las copias, y pasa los criterios de §3.2.
- El bot avisa cuando una copia tiene más de 30 h (probado forzando).
- `docs/recuperacion.md` existe, cabe en dos pantallas la parte que hay
  que leer con el servidor muerto, y dice la fecha del último ensayo.
- El kit físico existe y el humano ha confirmado la passphrase en Bitwarden
  offline.

---

## 6. Qué necesita el agente del humano

### 6.1 Root desde una terminal con TTY

Claude Code no puede autenticar `sudo`. Como con el DNS del tailnet: el
agente deja el script en `~/…`, el humano lanza `sudo bash …` por SSH y
pega la salida. Pasos con root en este plan: leer `crontab -l` de root,
`AdGuardHome.yaml` y `tailscaled.state` para el primer tar; instalar la
línea de cron de root; reiniciar el bot; `snap install multipass`.

Alternativa que evita el ping-pong: `/etc/sudoers.d/server` con
`server ALL=(ALL) NOPASSWD: ALL`. Dado que `server` ya está en el grupo
`docker` (equivalente a root en la práctica), no rebaja la seguridad real
del sistema; sí cambia la ergonomía del riesgo (cualquier comando del agente
puede ser root sin fricción). Es decisión del humano; el plan funciona con
las dos.

### 6.2 Cosas que solo él puede hacer

- Apuntar la passphrase en papel y comprobarla en Bitwarden offline.
- Crear el PAT de GitHub de solo lectura.
- Preparar el USB (o dejar que `kit-usb.sh` lo llene).
- Autenticar Tailscale en el navegador si en algún ensayo se hace
  `tailscale up` sin identidad.
- Responder §7.

### 6.3 Lo que queda fuera del servidor en una restauración real

Va también en `recuperacion.md`, porque es lo que se olvida:

1. Router: reserva DHCP de `192.168.1.50` para la MAC nueva; DNS de la LAN
   → `192.168.1.50`.
2. Consola de Tailscale, **solo si la identidad no se pudo restaurar**:
   borrar el nodo `server` viejo antes del `tailscale up` (para heredar el
   nombre), aprobar exit node, cambiar el nameserver global a la IP nueva.
3. Clientes: Bitwarden (misma URL: nada), openGym (mismo `RP_ID`: nada),
   Combina APK (misma URL: nada). Si cambió el nombre MagicDNS: todo lo
   anterior se rehace, y las passkeys se registran de nuevo.
4. Clientes SSH: si no se restauraron las `ssh_host_*`, borrar la entrada
   vieja de `known_hosts`.

---

## 7. Decisiones

Tomadas el 18 de septiembre de 2026 con el usuario:

1. **Cockpit se queda**, en la LAN, y se reinstala por defecto. Excepción
   consciente a "nada en la LAN"; anotarla en `decisiones.md`.
2. **AdGuard se normaliza ya** a `~/adguard/{conf,work}` (§4, paso 3).
3. **Combina vacío es esperado.** Nada que hacer.
4. **Criterio de simplicidad**: la restauración son los cuatro pasos de §0.
   Todo lo que obligue a teclear un `.env`, un cron o una ruta a mano es
   un fallo del script, no un paso del procedimiento.

Con valor por defecto si el humano no dice lo contrario:

5. **Desktop** en la reinstalación, como ahora (el script sirve para
   Server también).
6. **Retención del tar del sistema: 7 días + una copia mensual** en
   `Sistema_Backups/mensual/` (200 KB al mes; cubre "un cambio malo pasó
   desapercibido más de una semana").
7. **`sudoers` sin contraseña para `server`**: no decidido. Mientras tanto,
   el procedimiento de §6.1 (script en `~/`, lo lanza el humano por SSH).
8. **Refactor de los scripts de backup** (rutas relativas, copias vivas como
   symlinks al repo, como la unidad del bot): después del ensayo, como
   trabajo aparte. Encaja con el criterio 4 — cuantas menos copias
   divergentes, menos que restaurar — pero no bloquea nada.

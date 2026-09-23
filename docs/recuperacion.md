# Recuperación del servidor

Qué hacer si muere el disco, o la máquina entera. La parte que hay que
leer con el servidor muerto cabe en la primera pantalla; el resto es para
mantener el kit y saber cómo se probó.

Diseño y alternativas descartadas: [decisiones §14](decisiones.md#14-copia-del-sistema-reproducible-en-vez-de-imagen-de-disco).
Plan original con el inventario completo: [plan-recuperacion.md](plan-recuperacion.md).

---

## Con el servidor muerto

Hace falta **la passphrase** (el papel) y **la cuenta de Google**. Nada más.

```
1. Instalar Ubuntu 26.04 (Desktop o Server, da igual) con usuario `server`
   y hostname `server`. Cable de red.

2. Con el navegador, en drive.google.com, carpeta Sistema_Backups: bajar a
   ~/kit el sistema_FECHA.tar.gz.gpg más reciente y todos los
   repos/*.bundle.gpg. (Hay un LEEME.txt en la carpeta con estos pasos.)

3. git clone https://github.com/SaguadoDev/homelab
   sudo bash homelab/scripts/restaurar-servidor.sh --kit ~/kit

   Pide la passphrase y no vuelve a preguntar nada: rclone.conf viene
   dentro del tar, los repos de los bundles, los datos de Drive.
   (Si GitHub no está: gpg -d ~/kit/homelab-*.bundle.gpg > homelab.bundle
    && git clone homelab.bundle homelab.)

4. Si estás por SSH, en la fase 3 entra en vigor la IP fija y la sesión se
   corta: vuelve a entrar en 192.168.1.50 y relanza con `--desde 4`.

5. Si cambió la máquina (MAC nueva): reserva DHCP de 192.168.1.50 en el
   router. El DNS de la LAN ya apunta ahí.
```

Sin nada bajado a mano también funciona: sin `--kit`, el script pide la
passphrase, una ruta a `rclone.conf` (o lanza `rclone config`) y baja de
Drive el tar y los bundles él mismo. El token de GitHub solo se pide si no
hay bundle de un repo privado.

Unos 20–40 minutos, casi todo construyendo las imágenes de Vault App y
Combina y bajando la media de openGym. El script deja un log en
`~/restauracion-FECHA.log` e imprime al final la lista de lo que queda
fuera del servidor.

**Nada se teclea salvo la passphrase.** `rclone.conf`, los `.env`, los
composes, el cron, la configuración de AdGuard y la identidad de Tailscale
vienen del tar del sistema; el código, de los bundles; los datos, de las
cinco copias de siempre. Si el script pide algo más, es un fallo del
script.

### Lo que hace, fase a fase

| # | Fase | De dónde sale |
|---|---|---|
| 1 | Paquetes: Docker, Tailscale, rclone, gnupg, sqlite3, dig, jq, cockpit, pcp | apt |
| 2 | Passphrase en su sitio; descifra el tar del kit (o baja el último de Drive); verifica `SHA256SUMS`; saca `rclone.conf` del tar | kit + `Sistema_Backups` |
| 3 | `/etc`: resolved (host → 1.1.1.1), `daemon.json`, sysctl del exit node, claves SSH del host, gdm3, hostname, netplan con la IP fija | tar del sistema |
| 4 | Clona `homelab`, `vault_app`, `Combina` y el repo de hexwatch (ruta y URL de `~/.config/hexwatch.env`, que viene en el tar) desde los bundles (kit, o `Sistema_Backups/repos/`; GitHub solo si no hay); coloca composes vivos, `.env`, scripts de backup, dotfiles, memoria de Claude, `~/adguard/conf`; crea `~/bot` con su venv | bundles + tar |
| 5 | Restaura `tailscaled.state`: misma IP, mismo nombre, mismos `serve`, sin login. Aborta si el nodo no se llama `server` | tar |
| 6 | AdGuard con el drop-in `After=tailscaled`; comprueba bloqueo, split DNS y `bind_hosts` con la IP del tailnet | tar |
| 7 | Vaultwarden: `vw-data` de la copia; comprueba `/alive`, `prelogin` y que `rsa_key.pem` no cambia | `Vaultwarden_Backups` |
| 8 | Postgres solo → `pg_restore` de `vault` → API (`--build`) | `Vault_Backups` |
| 9 | Rol y base `armario` en el Postgres compartido → `pg_restore` → fotos → API (`--build`) | `Armario_Backups` |
| 10 | openGym: `data/` de la copia; comprueba que `secret` no cambia y que `RP_ID` es el nodo | `openGym_Backups` |
| 11 | hexwatch: `hexwatch.db` de la copia (con `integrity_check`), symlink de la unidad a su repo, arranque y `/status` | `Hexwatch_Backups` |
| 12 | Bot (symlink de la unidad) y los dos cron, con la línea de `backup-sistema.sh` | tar |
| 13 | `docker ps`, los cinco `https://`, opcionalmente las seis copias a mano (`--con-backups`); borra `/root/restauracion` | — |

Cada fase comprueba antes de actuar: relanzar el script entero es seguro.
`--solo N` ejecuta una fase; `--desde N` retoma.

### Fuera del servidor

Lo que ningún script puede hacer y se olvida:

1. **Router.** Reserva DHCP de `192.168.1.50` para la MAC nueva. El DNS de
   la LAN ya apunta a esa IP.
2. **Consola de Tailscale, solo si el nodo salió con otra IP** (no se pudo
   restaurar `tailscaled.state`): borrar el nodo `server` viejo *antes* de
   autenticar para heredar el nombre; aprobar el exit node; cambiar el
   nameserver global del tailnet a la IP nueva ([decisión §13](decisiones.md#13-adguard-como-dns-del-tailnet-no-solo-de-la-lan)).
3. **Clientes.** Con el mismo nombre MagicDNS, Bitwarden, las passkeys de
   openGym y las apps de Combina y hexwatch siguen funcionando sin tocar
   nada. Si el nombre cambió: re-registrar las passkeys y recompilar las
   dos apps.
4. **SSH.** Si no se restauraron las `ssh_host_*`, borrar la entrada vieja
   de `known_hosts` en los clientes.

---

## El kit

La única pieza que no puede vivir dentro de las copias es la passphrase.
Todo lo demás está en Drive, y Drive se abre con la cuenta de Google desde
cualquier navegador.

**En papel, en un cajón:**

- La passphrase (`~/.config/vault/backup-passphrase`, 48 caracteres).
- La cuenta de Google del Drive y del login de Tailscale.
- El nombre del proyecto de Google Cloud donde vive el cliente OAuth de
  rclone. Solo hace falta si se pierde el tar del sistema *y* hay que
  rehacer `rclone.conf` a mano: el remoto usa `scope = drive.file`, que
  solo ve los ficheros subidos por *ese* cliente; con el cliente por
  defecto de rclone las copias son invisibles.
- "El procedimiento está en github.com/SaguadoDev/homelab, docs/recuperacion.md".

**En Drive, `Sistema_Backups/`**, lo deja `backup-sistema.sh` cada noche:

- `sistema_FECHA.tar.gz.gpg` — con `rclone.conf` dentro, entre lo demás.
- `repos/homelab-HASH.bundle.gpg`, `repos/vault_app-HASH.bundle.gpg`,
  `repos/Combina-HASH.bundle.gpg` y el del repo de hexwatch — los cuatro
  repos enteros, renovados cuando cambia `HEAD`. Sin ellos haría falta un
  token de GitHub para los tres privados, y ese token tendría que
  guardarse en algún sitio.
- `LEEME.txt` — los cuatro pasos, para quien abra la carpeta dentro de
  tres años.

**Y en la bóveda de Bitwarden**, que la app del móvil abre sin red: la
passphrase. Comprobarlo en modo avión, no asumirlo.

`/copias` en el bot vigila la edad del tar. Si un día se quiere una copia
fuera de Google, basta con bajar esa carpeta a un disco: ya va cifrada.

---

## Cómo se probó

Una restauración que no se ha ejecutado nunca es una hipótesis. El
ensayo se hace en una VM en el propio servidor, sin tocar producción:

```bash
sudo snap install multipass                    # el binario queda en /snap/bin
multipass set local.privileged-mounts=true
multipass launch 26.04 --name ensayo --cpus 2 --memory 6G --disk 30G
multipass mount ~/vault_app ensayo:/mnt/repos/vault_app
multipass mount ~/Combina   ensayo:/mnt/repos/Combina
multipass mount ~/homelab   ensayo:/mnt/repos/homelab
multipass exec ensayo -- sudo adduser --disabled-password --gecos '' server
multipass exec ensayo -- mkdir -p /tmp/kit
# `multipass transfer` no puede leer directorios ocultos del home (confinamiento
# del snap): se pasa por stdin.
cat ~/.config/vault/backup-passphrase | multipass exec ensayo -- bash -c 'cat > /tmp/kit/backup-passphrase'
cat ~/.config/rclone/rclone.conf       | multipass exec ensayo -- bash -c 'cat > /tmp/kit/rclone.conf'
multipass exec ensayo -- sudo bash /mnt/repos/homelab/scripts/restaurar-servidor.sh \
    --ensayo --kit /tmp/kit --repos-desde /mnt/repos
```

Con `--repos-desde` los clones salen de los montajes, así el ensayo
prueba el árbol de trabajo actual (solo lo **commiteado**: `git clone`
de un montaje no ve cambios sin confirmar). Para ensayar la vía real
—la de "solo tengo la passphrase y Drive"— se baja a un directorio el
último `sistema_*.tar.gz.gpg` y `repos/*.bundle.gpg`, se pasa como
`--kit` (con `backup-passphrase` dentro, porque `multipass exec` no tiene
terminal para pedirla) y se omite `--repos-desde`: el script saca
`rclone.conf` del tar y clona de los bundles.

`--ensayo` cambia exactamente esto, y el script lo imprime al arrancar:
no toca netplan ni hostname (la VM va por DHCP de multipass), **no
restaura `tailscaled.state`** (dos nodos con la misma clave se pisan),
**no instala cron ni bot** (subirían copias duplicadas a Drive y dos bots
con el mismo token se pelean), y AdGuard escucha en la IP de la VM. Los
datos que levanta son los reales, bajados de Drive con el `rclone.conf`
del kit.

Se verifica con los mismos criterios que la restauración real (fases
6–10) y al acabar `multipass delete --purge ensayo`. Repetir cuando cambie
el script o se añada un servicio.

| Fecha | Resultado |
|---|---|
| 18/09/2026 (2º) | Vía real: kit con solo el tar y los tres bundles bajados de Drive, sin `rclone.conf`, sin montajes, sin token. Fases 1–12 limpias a la primera en unos 6 minutos: `rclone.conf` salió del tar, los tres repos de los bundles, y los mismos datos que en el primer ensayo. |
| 18/09/2026 | Primer ensayo, VM multipass en el propio servidor (2 vCPU, 6 GB). Fases 1–12 en unos 8 minutos con datos reales de Drive: 2 usuarios y 97 ítems en Vaultwarden con `rsa_key` intacta, 14 tablas en `vault`, rol y base `armario` con 35 filas, 2 perfiles en openGym con `secret` intacto, AdGuard filtrando en la IP de la VM. Dos retoques al script salidos del ensayo: openGym se comprueba contra `/api/health` (el healthcheck de la imagen sondea cada 5 min y la espera agotaba), y AdGuard reintenta el bloqueo durante dos minutos mientras baja las listas. Sin tocar producción. |

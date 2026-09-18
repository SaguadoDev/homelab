# Recuperación del servidor

Qué hacer si muere el disco, o la máquina entera. La parte que hay que
leer con el servidor muerto cabe en la primera pantalla; el resto es para
mantener el kit y saber cómo se probó.

Diseño y alternativas descartadas: [decisiones §14](decisiones.md#14-copia-del-sistema-reproducible-en-vez-de-imagen-de-disco).
Plan original con el inventario completo: [plan-recuperacion.md](plan-recuperacion.md).

---

## Con el servidor muerto

Hace falta el **kit** (más abajo): el papel con la passphrase y el USB.

```
1. Instalar Ubuntu 26.04 (Desktop o Server, da igual) con usuario `server`
   y hostname `server`. Cable de red.

2. git clone https://github.com/SaguadoDev/homelab
   sudo bash homelab/scripts/restaurar-servidor.sh --kit /media/server/KIT

   (sin USB: sin --kit; el script pide la passphrase, la ruta a rclone.conf
    o lanza `rclone config`, y el token de GitHub)

3. Si estás por SSH, en la fase 3 entra en vigor la IP fija y la sesión se
   corta: vuelve a entrar en 192.168.1.50 y relanza con `--desde 4`.

4. Si cambió la máquina (MAC nueva): reserva DHCP de 192.168.1.50 en el
   router. El DNS de la LAN ya apunta ahí.
```

Unos 20–40 minutos, casi todo construyendo las imágenes de Vault App y
Combina y bajando la media de openGym. El script deja un log en
`~/restauracion-FECHA.log` e imprime al final la lista de lo que queda
fuera del servidor.

**Nada se teclea salvo los tres secretos del kit.** Los `.env`, los
composes, el cron, la configuración de AdGuard y la identidad de Tailscale
vienen del tar del sistema; los datos, de las cuatro copias de siempre.
Si el script pide algo más, es un fallo del script.

### Lo que hace, fase a fase

| # | Fase | De dónde sale |
|---|---|---|
| 1 | Paquetes: Docker, Tailscale, rclone, gnupg, sqlite3, dig, jq, cockpit, pcp | apt |
| 2 | Passphrase y `rclone.conf` en su sitio; baja y descifra el último `sistema_*.tar.gz.gpg`; verifica `SHA256SUMS` | kit + `Sistema_Backups` |
| 3 | `/etc`: resolved (host → 1.1.1.1), `daemon.json`, sysctl del exit node, claves SSH del host, gdm3, hostname, netplan con la IP fija | tar del sistema |
| 4 | Clona `homelab`, `vault_app`, `Combina`; coloca composes vivos, `.env`, scripts de backup, `rclone.conf`, dotfiles, memoria de Claude, `~/adguard/conf`; crea `~/bot` con su venv | GitHub + tar |
| 5 | Restaura `tailscaled.state`: misma IP, mismo nombre, mismos `serve`, sin login. Aborta si el nodo no se llama `server` | tar |
| 6 | AdGuard con el drop-in `After=tailscaled`; comprueba bloqueo, split DNS y `bind_hosts` con la IP del tailnet | tar |
| 7 | Vaultwarden: `vw-data` de la copia; comprueba `/alive`, `prelogin` y que `rsa_key.pem` no cambia | `Vaultwarden_Backups` |
| 8 | Postgres solo → `pg_restore` de `vault` → API (`--build`) | `Vault_Backups` |
| 9 | Rol y base `armario` en el Postgres compartido → `pg_restore` → fotos → API (`--build`) | `Armario_Backups` |
| 10 | openGym: `data/` de la copia; comprueba que `secret` no cambia y que `RP_ID` es el nodo | `openGym_Backups` |
| 11 | Bot (symlink de la unidad) y los dos cron, con la línea de `backup-sistema.sh` | tar |
| 12 | `docker ps`, los cuatro `https://`, opcionalmente las cinco copias a mano (`--con-backups`); borra `/root/restauracion` | — |

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
   openGym y el APK de Combina siguen funcionando sin tocar nada. Si el
   nombre cambió: re-registrar las passkeys y recompilar el APK.
4. **SSH.** Si no se restauraron las `ssh_host_*`, borrar la entrada vieja
   de `known_hosts` en los clientes.

---

## El kit

Sin kit no hay recuperación: las dos cosas que abren las copias no pueden
vivir dentro de las copias.

**En papel, en un cajón:**

- La passphrase (`~/.config/vault/backup-passphrase`, 48 caracteres).
- La cuenta de Google del Drive y del login de Tailscale.
- El nombre del proyecto de Google Cloud donde vive el cliente OAuth de
  rclone (por si hay que rehacer `rclone.conf`: el remoto usa
  `scope = drive.file`, que solo ve los ficheros subidos por *ese*
  cliente; con el cliente por defecto de rclone las copias son invisibles).
- "El procedimiento está en github.com/SaguadoDev/homelab, docs/recuperacion.md".

**En un USB:** lo llena `scripts/kit-usb.sh`.

```bash
~/homelab/scripts/kit-usb.sh /media/server/KIT
```

Deja `rclone.conf`, el último tar del sistema, `restaurar-servidor.sh`
suelto, los tres repos como `git bundle` y un `KIT-FECHA.txt` con lo que
hay y lo que falta. Lo único que no puede escribir él es el
`github-token`: un *fine-grained PAT* de solo lectura (Contents) sobre
`vault_app` y `Combina`, que se crea en GitHub y se guarda a mano en el
USB con ese nombre.

**Y en la bóveda de Bitwarden**, que la app del móvil abre sin red: la
passphrase. Comprobarlo en modo avión, no asumirlo.

Refrescar el USB cuando cambie algo del kit y como mínimo cada tres
meses. El bot vigila la edad del tar en Drive (`/copias`); el USB no lo
vigila nadie.

---

## Cómo se probó

Una restauración que no se ha ejecutado nunca es una hipótesis. El
ensayo se hace en una VM en el propio servidor, sin tocar producción:

```bash
sudo snap install multipass
multipass launch 26.04 --name ensayo --cpus 2 --memory 6G --disk 30G
multipass mount ~/vault_app ensayo:/mnt/repos/vault_app
multipass mount ~/Combina   ensayo:/mnt/repos/Combina
multipass mount ~/homelab   ensayo:/mnt/repos/homelab
multipass exec ensayo -- sudo adduser --disabled-password --gecos '' server
multipass transfer ~/.config/vault/backup-passphrase ~/.config/rclone/rclone.conf ensayo:/tmp/kit/
multipass exec ensayo -- sudo bash /mnt/repos/homelab/scripts/restaurar-servidor.sh \
    --ensayo --kit /tmp/kit --repos-desde /mnt/repos
```

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
| _pendiente_ | primer ensayo |

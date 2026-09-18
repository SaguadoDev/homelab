# Decisiones

Por qué está montado así y no de otra manera. Incluye las alternativas
descartadas, que suelen explicar más que la opción elegida.

---

## 1. Tailscale en lugar de abrir puertos en el router

**Alternativas:** redirección de puertos + DNS dinámico + Let's Encrypt
por DNS-01; Cloudflare Tunnel; WireGuard a mano.

**Elegido:** Tailscale.

Abrir el 443 de casa significa aceptar que todo internet llame a tu
puerta y confiar en que cada servicio detrás aguante. Vaultwarden es
sólido, pero la superficie de ataque pasa a ser "cualquiera" en lugar de
"mis dispositivos".

Con Tailscale la superficie es el tailnet. Un servicio con un fallo grave
sin parchear sigue siendo inalcanzable para quien no esté dentro. Además
resuelve de paso tres cosas que con puertos abiertos habría que montar por
separado: DNS estable (MagicDNS), certificados (`serve`) y acceso desde
fuera sin IP fija.

**Lo que se paga:** dependencia de un coordinador ajeno, y que cada
dispositivo nuevo tenga que unirse al tailnet. Para uso familiar, barato.
WireGuard a pelo evitaría la dependencia a cambio de gestionar claves y
NAT a mano; no compensa.

---

## 2. El DNS del host apunta a 1.1.1.1, no a AdGuard

**El host resuelve por `1.1.1.1` y `8.8.8.8`. Los demás dispositivos de la
casa resuelven por AdGuard.** Parece incoherente y es deliberado.

Si el servidor se resolviera a sí mismo a través de AdGuard, se crearía
una dependencia circular: para arrancar AdGuard, Docker necesita resolver
`registry-1.docker.io`; para resolverlo necesita AdGuard. Basta con que el
contenedor no levante tras un reinicio para que la máquina se quede sin
DNS y sin la forma de arreglarlo.

Manteniendo el host con resolutores públicos:

- El servidor arranca aunque AdGuard esté caído.
- `docker pull`, `apt update` y la renovación ACME de tailscaled siguen
  funcionando pase lo que pase con el filtrado.
- Se puede depurar AdGuard **desde** la máquina que lo aloja.

**Lo que se paga:** el tráfico del propio servidor no pasa por el filtro.
Es un host sin navegador; no se pierde nada real.

**Cómo se consigue, que no es evidente.** La decisión es fácil de enunciar
y tiene una trampa de implementación que costó tres intentos (incidencia 9).
El host resuelve por el *stub* de systemd-resolved en `127.0.0.53`, que a su
vez consulta `1.1.1.1` y `8.8.8.8`. Para que ese stub pueda existir, AdGuard
**no puede escuchar en `0.0.0.0`**: en `network_mode: host` el comodín ocupa
todas las direcciones de la máquina, el loopback entero incluido, y ahí está
`127.0.0.53`.
Por eso `bind_hosts` es la IP de LAN concreta y no el comodín.

El montaje se sostiene sobre tres piezas que hay que mirar juntas:

| Pieza | Valor | Si se rompe |
|---|---|---|
| `bind_hosts` de AdGuard | `192.168.1.50` | el stub no puede bindear |
| `DNSStubListener` | `yes` (por defecto) | no hay `127.0.0.53` |
| `/etc/resolv.conf` | symlink a `stub-resolv.conf` | tailscaled pasa a modo directo |

La tercera es consecuencia de las dos primeras: tailscaled comprueba que
`/etc/resolv.conf` apunte a `127.0.0.53` y, si no, se declara dueño del
fichero. No es un capricho suyo, es su forma de detectar si resolved está
realmente en uso.

---

## 3. TLS gestionado por tailscaled, no por un proxy inverso

**Alternativas:** Nginx o Caddy delante con certificados propios.

`tailscale serve` termina TLS con un certificado real de Let's Encrypt y
lo **renueva solo**. Un proxy inverso añadiría un contenedor más, su
configuración, su renovación y un punto de fallo, para dar exactamente el
mismo resultado.

Corolario que costó aprender: si tailscaled gestiona los certificados, no
hay que generarlos a mano con `tailscale cert`. Esos ficheros son copias
estáticas que caducan a los 90 días y que nadie renueva.

**Cuándo cambiaría:** si hiciera falta enrutar por nombre de host, cachear
o servir estáticos. Hoy no hace falta.

---

## 4. Todo publicado en `127.0.0.1`, nunca en `0.0.0.0`

`tailscale serve` corre **en el host**, así que alcanza los servicios por
loopback. Publicar en `0.0.0.0` no aporta nada y abre el servicio a la red
local en HTTP plano, saltándose Tailscale.

Estar dentro de casa no es una credencial. Una wifi de invitados, una TV
con firmware de 2019 o el portátil de una visita están en esa misma red.

La única excepción es AdGuard, que **tiene** que escuchar en la LAN para
hacer de DNS, y Cockpit, que está pendiente de corregir.

---

## 5. Postgres sin puerto publicado

La base de datos no expone ningún puerto al host: solo la API la alcanza,
por el nombre del servicio dentro de la red del compose.

Así la base de datos no tiene que defenderse de nada. Su única superficie
es la API, que ya exige token. Para administrarla se entra por
`docker compose exec`, que además deja constancia de que fue una acción
manual.

---

## 6. Copias cifradas antes de salir de la máquina

Las copias locales van en claro; las que suben a Google Drive van
cifradas con GPG simétrico (AES-256).

No es incoherente: son amenazas distintas. El dump local vive en el mismo
disco que la base de datos y su cifrado no protege de nada que no proteja
ya el disco. En cuanto el fichero sale hacia una cuenta de terceros, el
modelo cambia: ahí la confidencialidad depende de una cuenta de Google.

Con Vaultwarden se podría argumentar que los ítems ya viajan cifrados de
extremo a extremo — y es cierto. Pero el tar lleva además `rsa_key.pem`,
los correos de los usuarios, los secretos TOTP de quien tenga 2FA y el
`docker-compose.yml` con la contraseña SMTP. Nada de eso está cifrado por
la contraseña maestra.

**Una sola passphrase para los tres sistemas.** Varias significan varias
cosas que custodiar, y en la práctica una acaba perdiéndose. Con una, el
único secreto a proteger es ese. Se paga que su filtración los comprometa
todos, y que el coste de esa apuesta crezca con cada sistema que se suma:
hoy son la bóveda, las finanzas y los entrenamientos.

---

## 7. Retención: 7 días fuera, 30 días dentro

En Drive se conservan 7 copias diarias; en el disco local, 30 noches de
`pg_dump`.

Son dos redes distintas. La local es abundante y barata y cubre el caso
habitual (un borrado tonto, una migración que sale mal). La remota cubre
el caso catastrófico —el disco, un robo, un cifrado por ransomware— y
paga por espacio, así que se queda en la ventana mínima razonable para
detectar un problema.

---

## 8. Sin Prometheus ni Grafana

Un bot de Telegram de 500 líneas cubre la necesidad real: enterarse de que
algo se ha caído. La pila de observabilidad son tres contenedores más,
almacenamiento de series temporales, dashboards que mantener y alertas que
configurar — para vigilar un host y seis contenedores.

Además llega a donde hay que llegar: al móvil, sin abrir nada.

**Cuándo cambiaría:** el día que quiera series históricas para ver
tendencias, no solo el estado ahora mismo.

---

## 9. openGym con la versión fijada

**Alternativas:** `:latest` como AdGuard y Vaultwarden; construir las
imágenes desde el código.

**Elegido:** etiqueta exacta (`1.2.11`), y se sube a mano tras leer el
changelog.

Es una excepción deliberada al resto del montaje. Vaultwarden y AdGuard
llevan años, tienen mucha gente detrás y un `:latest` roto se detecta y se
corrige en horas. openGym tiene semanas de vida pública, un desarrollador
principal, y en su propio tracker hay abierta una incidencia de sesiones de
entrenamiento borradas. Un `docker compose pull` desatendido sobre eso es
apostar el historial a que esa noche no había regresión.

Construir desde el código se descartó por lo contrario: metería el
repositorio de un tercero dentro de este, y el `docker-compose.yml` del
proyecto trae `"${WEB_PORT:-8080}:80"` —publicado en `0.0.0.0`— que habría
que corregir en cada actualización. Con imágenes ya construidas, este
repositorio se queda con lo que le toca, que es el despliegue.

**Lo que se paga:** los parches de seguridad no llegan solos. La
contrapartida es que el servicio no es alcanzable desde internet, así que
la ventana de exposición es el tailnet.

---

## 10. Un solo nombre MagicDNS para todos los servicios

Los servicios se distinguen por puerto (`:443`, `:8443`, `:8444`), no por
nombre de host. Dar a cada uno el suyo exigiría un nodo de Tailscale por
servicio o un proxy inverso delante, que es justo lo que evita la
[decisión §3](#3-tls-gestionado-por-tailscaled-no-por-un-proxy-inverso).

**Lo que se paga, y no es gratis:** Vaultwarden y openGym comparten
hostname, luego comparten RP ID de WebAuthn. El selector de passkeys del
móvil ofrece las credenciales de los dos servicios al entrar en cualquiera
de ellos. Funciona —cada servicio filtra por su propio credential ID— pero
hay que elegir a mano. Con dos servicios con passkeys es un roce; con seis
sería motivo para replantearlo.

## 11. Combina despliega desde el clon de su propio repositorio

**Alternativas:** un directorio de despliegue aparte, como los otros
servicios (`~/combina/` con el compose copiado y los datos al lado).

**Elegido:** el clon del repositorio de la aplicación **es** el directorio
de ejecución. El `docker-compose.yml` está versionado ahí, y el `.env`,
`data/prendas/` y `logs/` cuelgan del mismo sitio bloqueados por su
`.gitignore`.

Se montó primero de la otra forma y duró unas horas. El problema no es la
comodidad: es que había **dos copias del mismo `docker-compose.yml`**, la
del repositorio y la desplegada, y se desincronizaron a la primera
modificación. Con el compose y el código en sitios distintos, además, el
contexto de construcción tiene que apuntar al repositorio de todas formas
—la imagen necesita el directorio compartido de tipos—, así que la
separación no aislaba nada y solo añadía una variable más que mantener.

Vault App ya despliega así, de modo que no es un patrón nuevo en la
máquina: conviven los dos.

**Lo que cuesta:** un `git clean -xfd` en ese directorio se lleva las fotos
de la usuaria y el `.env`, porque son justo lo que git ignora. Lo recupera
la copia nocturna, pero se pierde lo del día. Está avisado en el README del
servicio, que es donde se va a leer antes de escribir ese comando.

## 12. Combina reutiliza la instancia de PostgreSQL, con rol y base propios

**Alternativas:** un segundo contenedor de Postgres solo para este
servicio.

**Elegido:** la instancia que ya existe, con `armario` / `armario_user`
nuevos y sin más permisos que sobre su propia base.

Un segundo motor duplicaría memoria en una máquina modesta y, peor,
duplicaría la ruta de copias: otro volcado, otra verificación y otro
horario que cuadrar. Con roles separados el aislamiento que de verdad
importa —que un servicio no lea los datos del otro— ya está.

**Lo que cuesta:** un apagón sucio o una migración que salga mal afectan a
los dos servicios a la vez. Se acepta porque las copias se lanzan por
separado y a horas distintas (04:30 y 05:30), y porque el fallo compartido
que de verdad da miedo —que no haya SAI— no lo arregla tener dos motores.

## 13. AdGuard como DNS del tailnet, no solo de la LAN

**Alternativas:** dejar el tailnet sin DNS propio (lo que había); *Private
DNS* de Android apuntando a un DoT publicado con `tailscale serve
--tls-terminated-tcp=853`; exit node más el DNS del host apuntando a AdGuard.

**Elegido:** `<IP_TAILSCALE>` como *nameserver* global del tailnet, con
*Override local DNS*, y AdGuard escuchando también en esa IP.

El tailnet no tenía resolutor configurado: solo split DNS para `*.ts.net`.
Un dispositivo con Tailscale activo usaba el DNS de la red en la que
estuviera —en casa el router, luego AdGuard; con datos móviles, el de la
operadora, luego anuncios—. Y aunque el tailnet hubiera apuntado al
servidor, AdGuard no atendía: `bind_hosts` era solo la IP de LAN. Se
comprobó con `dig @<IP_TAILSCALE>`: *connection refused*.

Con el cambio, todo dispositivo del tailnet resuelve contra AdGuard esté
donde esté, y AdGuard lo ve con su IP `100.x`, así que las estadísticas
por cliente siguen funcionando fuera de casa. Con Tailscale apagado nada
cambia: el dispositivo vuelve al DNS de la red.

**Por qué no las otras.** *Private DNS* arregla un móvil cada vez, y en
modo estricto deja el dispositivo sin internet si el servidor no responde.
El exit node obliga a enrutar todo el tráfico por casa y a deshacer la
[decisión §2](#2-el-dns-del-host-apunta-a-1111-no-a-adguard).

**Lo que se paga.**

- Si el servidor cae, cualquier dispositivo con Tailscale activo se queda
  sin DNS. No hay respaldo posible: tailscaled consulta a todos los
  *nameservers* globales en paralelo y se queda con la primera respuesta,
  así que un segundo resolutor público no sería un respaldo sino una
  fuga que se saltaría el filtro a ratos. Es un solo *nameserver* o nada.
- `bind_hosts` gana una IP que no existe hasta que tailscaled levanta
  `tailscale0`. Si Docker arranca antes, AdGuard no puede bindear y sale.
  Por eso `docker.service` lleva un *drop-in* con `After=tailscaled.service`
  (`systemd/docker-after-tailscaled.conf`, enlazado en
  `/etc/systemd/system/docker.service.d/`). tailscaled configura la
  interfaz desde su estado guardado antes de hablar con el servidor de
  control, así que la ventana es corta; y si aun así AdGuard llegara antes,
  `restart: unless-stopped` lo reintenta hasta que la IP existe.
- Sigue sin ser `0.0.0.0`: son dos IPs concretas. La restricción de la
  incidencia 9 no cambia.

## 14. Copia del sistema: reproducible en vez de imagen de disco

**Alternativas:** imagen de disco periódica (Clonezilla, `dd`, Timeshift)
a un disco externo; no hacer nada y reconstruir a mano si pasa.

**Elegido:** capas reproducibles. Ubuntu limpia + una lista fija de
paquetes + doce ficheros de `/etc` + tres repos de GitHub + un tar cifrado
con lo que no se regenera (secretos, identidad de Tailscale, AdGuard,
cron, composes vivos) + las cuatro copias de datos que ya existían. Un
script, `scripts/restaurar-servidor.sh`, sabe el orden. Runbook en
[recuperacion.md](recuperacion.md); inventario y plan en
[plan-recuperacion.md](plan-recuperacion.md).

Hasta septiembre de 2026 había copia de los **datos** de los cuatro
servicios y de nada más. Si moría el disco, los datos volvían pero había
que reconstruir a mano paquetes, IP fija, DNS del host, Docker, Tailscale
con su identidad y sus `serve`, AdGuard, los `.env`, los cuatro cron y el
bot. Y tres cosas no estaban en ningún sitio: `tailscaled.state`, la
configuración de AdGuard y el cron de root.

**Por qué no una imagen.** Necesita un segundo disco enchufado, envejece
desde el día que se hace, arrastra 24 GB de los que casi todo se regenera
y, si lo que muere es la máquina y no el disco, la imagen de un m715q no
tiene por qué arrancar en otro hardware. La reproducibilidad además
obliga a que el repo diga la verdad: lo que no está documentado no se
restaura, y eso se nota en el ensayo.

**El nudo que ningún software desata.** Para descifrar el tar del
sistema hace falta la passphrase, y la passphrase no puede vivir dentro
de lo que protege. Es la única pieza en papel. Todo lo demás está en
Drive, que se abre con la cuenta de Google desde un navegador: el tar
lleva `rclone.conf` dentro, y los tres repos van como `git bundle`
cifrados en la misma carpeta, así que ni el acceso a Drive ni GitHub ni
un token son requisitos. Se descartó un USB con el kit: es una cosa más
que mantener al día y que nadie vigila. La bóveda de Bitwarden en el
móvil —que se abre sin red— es la copia digital más probable de la
passphrase, y el motivo de que exista una fuera del propio Vaultwarden.

**Identidad de Tailscale, sí.** Restaurar `tailscaled.state` devuelve el
nodo con la misma IP y el mismo nombre, sin login y sin tocar la consola.
Importa más de lo que parece: la IP es el nameserver global del tailnet
([§13](#13-adguard-como-dns-del-tailnet-no-solo-de-la-lan)) y el nombre
MagicDNS ata las passkeys de openGym y la URL compilada en el APK de
Combina. Un nodo nuevo sale como `server-1` si el viejo sigue en la
consola, y entonces nada de eso vale. El script aborta si el nombre no es
`server`.

**Cockpit se queda en la LAN.** Contradice la
[decisión §4](#4-todo-publicado-en-127001-nunca-en-0000) y se decidió
mantenerlo igualmente: se usa desde el PC y el móvil, y publicarlo por
`tailscale serve` rompería ese uso. Es la única excepción y el script de
restauración lo instala por defecto.

**Lo que se paga.**

- Una quinta copia nocturna en el cron de root, ~300 KB, y una línea más
  en el bot (`/copias`).
- El tar lleva la clave privada del nodo de Tailscale, las claves SSH del
  host y todos los secretos. Va cifrado con la misma passphrase que el
  resto; si esa passphrase cae, cae todo, igual que antes.
- El ensayo hay que repetirlo cuando cambie el script o se añada un
  servicio, y es manual.
- Los cuatro scripts de backup del repo siguen saneados con
  `/home/homelab`: no son ejecutables tal cual. Mientras no se
  refactoricen a rutas relativas, el tar del sistema lleva las copias
  vivas y esa es la fuente de verdad. Pendiente.


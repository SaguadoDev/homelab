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

**Una sola passphrase para los dos sistemas.** Dos significan dos cosas
que custodiar, y en la práctica una acaba perdiéndose. Con una, el único
secreto a proteger es ese. Se paga que su filtración comprometa ambos.

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
configurar — para vigilar un host y cuatro contenedores.

Además llega a donde hay que llegar: al móvil, sin abrir nada.

**Cuándo cambiaría:** el día que quiera series históricas para ver
tendencias, no solo el estado ahora mismo.

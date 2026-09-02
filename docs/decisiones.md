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

## 11. Armario despliega desde el clon de su propio repositorio

**Alternativas:** un directorio de despliegue aparte, como los otros
servicios (`~/armario/` con el compose copiado y los datos al lado).

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

## 12. Armario reutiliza la instancia de PostgreSQL, con rol y base propios

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

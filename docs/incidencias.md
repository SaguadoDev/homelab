# Incidencias

Lo que se rompió, por qué, y cómo se arregló. Ordenado por lo que enseñó,
no por gravedad.

---

## 1. El puerto 80 ya estaba ocupado

**Síntoma.** Al intentar publicar el primer servicio en el 80, el puerto
estaba cogido. Nada evidente escuchaba ahí.

**Causa.** AdGuard Home corre con `network_mode: host` y su interfaz web
escucha en `0.0.0.0:80`. En modo host no hay mapeo de puertos que revise:
el contenedor ocupa el 80 de la máquina entera, y `docker ps` no muestra
ningún puerto publicado porque técnicamente no publica ninguno.

**Solución.** No mover AdGuard: el modo host es necesario para que vea la
IP de origen real de cada consulta. En su lugar, ningún servicio usa el 80
del host. Cada uno escucha en un puerto alto en loopback y `tailscale
serve` los publica en 443 y 8443 con TLS.

**Lección.** `network_mode: host` convierte los puertos del contenedor en
puertos del host sin que aparezcan en `docker ps`. A la hora de buscar
quién ocupa un puerto, `ss -tlnp` dice la verdad y `docker ps` no.

---

## 2. Las passkeys dejaron de funcionar al pasar de IP a dominio

**Síntoma.** Vaultwarden funcionaba en `http://192.168.1.X:8080` y las
passkeys estaban registradas. Al pasar a `https://<host>.<tailnet>.ts.net`
los clientes dejaron de reconocerlas: el navegador no ofrecía la passkey,
como si no existiera.

**Causa.** WebAuthn ata cada credencial a un **RP ID**, derivado del
origen donde se registró. Una passkey creada bajo `192.168.1.X:8080`
pertenece a ese RP ID y **no es válida** bajo otro. No es un fallo:
es exactamente lo que impide que un sitio use las credenciales de otro.
En Vaultwarden ese origen sale de la variable `DOMAIN`.

**Solución.** Poner `DOMAIN` en la URL definitiva **antes** de registrar
nada, y volver a registrar las passkeys ya creadas. No hay migración
posible: la credencial vieja es criptográficamente ajena al dominio nuevo.

**Lección.** Decidir la URL definitiva es lo primero, no lo último. Todo
lo que se registre antes —passkeys, 2FA de tipo WebAuthn, clientes
sincronizados— queda atado a ella. El coste de cambiarla después no es
editar una variable, es reconfigurar todos los dispositivos.

---

## 3. Tras un corte de luz, la mitad de las cosas no volvían

**Síntoma.** Después de un apagón, el servidor arrancaba pero algunos
servicios no. El bot, que es quien debería avisar, tampoco.

**Causa.** Dos, encadenadas. Los contenedores no tenían política de
reinicio explícita, y el bot arrancaba antes de que Docker y tailscaled
estuvieran listos: fallaba y, sin `Restart=`, se quedaba muerto.

**Solución.**

- `restart: unless-stopped` en todos los servicios (`always` en
  Vaultwarden, que debe volver siempre).
- En la unidad de systemd del bot, `After=network-online.target
  tailscaled.service docker.service` con `Restart=always` y
  `RestartSec=10`.

Deliberadamente `After=` y no `Requires=`: si Docker tarda o falla, el bot
arranca igual y **reporta** el fallo. Con `Requires=` el monitor se caería
junto con lo que vigila, que es justo cuando hace falta.

**Lección.** Un monitor que depende de lo que monitoriza no es un monitor.
Y "funciona" y "funciona después de un reinicio inesperado" son dos
estados distintos: el segundo hay que probarlo a propósito.

---

## 4. AdGuard guardaba sus datos en `/path/to/your/conf`

**Síntoma.** Ninguno. Todo funcionaba. La configuración de AdGuard
simplemente no estaba donde se suponía.

**Causa.** El `docker-compose.yml` se copió de un ejemplo y nunca se
editaron las rutas de los volúmenes:

```yaml
volumes:
  - /path/to/your/work:/opt/adguardhome/work
  - /path/to/your/conf:/opt/adguardhome/conf
```

Docker crea las rutas de un *bind mount* si no existen. Así que creó, de
verdad, un directorio `/path/to/your/` en la raíz del sistema de ficheros,
y ahí llevaba meses viviendo la configuración. Los directorios que sí se
habían preparado a mano estaban vacíos.

**Solución.** Rutas relativas al directorio del compose (`./conf`,
`./work`). El compose de este repositorio ya lleva la corrección;
**aplicarla en la máquina está pendiente**, porque mover los datos implica
recrear el contenedor y dejar sin DNS a la casa durante unos segundos.

**Lección.** Que algo funcione no significa que esté como uno cree. Un
respaldo de la carpeta "correcta" habría copiado un directorio vacío y
nadie se habría enterado hasta el día de restaurar.

---

## 5. La bóveda estaba accesible en HTTP plano desde toda la red local

**Síntoma.** Ninguno. Vaultwarden se usaba por HTTPS a través del tailnet
y todo parecía correcto.

**Causa.** El mapeo por defecto `ports: - "8080:80"` publica en
`0.0.0.0`. Comprobado desde otra máquina de la LAN:

```
http://192.168.1.X:8080/  ->  HTTP 200
```

Cualquiera en la red —la wifi de invitados incluida— llegaba a la bóveda
sin cifrar, saltándose Tailscale por completo, con las credenciales
viajando en claro.

**Solución.** `ports: - "127.0.0.1:8080:80"`. `tailscale serve` ya
proxeaba a `127.0.0.1:8080`, así que por el tailnet no cambió nada.

**Lección.** `"8080:80"` significa `"0.0.0.0:8080:80"`. El valor por
defecto es el inseguro, y no da ninguna señal de serlo. Cuando se pone un
túnel delante de un servicio, hay que verificar que el camino viejo se ha
cerrado — el túnel no cierra nada por sí solo.

---

## 6. El script de copias podía borrar las copias buenas

**Síntoma.** Ninguno todavía. Salió en una revisión.

**Causa.** El script no tenía `set -e`. Si el volcado de SQLite fallaba
—disco lleno, base bloqueada—, el script continuaba, empaquetaba un
directorio vacío, subía ese tar (109 bytes, perfectamente válido) y a
continuación ejecutaba la rotación:

```bash
rclone delete "$REMOTE/" --min-age 7d
```

Siete noches fallando en silencio y no queda ni una copia útil. En Drive
todo parecería normal: siete ficheros, uno por día.

**Solución.** `set -euo pipefail`, verificación del volcado con
`PRAGMA integrity_check`, comprobación de tamaño mínimo antes de subir, y
la rotación **solo** después de una subida correcta.

**Lección.** Un script de copias sin `set -e` no hace copias, hace
ficheros. Y cualquier rotación automática es un borrado automático: hay
que ganarse el derecho a ejecutarla verificando primero lo que se acaba de
escribir.

---

## 7. Copiar `db.sqlite3` habría perdido datos

**Causa.** SQLite en modo WAL escribe en `db.sqlite3-wal` y solo consolida
en el fichero principal al hacer checkpoint. En una comprobación real, el
fichero principal llevaba 17 horas sin tocarse mientras el WAL acumulaba
103 KB de datos reales. Un `cp db.sqlite3` habría producido una copia que
abre bien, pasa `integrity_check` y **le faltan las últimas horas**.

**Solución.** Volcado por la API de respaldo de SQLite, que consolida el
WAL:

```bash
sqlite3 "$VW_DATA/db.sqlite3" ".backup '$STAGE/db.sqlite3'"
```

Verificado: el volcado en caliente traía 85 ítems, incluido uno creado
minutos antes que solo existía en el WAL.

**Lección.** El peor tipo de copia rota es la que se restaura sin error.

---

## 8. Certificados generados a mano que no usaba nadie

**Síntoma.** Ninguno. Un directorio `ssl/` con un `.crt` y un `.key`
válidos junto al compose de Vaultwarden.

**Causa.** Un intento inicial de terminar TLS en el propio servicio:
`sudo tailscale cert <host>.<tailnet>.ts.net` y guardar los ficheros. El
enfoque se abandonó a favor de `tailscale serve`, pero los ficheros se
quedaron. Nadie los montaba: el compose solo monta `vw-data`, no había
ninguna variable TLS y no hay proxy inverso en la máquina.

**Solución.** Borrarlos.

**Lección.** Restos inofensivos hoy, trampa mañana: caducaban a los 90
días y nada los renovaba. Dentro de un año alguien —yo— los habría
encontrado y dado por buenos. Lo que no se usa se borra, no se deja "por
si acaso".

---

## 9. Tailscale se llevó por delante la resolución DNS del host

**Síntoma.** El host dejó de resolver nombres externos: `ping` por IP
funcionaba y `getent hosts` no devolvía nada. El bot de Telegram murió con
"Temporary failure in name resolution" y estuvo caído varios días sin que
nadie se enterase — precisamente porque el bot es quien avisa.

**Causa aparente, y por qué era una pista falsa.** `/etc/resolv.conf` era un
fichero regular escrito por tailscaled apuntando solo a `100.100.100.100`,
en lugar del symlink a `/run/systemd/resolve/stub-resolv.conf`. La
corrección obvia —borrar el fichero, rehacer el symlink, reiniciar
tailscaled— **funciona y no sobrevive**. Se aplicó tres veces y las tres
volvió al estado roto. La segunda hipótesis, que systemd-resolved no
estuviera activo o habilitado, también era falsa: estaba `enabled` y
`active` las tres veces.

**Causa real.** Una cadena de tres eslabones que solo se ve entera mirando
el log de tailscaled:

```
dns: resolvedIsActuallyResolver error: resolv.conf doesn't point to
     systemd-resolved; points to [1.1.1.1 8.8.8.8 1.0.0.1]
dns: [resolved-ping=yes rc=resolved resolved=not-in-use ret=direct]
dns: using "direct" mode
```

`resolved-ping=yes` es la clave: tailscaled **sí** hablaba con resolved. No
era un problema de arranque ni de orden de servicios. Lo que fallaba era el
contenido del fichero, y el motivo estaba tres capas más abajo:

1. AdGuard Home corre en `network_mode: host` con `bind_hosts: 0.0.0.0`. El
   comodín no ocupa "la IP del servidor": ocupa **todas** las direcciones
   del puerto 53, `127.0.0.53` incluida.
2. Por eso existía `/etc/systemd/resolved.conf.d/adguard.conf` con
   `DNSStubListener=no`, puesto a propósito meses antes para que AdGuard
   pudiera quedarse el 53. Sin stub, nadie escucha en `127.0.0.53`.
3. Con el stub desactivado, systemd-resolved convierte `stub-resolv.conf` en
   un **symlink a `resolv.conf`**, el fichero de upstreams. Eso es
   comportamiento documentado, no corrupción. Resultado: rehacer el symlink
   dejaba a `/etc/resolv.conf` apuntando a `1.1.1.1 8.8.8.8 1.0.0.1`, jamás
   a `127.0.0.53`.

tailscaled comprueba exactamente eso para decidir si resolved está en uso.
Como nunca lo estaba, se declaraba dueño del fichero y volvía a modo
directo. **Determinista, no intermitente**: el arreglo manual no podía
funcionar ninguna de las tres veces.

Dicho de otro modo: dos requisitos incompatibles conviviendo sin que nadie
lo hubiera notado. AdGuard en modo host necesitaba el 53 entero; la
integración tailscaled↔resolved necesitaba `127.0.0.53` libre.

**Solución.** Acotar AdGuard y devolverle el stub a resolved. El orden
importa: AdGuard tiene que soltar el 53 **antes** de que resolved intente
levantar el stub, y `/etc/resolv.conf` tiene que ser ya el symlink correcto
**antes** de reiniciar tailscaled, o vuelve a modo directo y lo sobrescribe.

```bash
cd /home/server/adguard && docker compose stop        # 1. soltar el 53
sudo sed -i 's/^    - 0\.0\.0\.0$/    - 192.168.1.50/' \
     /path/to/your/conf/AdGuardHome.yaml               # 2. acotar el bind
sudo mv /etc/systemd/resolved.conf.d/adguard.conf \
        /etc/systemd/resolved.conf.d/adguard.conf.bak  # 3. devolver el stub
docker compose start                                   # 4. AdGuard en .50
sudo systemctl restart systemd-resolved                # 5. stub en .53
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf   # 6.
sudo systemctl restart tailscaled                      # 7. y solo ahora
```

Se para con AdGuard detenido, no reiniciado, porque AdGuard reescribe su
propio `AdGuardHome.yaml` al apagarse y se llevaría por delante la edición.

El resultado se ve en el mismo log, con el antes y el después:

```
13:14:36  resolved=not-in-use                     ret=direct            -> "direct" mode
13:29:43  resolved=file  resolv-conf-mode=stub    ret=systemd-resolved  -> "systemd-resolved" mode
```

**Verificación.** Que `resolvectl status` diga `stub` no basta; lo que hay
que comprobar es que el host y la LAN resuelven por caminos distintos:

```bash
dig +short @192.168.1.50 doubleclick.net   # 0.0.0.0  -> la LAN pasa por el filtro
resolvectl query doubleclick.net           # IP real  -> el host no
resolvectl status tailscale0               # 100.100.100.100 solo para tail587adf.ts.net
```

**Daño colateral: los contenedores se quedaron sin DNS.** El arreglo dejó al
host perfecto y rompió a los siete contenedores en marcha, que es un fallo
que no aparece en ninguna de las verificaciones de DNS del host.

Los contenedores en redes de usuario resuelven por el DNS embebido de Docker
(`127.0.0.11`), que reenvía al resolutor que el host tenía **en el momento de
crear el contenedor** — `100.100.100.100`. Al pasar tailscaled a modo
`systemd-resolved`, deja de configurar upstreams propios: resolved se encarga
del reparto. Consecuencia, comprobada con una consulta cruda:

```
100.100.100.100 -> rcode 2 (SERVFAIL)
tailscaled: dns: resolver: forward: no upstream resolvers set, returning SERVFAIL
```

Desde dentro, `EAI_AGAIN` en todo. AdGuard no se enteró porque resuelve por
sus propios upstreams DoH con `bootstrap_dns` en IP directa, así que la casa
siguió navegando mientras los servicios del servidor no resolvían nada.

**Se arregla reiniciando los contenedores**: al arrancar releen la
configuración y Docker, al ver que el `resolv.conf` del host solo tiene
loopback, sustituye por sus resolutores por defecto.

```bash
docker restart combina-api opengym-api opengym-web server-api-1
```

Para que no dependa de ese automatismo, lo explícito es fijarlo en
`/etc/docker/daemon.json` — pendiente:

```json
{ "dns": ["1.1.1.1", "8.8.8.8"] }
```

**Lecciones.** Cuatro, y la última es la que costó dinero.

*Un arreglo que hay que repetir no es un arreglo.* La primera vez parece
mala suerte; la tercera es un diagnóstico incompleto. Que el síntoma
desaparezca al aplicar algo no demuestra que la causa fuera esa.

*El comodín no es "todas las interfaces", es también todo el loopback.*
`0.0.0.0` en un contenedor en modo host se queda con `127.0.0.53` y
`127.0.0.54`, no solo con la IP de LAN. Un servicio de DNS en modo host y
systemd-resolved no caben en la misma máquina sin acotar el bind.

*Arreglar el DNS del host no arregla el DNS de los contenedores, y puede
romperlo.* Son dos resolutores distintos y las comprobaciones del host pasan
las siete mientras dentro no resuelve nada. Después de tocar `resolv.conf`
hay que probar **desde dentro de un contenedor**, no solo con `getent` en el
host.

*El monitor no puede ser lo único que vigila.* El bot detecta que se caen
los demás; cuando se cae él, no lo detecta nadie. Necesita un vigilante
externo a la máquina — un latido saliente hacia un servicio de terceros
sirve, y no abre ningún puerto.

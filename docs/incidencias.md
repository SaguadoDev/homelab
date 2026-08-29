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

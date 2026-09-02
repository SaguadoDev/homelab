# Bot de monitorización

Bot de Telegram que vigila el servidor y avisa cuando algo se sale de
madre. Es la única vía de observabilidad del montaje: no hay Prometheus
ni Grafana porque para un host y cuatro contenedores el coste de operar
esa pila supera con creces lo que aporta.

## Qué hace

Dos cosas a la vez, en el mismo proceso:

- **Responde a comandos.** Menú con botones inline sobre `python-telegram-bot`.
- **Vigila en segundo plano.** Cada `INTERVALO_MONITORIZACION` segundos
  muestrea CPU, RAM, disco, temperatura y el estado de cada servicio, y
  manda un aviso cuando algo cruza su umbral.

## Comandos

| Comando | Qué devuelve |
|---|---|
| `/estado` | CPU, RAM, disco y temperatura, con barras de progreso |
| `/servicios` | AdGuard, Vaultwarden, Vault App, openGym, Armario y Tailscale |
| `/uptime` | Tiempo activo del sistema |
| `/red` | IP local y tráfico acumulado |
| `/procesos` | Top 5 por CPU |
| `/docker` | Todos los contenedores y su estado |
| `/ping` | Conectividad y latencia hacia el exterior |
| `/alertas` | Activar o silenciar los avisos automáticos |
| `/help` | El menú |

## Diseño

**Cooldown por causa.** Cada tipo de alerta lleva su propia marca de
tiempo. Un disco al 91% dispara un aviso y se calla 15 minutos, en vez de
generar uno por minuto hasta que alguien lo arregle. Es la diferencia
entre un monitor que se lee y uno que se silencia.

**Chat único autorizado.** El decorador `@solo_autorizado` compara el
`chat_id` de cada mensaje con el configurado y registra los intentos
rechazados. El bot ejecuta `docker inspect` y lee el estado del host: sin
lista blanca, cualquiera que diera con el bot tendría un panel de tu
servidor.

**Sin cliente de Docker.** Consulta a través de `subprocess` llamando al
binario `docker`, con `timeout` en todas las llamadas. Una dependencia
menos, y un demonio Docker colgado devuelve "Timeout ⚠️" en lugar de
bloquear el bot entero.

**Estado de Vault App compuesto.** No basta con que los dos contenedores
corran: se lee además el `health` de la API para distinguir "arrancando"
de "corriendo pero sin responder", y se dice cuál de las dos piezas ha
caído ("DB caída" frente a "API caída").

**Armario tiene un estado propio para el fallo silencioso.** Su
`healthcheck` llama a un `/health` que comprueba la base de datos, no solo
que el proceso responde, así que se distingue `Sin base de datos 🟡` de
`Detenido 🔴` y los dos alertan. Es el caso que un `200 OK` a secas se
traga: el contenedor sigue vivo, la aplicación del móvil sigue funcionando
en local, y lo único que pasa es que deja de sincronizar — en silencio y
durante días, si nadie mira. No se comprueba su Postgres porque es el
compartido, que ya vigila el estado de Vault App: duplicarlo duplicaría la
alerta cuando lo que falla es la base y no el servicio.

## Instalación

```bash
cd /home/homelab/bot
python3 -m venv venv
./venv/bin/pip install -r requirements.txt
cp .env.example .env && $EDITOR .env

sudo cp ../systemd/homelab-bot.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now homelab-bot
```

## Deuda conocida

- **No hay error handler registrado.** Cuando la API de Telegram devuelve
  un 502, `python-telegram-bot` reintenta solo, pero antes vuelca una
  traza completa al log. Funciona; ensucia. Falta un
  `app.add_error_handler(...)`.
- **`BadRequest: Message is not modified`.** Pulsar dos veces el mismo
  botón inline intenta reeditar el mensaje con contenido idéntico y
  Telegram lo rechaza. Hay que capturarlo y descartarlo.
- **Sin persistencia.** Los cooldowns viven en memoria: al reiniciar el
  servicio se olvidan y puede repetirse un aviso reciente.

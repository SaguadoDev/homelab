import json
import os
import subprocess
import time
import urllib.request
from datetime import datetime, timezone

# Las cinco copias nocturnas en Drive y a qué hora deberían estar subidas.
# Las horas son las de docs/backups.md; el umbral de 30 h deja margen a un
# día entero de retraso (un corte de luz a las 03:00) sin gritar, pero grita
# antes de que la rotación a 7 días empiece a comerse copias buenas.
COPIAS = (
    ("Vaultwarden", "gdrive:Vaultwarden_Backups", "vaultwarden_"),
    ("Vault App",   "gdrive:Vault_Backups",       "vault_"),
    ("openGym",     "gdrive:openGym_Backups",     "opengym_"),
    ("Combina",     "gdrive:Armario_Backups",     "armario_"),
    ("Sistema",     "gdrive:Sistema_Backups",     "sistema_"),
)
COPIAS_HORAS_MAX = 30


def comprobar_adguard():
    """Comprueba si el contenedor de AdGuard Home está corriendo."""
    try:
        estado = subprocess.check_output(
            ['docker', 'inspect', '-f', '{{.State.Running}}', 'adguardhome'],
            stderr=subprocess.STDOUT, timeout=10
        ).decode('utf-8').strip()
        return "Activo 🟢" if estado == 'true' else "Detenido 🔴"
    except subprocess.TimeoutExpired:
        return "Timeout ⚠️"
    except Exception:
        return "Error / Inaccesible ⚠️"


def comprobar_vaultwarden():
    """Comprueba si el contenedor de Vaultwarden está corriendo."""
    try:
        estado = subprocess.check_output(
            ['docker', 'inspect', '-f', '{{.State.Running}}', 'vaultwarden'],
            stderr=subprocess.STDOUT, timeout=10
        ).decode('utf-8').strip()
        return "Activo 🟢" if estado == 'true' else "Detenido 🔴"
    except subprocess.TimeoutExpired:
        return "Timeout ⚠️"
    except Exception:
        return "Error / Inaccesible ⚠️"


def comprobar_vault_app():
    """Comprueba si los contenedores de Vault App (API + Postgres) están corriendo."""
    resultados = {}
    for nombre in ('server-api-1', 'server-postgres-1'):
        try:
            estado = subprocess.check_output(
                ['docker', 'inspect', '-f', '{{.State.Running}}', nombre],
                stderr=subprocess.STDOUT, timeout=10
            ).decode('utf-8').strip()
            resultados[nombre] = estado == 'true'
        except subprocess.TimeoutExpired:
            return "Timeout ⚠️"
        except Exception:
            resultados[nombre] = False

    if all(resultados.values()):
        # Verificar que la API responde al health check
        try:
            health = subprocess.check_output(
                ['docker', 'inspect', '-f', '{{.State.Health.Status}}', 'server-api-1'],
                stderr=subprocess.STDOUT, timeout=10
            ).decode('utf-8').strip()
            if health == 'healthy':
                return "Activo 🟢"
            elif health == 'starting':
                return "Iniciando 🟡"
            else:
                return "API sin responder 🟡"
        except Exception:
            return "Activo 🟢"  # Contenedores corren aunque no podamos leer health
    elif resultados.get('server-api-1'):
        return "DB caída 🔴"
    elif resultados.get('server-postgres-1'):
        return "API caída 🔴"
    else:
        return "Detenido 🔴"


def comprobar_opengym():
    """Comprueba si los contenedores de openGym (web + api) están corriendo.

    El contenedor `opengym-media` queda fuera a propósito: es una tarea de
    un solo uso que descarga las imágenes de los ejercicios y termina, así
    que su estado normal es "Exited".
    """
    resultados = {}
    for nombre in ('opengym-web', 'opengym-api'):
        try:
            estado = subprocess.check_output(
                ['docker', 'inspect', '-f', '{{.State.Running}}', nombre],
                stderr=subprocess.STDOUT, timeout=10
            ).decode('utf-8').strip()
            resultados[nombre] = estado == 'true'
        except subprocess.TimeoutExpired:
            return "Timeout ⚠️"
        except Exception:
            resultados[nombre] = False

    if all(resultados.values()):
        # Ambas imágenes traen HEALTHCHECK propio: web sondea su nginx y api
        # su /api/health. Si la api está sana, el camino entero lo está.
        try:
            health = subprocess.check_output(
                ['docker', 'inspect', '-f', '{{.State.Health.Status}}', 'opengym-api'],
                stderr=subprocess.STDOUT, timeout=10
            ).decode('utf-8').strip()
            if health == 'healthy':
                return "Activo 🟢"
            elif health == 'starting':
                return "Iniciando 🟡"
            else:
                return "API sin responder 🟡"
        except Exception:
            return "Activo 🟢"  # Contenedores corren aunque no podamos leer health
    elif resultados.get('opengym-web'):
        return "API caída 🔴"
    elif resultados.get('opengym-api'):
        return "Web caída 🔴"
    else:
        return "Detenido 🔴"


def comprobar_combina():
    """Comprueba el contenedor de Combina (la API del armario digital).

    Postgres no se mira aquí: es la instancia compartida que ya vigila
    `comprobar_vault_app()`, y duplicar la comprobación duplicaría la alerta
    cuando lo que falla es la base y no este servicio.

    El healthcheck de la imagen llama a /health, que **comprueba la base de
    datos, no solo que el proceso responde**: un contenedor vivo que no puede
    escribir es justo el fallo que hay que detectar, y el que un "200 OK" a
    secas se traga.
    """
    try:
        estado = subprocess.check_output(
            ['docker', 'inspect', '-f', '{{.State.Running}}', 'combina-api'],
            stderr=subprocess.STDOUT, timeout=10
        ).decode('utf-8').strip()
    except subprocess.TimeoutExpired:
        return "Timeout ⚠️"
    except Exception:
        return "Detenido 🔴"

    if estado != 'true':
        return "Detenido 🔴"

    try:
        health = subprocess.check_output(
            ['docker', 'inspect', '-f', '{{.State.Health.Status}}', 'combina-api'],
            stderr=subprocess.STDOUT, timeout=10
        ).decode('utf-8').strip()
        if health == 'healthy':
            return "Activo 🟢"
        elif health == 'starting':
            return "Iniciando 🟡"
        else:
            # El contenedor corre pero /health no responde o dice que la BD no
            # está: la app del móvil sigue funcionando en local, pero deja de
            # sincronizar y nadie se entera sin este aviso.
            return "Sin base de datos 🟡"
    except Exception:
        return "Activo 🟢"  # El contenedor corre aunque no podamos leer health


# Sin respuesta de ninguna fuente ADS-B durante más de esto, hexwatch alerta.
# Por debajo es ruido normal: tras un 429 el backoff llega a 10 min por
# fuente. Se mira la ANTIGÜEDAD, no un recuento, así que vale igual para una
# aeronave que para diez.
HEXWATCH_SIN_DATOS_MAX = 1800
# La base de hexwatch, para ver que de verdad escribe (ver comprobar_hexwatch).
# Sin la variable en .env, esa parte de la comprobación se salta.
HEXWATCH_DB = os.getenv('HEXWATCH_DB')


def comprobar_hexwatch():
    """Comprueba hexwatch, el seguimiento de vuelos, que corre en systemd.

    No es un contenedor: se pregunta a systemd y después a su propia API por
    loopback, que es lo mismo que ve la app a través de `tailscale serve`.
    Una unidad `active` con la API colgada seguiría pareciendo sana.

    Lo que aquí no delata nadie es el silencio: un demonio vivo que no
    recibe datos (sin red, con las dos APIs en backoff). No hay usuario que
    entre y note que no va, así que se mira la edad del último sondeo bueno
    (`data_age_s`). Un rato sin datos es normal y se pinta en amarillo sin
    alertar; pasado `HEXWATCH_SIN_DATOS_MAX`, rojo y alerta. Y con datos
    entrando, que la base se siga escribiendo.
    """
    try:
        # `is-active` sale con código 3 si la unidad no está activa: `run` y
        # mirar la salida, no `check_output`.
        activo = subprocess.run(
            ['systemctl', 'is-active', 'hexwatch'],
            capture_output=True, text=True, timeout=10
        ).stdout.strip()
    except subprocess.TimeoutExpired:
        return "Timeout ⚠️"
    except Exception:
        return "Error / Inaccesible ⚠️"

    if activo == 'failed':
        return "Fallido 🔴"
    if activo != 'active':
        return f"Detenido 🔴 ({activo})"

    try:
        with urllib.request.urlopen('http://127.0.0.1:3002/status', timeout=5) as r:
            estado = json.load(r)
    except Exception:
        return "API sin responder 🔴"

    if estado.get('data_ok'):
        # Recibe datos, pero ¿los guarda? Un fallo de escritura (disco lleno,
        # permisos) se registra y el demonio sigue vivo y sirviendo /status.
        # Cada sondeo escribe en la base, así que basta la fecha de
        # modificación: sin abrir la SQLite ni competir con su WAL.
        if HEXWATCH_DB:
            try:
                escrito = max(os.path.getmtime(f) for f in
                              (HEXWATCH_DB, HEXWATCH_DB + '-wal') if os.path.exists(f))
            except ValueError:
                return "Sin base 🔴"
            except Exception:
                return "Error al mirar la base ⚠️"
            quieta = time.time() - escrito
            if quieta > HEXWATCH_SIN_DATOS_MAX:
                return f"No guarda en disco desde hace {int(quieta) // 60} min 🔴"
        return "Activo 🟢"
    edad = estado.get('data_age_s')
    if edad is None:
        return "Sin datos ADS-B todavía 🟡"
    texto = f"{edad // 60} min" if edad < 3600 else f"{edad // 3600} h"
    if edad > HEXWATCH_SIN_DATOS_MAX:
        return f"Sin datos ADS-B hace {texto} 🔴"
    return f"Sin datos ADS-B hace {texto} 🟡"


def comprobar_tailscale():
    """Comprueba el estado de Tailscale y si actúa como Exit Node."""
    try:
        estado = subprocess.check_output(
            ['tailscale', 'status'],
            timeout=5, stderr=subprocess.STDOUT
        ).decode('utf-8').lower()

        if "logged out" in estado or "failed" in estado or "stopped" in estado:
            return "Desconectado 🔴"

        prefs = subprocess.check_output(
            ['tailscale', 'debug', 'prefs'],
            timeout=5, stderr=subprocess.STDOUT
        ).decode('utf-8').lower()

        if "0.0.0.0/0" in prefs or "advertiseexitnode: true" in prefs:
            return "Activo 🟢"
        else:
            return "Activo sin Exit Node 🟡"

    except subprocess.TimeoutExpired:
        return "Timeout ⚠️"
    except Exception:
        return "Desconectado 🔴"


def comprobar_docker_contenedores():
    """Lista todos los contenedores Docker con su estado.

    Devuelve una lista de dicts o None si no se puede conectar.
    """
    try:
        salida = subprocess.check_output(
            ['docker', 'ps', '-a', '--format', '{{.Names}}|{{.Status}}|{{.State}}'],
            stderr=subprocess.STDOUT, timeout=10
        ).decode('utf-8').strip()

        contenedores = []
        for linea in salida.split('\n'):
            if not linea.strip():
                continue
            partes = linea.split('|')
            if len(partes) >= 3:
                nombre, status, state = partes[0], partes[1], partes[2]
                # Tres estados, no dos. Un contenedor de tarea puntual —el que
                # descarga la media de openGym, por ejemplo— hace su trabajo y
                # sale con código 0: su estado sano es "Exited (0)". Pintarlo
                # igual que uno que se ha caído es una alarma que miente, y a
                # base de rojos que no significan nada se acaba dejando de
                # mirar los que sí.
                #
                # Esto solo afecta al listado informativo. Las alertas van por
                # las comprobaciones dedicadas de cada servicio, que siguen
                # exigiendo "running" y no miran esta función.
                if state == "running":
                    icono = "🟢"
                elif "Exited (0)" in status:
                    icono = "⚪"
                else:
                    icono = "🔴"
                contenedores.append({
                    'nombre': nombre,
                    'status': status,
                    'state': state,
                    'icono': icono,
                })
        return contenedores
    except subprocess.TimeoutExpired:
        return None
    except Exception:
        return None


def comprobar_conectividad(host="8.8.8.8", count=1):
    """Hace ping a un host externo y devuelve latencia.

    Returns:
        dict con claves 'ok' (bool) y 'ms' (float o None).
    """
    try:
        resultado = subprocess.run(
            ['ping', '-c', str(count), '-W', '3', host],
            capture_output=True, text=True, timeout=10
        )
        if resultado.returncode == 0:
            for line in resultado.stdout.split('\n'):
                if 'avg' in line:
                    # rtt min/avg/max/mdev = 1.234/5.678/9.012/1.234 ms
                    tiempos = line.split('=')[1].strip().split('/')
                    return {'ok': True, 'ms': float(tiempos[1])}
            return {'ok': True, 'ms': None}
        return {'ok': False, 'ms': None}
    except Exception:
        return {'ok': False, 'ms': None}


def comprobar_copias():
    """Edad y tamaño de la copia más reciente de cada carpeta de Drive.

    Corre como el usuario del bot, cuya rclone.conf es la misma que usan los
    scripts. Devuelve una lista de dicts con 'nombre', 'ok', 'horas',
    'fichero', 'kb' y 'detalle'; o None si rclone no está o no llega a Drive.

    Solo mira lo que hay en el remoto: no distingue "el cron no corrió" de
    "el script falló" — para eso están los logs. Lo que sí detecta es lo que
    nadie miraría: una copia que dejó de llegar hace días y una rotación que
    sigue borrando las viejas mientras tanto.
    """
    resultados = []
    for nombre, remoto, prefijo in COPIAS:
        try:
            salida = subprocess.check_output(
                ['rclone', 'lsl', remoto + '/', '--max-depth', '1',
                 '--include', prefijo + '*'],
                stderr=subprocess.STDOUT, timeout=60,
            ).decode('utf-8')
        except subprocess.CalledProcessError:
            # La carpeta no existe (todavía) o Drive no la deja listar: es un
            # problema de ESA copia, no de rclone.
            salida = ''
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return None
        except Exception:
            return None

        # rclone lsl: "   tamaño fecha hora.fracción nombre"
        ultimo = None
        for linea in salida.splitlines():
            partes = linea.split(None, 3)
            if len(partes) < 4:
                continue
            kb = int(partes[0]) // 1024
            # rclone lsl imprime la hora en la zona local del sistema.
            fecha = datetime.fromisoformat(f"{partes[1]}T{partes[2][:19]}").astimezone()
            if ultimo is None or fecha > ultimo[0]:
                ultimo = (fecha, kb, partes[3])

        if ultimo is None:
            resultados.append({'nombre': nombre, 'ok': False, 'horas': None,
                               'fichero': None, 'kb': 0, 'detalle': 'sin copias 🔴'})
            continue

        horas = (datetime.now(timezone.utc) - ultimo[0]).total_seconds() / 3600
        ok = horas <= COPIAS_HORAS_MAX and ultimo[1] > 0
        if not ok:
            detalle = f"hace {horas:.0f} h 🔴"
        else:
            detalle = f"hace {horas:.0f} h, {ultimo[1]} KB 🟢"
        resultados.append({'nombre': nombre, 'ok': ok, 'horas': horas,
                           'fichero': ultimo[2], 'kb': ultimo[1], 'detalle': detalle})
    return resultados


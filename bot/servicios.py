import subprocess


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

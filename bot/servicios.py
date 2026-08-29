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
    for nombre in ('vault-api', 'vault-postgres'):
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
                ['docker', 'inspect', '-f', '{{.State.Health.Status}}', 'vault-api'],
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
    elif resultados.get('vault-api'):
        return "DB caída 🔴"
    elif resultados.get('vault-postgres'):
        return "API caída 🔴"
    else:
        return "Detenido 🔴"


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
                icono = "🟢" if state == "running" else "🔴"
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

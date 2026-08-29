import psutil
import socket
import time
from datetime import timedelta


def obtener_uso_cpu():
    """Porcentaje de uso de CPU."""
    return psutil.cpu_percent(interval=1)


def obtener_uso_ram():
    """Uso de RAM: porcentaje y GB usados/totales."""
    mem = psutil.virtual_memory()
    return {
        'porcentaje': mem.percent,
        'usado': mem.used / (1e9),
        'total': mem.total / (1e9),
    }


def obtener_uso_disco():
    """Porcentaje de uso de disco (raíz)."""
    return psutil.disk_usage('/').percent


def obtener_disco_detallado():
    """Información detallada del disco en GB."""
    disco = psutil.disk_usage('/')
    return {
        'total': disco.total / (1e9),
        'usado': disco.used / (1e9),
        'libre': disco.free / (1e9),
        'porcentaje': disco.percent,
    }


def obtener_temperatura_cpu():
    """Temperatura de la CPU. Devuelve None si no hay sensor disponible."""
    try:
        temps = psutil.sensors_temperatures()
        if not temps:
            return None

        sensores_cpu = ['k10temp', 'coretemp', 'cpu_thermal']

        for sensor in sensores_cpu:
            if sensor in temps:
                return temps[sensor][0].current

        return None

    except Exception:
        return None


def obtener_uptime():
    """Tiempo activo del sistema en formato legible (ej: '3d 5h 12m')."""
    delta = timedelta(seconds=time.time() - psutil.boot_time())
    dias = delta.days
    horas, resto = divmod(delta.seconds, 3600)
    minutos = resto // 60

    partes = []
    if dias > 0:
        partes.append(f"{dias}d")
    if horas > 0:
        partes.append(f"{horas}h")
    partes.append(f"{minutos}m")
    return " ".join(partes)


def obtener_info_red():
    """IP local y tráfico acumulado de red (GB enviados/recibidos)."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip_local = s.getsockname()[0]
        s.close()
    except Exception:
        ip_local = "No disponible"

    net = psutil.net_io_counters()
    return {
        'ip_local': ip_local,
        'enviados': net.bytes_sent / (1e9),
        'recibidos': net.bytes_recv / (1e9),
    }


def obtener_top_procesos(n=5):
    """Top N procesos ordenados por uso de CPU."""
    procesos = []
    for proc in psutil.process_iter(['pid', 'name', 'cpu_percent', 'memory_percent']):
        try:
            info = proc.info
            if info['cpu_percent'] is not None:
                procesos.append(info)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue

    procesos.sort(key=lambda p: (p['cpu_percent'] or 0), reverse=True)
    return procesos[:n]
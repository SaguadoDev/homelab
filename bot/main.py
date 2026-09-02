import os
import asyncio
import logging
import time
from functools import wraps
from logging.handlers import RotatingFileHandler

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, ContextTypes

import config
import hardware
import servicios

# ──────────────────────────────────────────────
#  LOGGING
# ──────────────────────────────────────────────
os.makedirs(config.LOG_DIR, exist_ok=True)

logger = logging.getLogger('bot')
logger.setLevel(logging.INFO)

_file_handler = RotatingFileHandler(
    config.LOG_FILE, maxBytes=5 * 1024 * 1024, backupCount=3, encoding='utf-8'
)
_file_handler.setFormatter(logging.Formatter(
    '%(asctime)s [%(levelname)s] %(message)s', datefmt='%Y-%m-%d %H:%M:%S'
))
_console_handler = logging.StreamHandler()
_console_handler.setFormatter(logging.Formatter(
    '%(asctime)s [%(levelname)s] %(message)s', datefmt='%H:%M:%S'
))
logger.addHandler(_file_handler)
logger.addHandler(_console_handler)

# ──────────────────────────────────────────────
#  SISTEMA DE COOLDOWN
# ──────────────────────────────────────────────
_ultimo_alerta: dict[str, float] = {}
_alertas_activas: bool = True


def deberia_alertar(clave: str) -> bool:
    """Devuelve True si se puede enviar alerta (respeta cooldown y toggle)."""
    if not _alertas_activas:
        return False
    ahora = time.time()
    if clave in _ultimo_alerta and (ahora - _ultimo_alerta[clave]) < config.COOLDOWN_ALERTAS:
        return False
    _ultimo_alerta[clave] = ahora
    return True


# ──────────────────────────────────────────────
#  CONTROL DE ACCESO
# ──────────────────────────────────────────────
def solo_autorizado(func):
    """Decorador que restringe comandos al CHAT_ID configurado."""
    @wraps(func)
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE):
        chat_id = str(update.effective_chat.id)
        if chat_id != config.TELEGRAM_CHAT_ID:
            logger.warning(f"Acceso denegado — chat_id: {chat_id}")
            await update.message.reply_text("⛔ No autorizado.")
            return
        return await func(update, context)
    return wrapper


# ──────────────────────────────────────────────
#  UTILIDADES
# ──────────────────────────────────────────────
def _barra_progreso(porcentaje: float, longitud: int = 15) -> str:
    """Genera una barra visual con emoji de color según el nivel."""
    llenos = int(porcentaje / 100 * longitud)
    vacios = longitud - llenos
    if porcentaje >= 90:
        emoji = "🔴"
    elif porcentaje >= 70:
        emoji = "🟡"
    else:
        emoji = "🟢"
    return f"{emoji} {'█' * llenos}{'░' * vacios}"


# ──────────────────────────────────────────────
#  COMANDOS
# ──────────────────────────────────────────────

@solo_autorizado
async def cmd_help(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Menú principal con botones inline."""
    teclado = [
        [
            InlineKeyboardButton("📊 Estado", callback_data="estado"),
            InlineKeyboardButton("🌐 Servicios", callback_data="servicios"),
        ],
        [
            InlineKeyboardButton("⏱ Uptime", callback_data="uptime"),
            InlineKeyboardButton("🔌 Red", callback_data="red"),
        ],
        [
            InlineKeyboardButton("📋 Procesos", callback_data="procesos"),
            InlineKeyboardButton("🐳 Docker", callback_data="docker"),
        ],
        [
            InlineKeyboardButton("📡 Ping", callback_data="ping"),
            InlineKeyboardButton("🔔 Alertas", callback_data="alertas"),
        ],
    ]
    mensaje = (
        "🤖 *Panel de Control*\n\n"
        "Usa los botones o escribe un comando:\n\n"
        "📊 `/estado` — Recursos del sistema\n"
        "🌐 `/servicios` — Estado de servicios\n"
        "⏱ `/uptime` — Tiempo activo\n"
        "🔌 `/red` — Info de red\n"
        "📋 `/procesos` — Top procesos\n"
        "🐳 `/docker` — Contenedores Docker\n"
        "📡 `/ping` — Conectividad\n"
        "🔔 `/alertas` — Gestionar alertas\n"
        "❓ `/help` — Este menú"
    )
    await update.message.reply_text(
        mensaje, parse_mode='Markdown',
        reply_markup=InlineKeyboardMarkup(teclado),
    )


@solo_autorizado
async def cmd_estado(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Estado completo de recursos del servidor."""
    texto, teclado = _generar_estado()
    await update.message.reply_text(
        texto, parse_mode='Markdown',
        reply_markup=InlineKeyboardMarkup(teclado),
    )


@solo_autorizado
async def cmd_servicios(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Estado de AdGuard, Tailscale y conectividad."""
    texto, teclado = _generar_servicios()
    await update.message.reply_text(
        texto, parse_mode='Markdown',
        reply_markup=InlineKeyboardMarkup(teclado),
    )


@solo_autorizado
async def cmd_uptime(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Tiempo activo del servidor."""
    uptime = hardware.obtener_uptime()
    await update.message.reply_text(f"⏱ *Uptime:* `{uptime}`", parse_mode='Markdown')


@solo_autorizado
async def cmd_red(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Información de red: IP local y tráfico."""
    texto = _generar_red()
    await update.message.reply_text(texto, parse_mode='Markdown')


@solo_autorizado
async def cmd_procesos(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Top 5 procesos por uso de CPU."""
    texto = _generar_procesos()
    await update.message.reply_text(texto, parse_mode='Markdown')


@solo_autorizado
async def cmd_docker(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Estado de todos los contenedores Docker."""
    texto = _generar_docker()
    await update.message.reply_text(texto, parse_mode='Markdown')


@solo_autorizado
async def cmd_ping(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Verificación de conectividad externa."""
    texto = _generar_ping()
    await update.message.reply_text(texto, parse_mode='Markdown')


@solo_autorizado
async def cmd_alertas(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Ver o cambiar configuración de alertas (/alertas on | off)."""
    global _alertas_activas

    args = context.args
    if args and args[0].lower() in ('on', 'off'):
        _alertas_activas = args[0].lower() == 'on'
        estado = "activadas ✅" if _alertas_activas else "desactivadas ❌"
        logger.info(f"Alertas {'activadas' if _alertas_activas else 'desactivadas'} por el usuario")
        await update.message.reply_text(f"🔔 Alertas {estado}")
        return

    texto, teclado = _generar_alertas()
    await update.message.reply_text(
        texto, parse_mode='Markdown',
        reply_markup=InlineKeyboardMarkup(teclado),
    )


# ──────────────────────────────────────────────
#  GENERADORES DE CONTENIDO (compartidos entre
#  comandos y callbacks inline)
# ──────────────────────────────────────────────

def _generar_estado():
    cpu = hardware.obtener_uso_cpu()
    ram = hardware.obtener_uso_ram()
    disco = hardware.obtener_disco_detallado()
    temp = hardware.obtener_temperatura_cpu()
    uptime = hardware.obtener_uptime()

    temp_str = f"{temp}°C" if temp is not None else "No detectada"

    texto = (
        f"📊 *Estado del Servidor*\n"
        f"⏱ Uptime: `{uptime}`\n\n"
        f"🖥 *CPU:* `{cpu}%`\n{_barra_progreso(cpu)}\n\n"
        f"🧠 *RAM:* `{ram['porcentaje']}%` "
        f"({ram['usado']:.1f}/{ram['total']:.1f} GB)\n"
        f"{_barra_progreso(ram['porcentaje'])}\n\n"
        f"💾 *Disco:* `{disco['porcentaje']}%` "
        f"({disco['usado']:.1f}/{disco['total']:.1f} GB)\n"
        f"{_barra_progreso(disco['porcentaje'])}\n\n"
        f"🌡 *Temp:* `{temp_str}`"
    )
    teclado = [[
        InlineKeyboardButton("🔄 Actualizar", callback_data="estado"),
        InlineKeyboardButton("🌐 Servicios", callback_data="servicios"),
    ]]
    return texto, teclado


def _generar_servicios():
    adguard = servicios.comprobar_adguard()
    vaultwarden = servicios.comprobar_vaultwarden()
    vault_app = servicios.comprobar_vault_app()
    opengym = servicios.comprobar_opengym()
    combina = servicios.comprobar_combina()
    tailscale = servicios.comprobar_tailscale()
    conectividad = servicios.comprobar_conectividad()

    if conectividad['ok'] and conectividad['ms']:
        ping_str = f"{conectividad['ms']:.1f}ms"
    elif conectividad['ok']:
        ping_str = "OK"
    else:
        ping_str = "Sin conexión"

    texto = (
        f"🌐 *Estado de Servicios*\n\n"
        f"• AdGuard Home: {adguard}\n"
        f"• Vaultwarden: {vaultwarden}\n"
        f"• Vault App: {vault_app}\n"
        f"• openGym: {opengym}\n"
        f"• Combina: {combina}\n"
        f"• Tailscale: {tailscale}\n"
        f"• Internet: {'Conectado 🟢' if conectividad['ok'] else 'Desconectado 🔴'} "
        f"(`{ping_str}`)"
    )
    teclado = [[
        InlineKeyboardButton("🔄 Actualizar", callback_data="servicios"),
        InlineKeyboardButton("📊 Estado", callback_data="estado"),
    ]]
    return texto, teclado


def _generar_red():
    red = hardware.obtener_info_red()
    return (
        f"🔌 *Información de Red*\n\n"
        f"• IP Local: `{red['ip_local']}`\n"
        f"• Enviados: `{red['enviados']:.2f} GB`\n"
        f"• Recibidos: `{red['recibidos']:.2f} GB`"
    )


def _generar_procesos():
    procs = hardware.obtener_top_procesos(5)
    if not procs:
        return "⚠️ No se pudieron obtener los procesos."

    lineas = []
    for i, p in enumerate(procs, 1):
        nombre = p['name'][:20]
        lineas.append(
            f"`{i}.` *{nombre}* — CPU: `{p['cpu_percent']:.1f}%` "
            f"| RAM: `{p['memory_percent']:.1f}%`"
        )
    return f"📋 *Top Procesos*\n\n" + "\n".join(lineas)


def _generar_docker():
    contenedores = servicios.comprobar_docker_contenedores()
    if contenedores is None:
        return "⚠️ No se pudo conectar con Docker."
    if not contenedores:
        return "🐳 No hay contenedores."

    lineas = []
    for c in contenedores:
        lineas.append(f"{c['icono']} *{c['nombre']}* — `{c['status']}`")
    return f"🐳 *Contenedores Docker*\n\n" + "\n".join(lineas)


def _generar_ping():
    resultado = servicios.comprobar_conectividad()
    if resultado['ok']:
        ms_str = f" (`{resultado['ms']:.1f}ms`)" if resultado['ms'] else ""
        return f"📡 Conectividad: *OK*{ms_str}"
    return "📡 Conectividad: *Sin conexión* 🔴"


def _generar_alertas():
    estado = "Activadas ✅" if _alertas_activas else "Desactivadas ❌"
    texto = (
        f"🔔 *Configuración de Alertas*\n\n"
        f"• Estado: {estado}\n"
        f"• Umbral CPU: `{config.UMBRAL_CPU}%`\n"
        f"• Umbral RAM: `{config.UMBRAL_RAM}%`\n"
        f"• Umbral Temp: `{config.UMBRAL_TEMP}°C`\n"
        f"• Umbral Disco: `{config.UMBRAL_DISCO}%`\n"
        f"• Cooldown: `{config.COOLDOWN_ALERTAS // 60} min`\n\n"
        f"Usa `/alertas on` o `/alertas off`"
    )
    teclado = [[
        InlineKeyboardButton("✅ Activar", callback_data="alertas_on"),
        InlineKeyboardButton("❌ Desactivar", callback_data="alertas_off"),
    ]]
    return texto, teclado


# ──────────────────────────────────────────────
#  CALLBACKS DE BOTONES INLINE
# ──────────────────────────────────────────────

async def callback_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Router para todos los botones inline."""
    global _alertas_activas

    query = update.callback_query
    chat_id = str(query.message.chat_id)

    if chat_id != config.TELEGRAM_CHAT_ID:
        await query.answer("⛔ No autorizado.", show_alert=True)
        return

    await query.answer()
    data = query.data

    # Mapeo de callbacks a generadores de contenido
    generadores_simples = {
        "uptime": lambda: (f"⏱ *Uptime:* `{hardware.obtener_uptime()}`", None),
        "red": lambda: (_generar_red(), None),
        "procesos": lambda: (_generar_procesos(), None),
        "docker": lambda: (_generar_docker(), None),
        "ping": lambda: (_generar_ping(), None),
    }

    generadores_con_teclado = {
        "estado": _generar_estado,
        "servicios": _generar_servicios,
        "alertas": _generar_alertas,
    }

    if data in generadores_simples:
        texto, teclado = generadores_simples[data]()
        await query.message.edit_text(
            texto, parse_mode='Markdown',
            reply_markup=InlineKeyboardMarkup(teclado) if teclado else None,
        )
    elif data in generadores_con_teclado:
        texto, teclado = generadores_con_teclado[data]()
        await query.message.edit_text(
            texto, parse_mode='Markdown',
            reply_markup=InlineKeyboardMarkup(teclado),
        )
    elif data == "alertas_on":
        _alertas_activas = True
        logger.info("Alertas activadas vía botón")
        await query.message.edit_text("🔔 Alertas *activadas* ✅", parse_mode='Markdown')
    elif data == "alertas_off":
        _alertas_activas = False
        logger.info("Alertas desactivadas vía botón")
        await query.message.edit_text("🔔 Alertas *desactivadas* ❌", parse_mode='Markdown')


# ──────────────────────────────────────────────
#  MONITORIZACIÓN EN SEGUNDO PLANO
# ──────────────────────────────────────────────

async def iniciar_monitorizacion(app):
    """Hook post_init de PTB: notifica arranque y lanza monitorización."""
    # Notificación de arranque (con reintentos por si la red no está lista)
    import psutil as _psutil
    boot_seconds = time.time() - _psutil.boot_time()

    for intento in range(5):
        try:
            uptime = hardware.obtener_uptime()

            if boot_seconds < 300:  # < 5 minutos → probable reinicio tras corte de luz
                texto = (
                    f"🔄 *Bot reiniciado — posible corte de luz*\n\n"
                    f"⏱ Uptime del sistema: `{uptime}`"
                )
            else:
                texto = f"✅ *Bot iniciado correctamente*\n⏱ Uptime: `{uptime}`"

            await app.bot.send_message(
                chat_id=config.TELEGRAM_CHAT_ID,
                text=texto,
                parse_mode='Markdown',
            )
            logger.info("Notificación de arranque enviada")
            break
        except Exception as e:
            logger.warning(f"Notificación de arranque fallida (intento {intento + 1}/5): {e}")
            if intento < 4:
                await asyncio.sleep(10)  # Espera 10s y reintenta
            else:
                logger.error("No se pudo enviar la notificación de arranque tras 5 intentos")

    asyncio.create_task(tarea_monitorizacion(app))
    logger.info("Monitorización en segundo plano iniciada")


async def tarea_monitorizacion(app):
    """Bucle que vigila recursos y servicios, con cooldown anti-spam."""
    while True:
        try:
            cpu = hardware.obtener_uso_cpu()
            ram = hardware.obtener_uso_ram()
            temp = hardware.obtener_temperatura_cpu()
            disco = hardware.obtener_uso_disco()

            # --- Alertas de hardware ---
            if cpu > config.UMBRAL_CPU and deberia_alertar('cpu'):
                await app.bot.send_message(
                    chat_id=config.TELEGRAM_CHAT_ID,
                    text=f"⚠️ *ALERTA CPU*\nUso: `{cpu}%` (umbral: {config.UMBRAL_CPU}%)",
                    parse_mode='Markdown',
                )
                logger.warning(f"Alerta CPU: {cpu}%")

            if ram['porcentaje'] > config.UMBRAL_RAM and deberia_alertar('ram'):
                await app.bot.send_message(
                    chat_id=config.TELEGRAM_CHAT_ID,
                    text=f"⚠️ *ALERTA RAM*\nUso: `{ram['porcentaje']}%` ({ram['usado']:.1f}/{ram['total']:.1f} GB) — umbral: {config.UMBRAL_RAM}%",
                    parse_mode='Markdown',
                )
                logger.warning(f"Alerta RAM: {ram['porcentaje']}%")

            if temp is not None and temp > config.UMBRAL_TEMP and deberia_alertar('temp'):
                await app.bot.send_message(
                    chat_id=config.TELEGRAM_CHAT_ID,
                    text=f"🔥 *ALERTA TEMPERATURA*\nCPU: `{temp}°C` (umbral: {config.UMBRAL_TEMP}°C)",
                    parse_mode='Markdown',
                )
                logger.warning(f"Alerta temperatura: {temp}°C")

            if disco > config.UMBRAL_DISCO and deberia_alertar('disco'):
                await app.bot.send_message(
                    chat_id=config.TELEGRAM_CHAT_ID,
                    text=f"💾 *ALERTA DISCO*\nUso: `{disco}%` (umbral: {config.UMBRAL_DISCO}%)",
                    parse_mode='Markdown',
                )
                logger.warning(f"Alerta disco: {disco}%")

            # --- Alertas de servicios ---
            adguard = servicios.comprobar_adguard()
            if ("Detenido" in adguard or "Error" in adguard) and deberia_alertar('adguard'):
                await app.bot.send_message(
                    chat_id=config.TELEGRAM_CHAT_ID,
                    text=f"🚨 *ALERTA* AdGuard Home ha caído.\nEstado: {adguard}",
                    parse_mode='Markdown',
                )
                logger.warning(f"Alerta AdGuard: {adguard}")

            vaultwarden = servicios.comprobar_vaultwarden()
            if ("Detenido" in vaultwarden or "Error" in vaultwarden) and deberia_alertar('vaultwarden'):
                await app.bot.send_message(
                    chat_id=config.TELEGRAM_CHAT_ID,
                    text=f"🚨 *ALERTA* Vaultwarden ha caído.\nEstado: {vaultwarden}",
                    parse_mode='Markdown',
                )
                logger.warning(f"Alerta Vaultwarden: {vaultwarden}")

            tailscale = servicios.comprobar_tailscale()
            if ("Desconectado" in tailscale or "Error" in tailscale) and deberia_alertar('tailscale'):
                await app.bot.send_message(
                    chat_id=config.TELEGRAM_CHAT_ID,
                    text=f"🚨 *ALERTA* Tailscale ha caído.\nEstado: {tailscale}",
                    parse_mode='Markdown',
                )
                logger.warning(f"Alerta Tailscale: {tailscale}")

            if "sin Exit Node" in tailscale and deberia_alertar('tailscale_exitnode'):
                await app.bot.send_message(
                    chat_id=config.TELEGRAM_CHAT_ID,
                    text=f"⚠️ *ALERTA* Tailscale activo pero *sin Exit Node*.",
                    parse_mode='Markdown',
                )
                logger.warning("Alerta Tailscale: sin Exit Node")

            vault_app = servicios.comprobar_vault_app()
            if any(x in vault_app for x in ("caída", "Detenido", "Error")) and deberia_alertar('vault_app'):
                await app.bot.send_message(
                    chat_id=config.TELEGRAM_CHAT_ID,
                    text=f"🚨 *ALERTA* Vault App tiene problemas.\nEstado: {vault_app}",
                    parse_mode='Markdown',
                )
                logger.warning(f"Alerta Vault App: {vault_app}")

            opengym = servicios.comprobar_opengym()
            if any(x in opengym for x in ("caída", "Detenido", "Error")) and deberia_alertar('opengym'):
                await app.bot.send_message(
                    chat_id=config.TELEGRAM_CHAT_ID,
                    text=f"🚨 *ALERTA* openGym tiene problemas.\nEstado: {opengym}",
                    parse_mode='Markdown',
                )
                logger.warning(f"Alerta openGym: {opengym}")

            # "Sin base de datos" entra a propósito: el contenedor sigue vivo y
            # respondiendo, así que sin esto el fallo pasaría desapercibido
            # mientras el móvil deja de sincronizar en silencio.
            combina = servicios.comprobar_combina()
            if any(x in combina for x in ("Sin base de datos", "Detenido", "Error")) and deberia_alertar('combina'):
                await app.bot.send_message(
                    chat_id=config.TELEGRAM_CHAT_ID,
                    text=f"🚨 *ALERTA* Combina tiene problemas.\nEstado: {combina}",
                    parse_mode='Markdown',
                )
                logger.warning(f"Alerta Combina: {combina}")

        except Exception as e:
            logger.error(f"Error en monitorización: {e}")

        await asyncio.sleep(config.INTERVALO_MONITORIZACION)


# ──────────────────────────────────────────────
#  MAIN
# ──────────────────────────────────────────────

def main():
    """Inicializa y arranca el bot."""
    logger.info("Iniciando bot de monitorización...")

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    app = Application.builder().token(config.TELEGRAM_TOKEN).build()

    # Comandos
    app.add_handler(CommandHandler("help", cmd_help))
    app.add_handler(CommandHandler("start", cmd_help))
    app.add_handler(CommandHandler("estado", cmd_estado))
    app.add_handler(CommandHandler("servicios", cmd_servicios))
    app.add_handler(CommandHandler("uptime", cmd_uptime))
    app.add_handler(CommandHandler("red", cmd_red))
    app.add_handler(CommandHandler("procesos", cmd_procesos))
    app.add_handler(CommandHandler("docker", cmd_docker))
    app.add_handler(CommandHandler("ping", cmd_ping))
    app.add_handler(CommandHandler("alertas", cmd_alertas))

    # Botones inline
    app.add_handler(CallbackQueryHandler(callback_handler))

    # Monitorización en segundo plano
    app.post_init = iniciar_monitorizacion

    logger.info("Bot iniciado. Esperando comandos...")
    app.run_polling()


if __name__ == "__main__":
    main()
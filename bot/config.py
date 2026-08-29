import os
from dotenv import load_dotenv

load_dotenv()

# --- Telegram ---
TELEGRAM_TOKEN = os.getenv('TELEGRAM_TOKEN')
TELEGRAM_CHAT_ID = os.getenv('TELEGRAM_CHAT_ID')

# --- Umbrales de alerta ---
UMBRAL_CPU = int(os.getenv('UMBRAL_CPU', 90))
UMBRAL_RAM = int(os.getenv('UMBRAL_RAM', 90))
UMBRAL_TEMP = float(os.getenv('UMBRAL_TEMP', 85.0))
UMBRAL_DISCO = int(os.getenv('UMBRAL_DISCO', 90))

# --- Intervalos (en segundos) ---
INTERVALO_MONITORIZACION = int(os.getenv('INTERVALO_MONITORIZACION', 60))
COOLDOWN_ALERTAS = int(os.getenv('COOLDOWN_ALERTAS', 900))  # 15 minutos por defecto

# --- Logging ---
LOG_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'logs')
LOG_FILE = os.path.join(LOG_DIR, 'bot.log')

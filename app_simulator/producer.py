"""Simula la app de Spotify: publica reproducciones en el tópico de Kafka.

- Lee de PostgreSQL, al iniciar, los suscriptores y las canciones que existen.
- Cada INTERVAL_SECONDS publica una reproducción con el formato fijo
  {event_id, subscriber_id, song_id, played_at, ms_played}.
- Una proporción SKIP_RATE son skips (ms_played < 30000).
- Una proporción DUPLICATE_RATE se vuelve a enviar, idéntica, entre 0 y
  MAX_DUPLICATE_DELAY_SECONDS segundos después (tope: 300).
- played_at cae al azar en los últimos MAX_PLAY_AGE_DAYS días (modo sin conexión).
- sent.log guarda cada mensaje ORIGINAL (sin duplicados) que Kafka confirmó.
"""
import heapq
import json
import logging
import os
import random
import signal
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from functools import partial
from pathlib import Path

import psycopg
from confluent_kafka import Producer

LOG_DIR = Path("/app/logs")
LOG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S%z",
    handlers=[logging.FileHandler(LOG_DIR / "producer.log"), logging.StreamHandler()],
)
log = logging.getLogger("producer")

SENT_LOG = LOG_DIR / "sent.log"
MAX_DELAY_LIMIT = 300  # la regla de negocio: un duplicado llega a lo más 5 minutos después
APP_TZ = timezone(timedelta(hours=-7))  # Hermosillo: así se ve que played_at trae zona horaria

stop = False


def _handle_signal(signum, frame):
    global stop
    stop = True


def read_config():
    """Lee y valida las variables de entorno. Termina si falta alguna o es inválida."""
    try:
        cfg = {
            "pg_host": os.environ["POSTGRES_HOST"],
            "pg_db": os.environ["POSTGRES_DB"],
            "pg_user": os.environ["POSTGRES_USER"],
            "pg_password": os.environ["POSTGRES_PASSWORD"],
            "bootstrap": os.environ["KAFKA_BOOTSTRAP_SERVERS"],
            "topic": os.environ["KAFKA_TOPIC"],
            "interval": float(os.environ["INTERVAL_SECONDS"]),
            "skip_rate": float(os.environ["SKIP_RATE"]),
            "dup_rate": float(os.environ["DUPLICATE_RATE"]),
            "max_delay": float(os.environ["MAX_DUPLICATE_DELAY_SECONDS"]),
            "max_age_days": float(os.environ["MAX_PLAY_AGE_DAYS"]),
        }
    except KeyError as e:
        log.error("Falta la variable de entorno %s. Revisa el .env y la sección environment: "
                  "del servicio producer en docker-compose.yml.", e)
        sys.exit(1)
    except ValueError as e:
        log.error("Una variable numérica del .env tiene un valor inválido: %s", e)
        sys.exit(1)

    if cfg["interval"] <= 0:
        log.error("INTERVAL_SECONDS debe ser mayor que 0")
        sys.exit(1)
    for name in ("skip_rate", "dup_rate"):
        if not 0 <= cfg[name] <= 1:
            log.error("%s debe estar entre 0 y 1 (vale %s)", name.upper(), cfg[name])
            sys.exit(1)
    if cfg["max_age_days"] <= 0:
        log.error("MAX_PLAY_AGE_DAYS debe ser mayor que 0")
        sys.exit(1)
    if cfg["max_delay"] > MAX_DELAY_LIMIT:
        log.warning("MAX_DUPLICATE_DELAY_SECONDS=%s pasa de %s; se usa %s (regla de negocio)",
                    cfg["max_delay"], MAX_DELAY_LIMIT, MAX_DELAY_LIMIT)
        cfg["max_delay"] = MAX_DELAY_LIMIT
    cfg["max_delay"] = max(cfg["max_delay"], 0.0)
    return cfg


def read_catalog(cfg):
    """IDs de suscriptores y (id, duración en ms) de canciones que existen en la base."""
    with psycopg.connect(host=cfg["pg_host"], dbname=cfg["pg_db"],
                         user=cfg["pg_user"], password=cfg["pg_password"]) as conn:
        subscribers = [r[0] for r in conn.execute(
            "SELECT subscriber_id FROM subscribers ORDER BY subscriber_id").fetchall()]
        songs = [(r[0], r[1] * 1000) for r in conn.execute(
            "SELECT song_id, duration_seconds FROM songs ORDER BY song_id").fetchall()]
    return subscribers, songs


def make_event(cfg, subscribers, songs):
    song_id, duration_ms = random.choice(songs)
    if random.random() < cfg["skip_rate"]:
        ms_played = random.randint(1000, 29999)                 # skip: no cuenta
    else:
        ms_played = random.randint(30000, max(30000, duration_ms))  # reproducción válida
    age = random.uniform(0, cfg["max_age_days"] * 86400)        # segundos hacia atrás
    played_at = (datetime.now(APP_TZ) - timedelta(seconds=age)).isoformat(timespec="seconds")
    return json.dumps({
        "event_id": str(uuid.uuid4()),
        "subscriber_id": random.choice(subscribers),
        "song_id": song_id,
        "played_at": played_at,
        "ms_played": ms_played,
    })


def on_delivery(is_original, err, msg):
    """Kafka llama a esta función con el resultado de cada envío."""
    value = msg.value().decode("utf-8")
    if err is not None:
        log.error("Kafka no confirmó el mensaje (%s): %s", err, value)
        return
    if is_original:
        with open(SENT_LOG, "a", encoding="utf-8") as f:
            f.write(value + "\n")
        log.info("Enviado: %s", value)
    else:
        log.info("Reenviado (duplicado): %s", value)


def main():
    cfg = read_config()
    try:
        subscribers, songs = read_catalog(cfg)
    except psycopg.OperationalError as e:
        # PostgreSQL todavía no acepta conexiones: termina con error y Docker
        # vuelve a iniciar el producer (restart: on-failure).
        log.error("No se pudo conectar a PostgreSQL; Docker volverá a iniciar el producer: %s", e)
        sys.exit(1)
    except psycopg.errors.UndefinedTable as e:
        log.error("Faltan tablas en la base (¿se ejecutó db/01_schema.sql?): %s", e)
        sys.exit(1)
    if not subscribers or not songs:
        log.error("La base no tiene suscriptores o canciones; no hay qué simular")
        sys.exit(1)

    producer = Producer({"bootstrap.servers": cfg["bootstrap"]})
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)
    log.info("Iniciado: %d suscriptores, %d canciones, tópico %s, cada %ss "
             "(skips %.0f%%, duplicados %.0f%%)", len(subscribers), len(songs), cfg["topic"],
             cfg["interval"], cfg["skip_rate"] * 100, cfg["dup_rate"] * 100)

    pending = []  # (momento de envío, contador, mensaje) de los duplicados por reenviar
    counter = 0
    next_original = time.monotonic()
    while not stop:
        now = time.monotonic()
        while pending and pending[0][0] <= now:
            _, _, value = heapq.heappop(pending)
            producer.produce(cfg["topic"], value=value, on_delivery=partial(on_delivery, False))
            producer.flush()
        if now >= next_original:
            value = make_event(cfg, subscribers, songs)
            producer.produce(cfg["topic"], value=value, on_delivery=partial(on_delivery, True))
            producer.flush()
            if random.random() < cfg["dup_rate"]:
                counter += 1
                due = time.monotonic() + random.uniform(0, cfg["max_delay"])
                heapq.heappush(pending, (due, counter, value))
            next_original += cfg["interval"]
        producer.poll(0)
        time.sleep(0.05)

    producer.flush()
    log.info("Detenido; quedaron %d duplicados sin reenviar", len(pending))


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        log.exception("Error inesperado")
        sys.exit(1)

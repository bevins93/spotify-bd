"""Lee el tópico de Kafka y guarda cada mensaje, tal cual, en el crudo.

El crudo son archivos de texto, una línea por mensaje, uno por hora de
llegada (UTC): /app/data/raw/<tópico>-AAAA-MM-DDTHH.log. No interpreta ni
filtra nada: el processor decide qué cuenta.

El offset de un mensaje se confirma en Kafka solo después de escribirlo y
vaciarlo al disco: si el consumer se cae, no pierde mensajes (a lo más repite
alguno, y el processor quita los duplicados).
"""
import logging
import os
import signal
import sys
from datetime import datetime, timezone
from pathlib import Path

from confluent_kafka import Consumer, KafkaError

LOG_DIR = Path("/app/logs")
LOG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S%z",
    handlers=[logging.FileHandler(LOG_DIR / "consumer.log"), logging.StreamHandler()],
)
log = logging.getLogger("consumer")

RAW_DIR = Path("/app/data/raw")

stop = False


def _handle_signal(signum, frame):
    global stop
    stop = True


def raw_file_for(topic, moment):
    """El archivo del crudo que corresponde a la hora UTC en que llegó el mensaje."""
    return RAW_DIR / f"{topic}-{moment:%Y-%m-%dT%H}.log"


def main():
    try:
        bootstrap = os.environ["KAFKA_BOOTSTRAP_SERVERS"]
        topic = os.environ["KAFKA_TOPIC"]
    except KeyError as e:
        log.error("Falta la variable de entorno %s. Revisa el .env y la sección environment: "
                  "del servicio consumer en docker-compose.yml.", e)
        sys.exit(1)

    try:
        RAW_DIR.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        log.error("No se pudo crear %s (¿está montado el volumen crudo?): %s", RAW_DIR, e)
        sys.exit(1)

    consumer = Consumer({
        "bootstrap.servers": bootstrap,
        "group.id": "ingestion",
        "auto.offset.reset": "earliest",
        "allow.auto.create.topics": True,
        # El offset se guarda a mano, después de escribir el mensaje en el crudo.
        "enable.auto.offset.store": False,
    })
    consumer.subscribe([topic])
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)
    log.info("Suscrito al tópico %s; el crudo se escribe en %s", topic, RAW_DIR)

    current_path, current_file = None, None
    try:
        while not stop:
            msg = consumer.poll(timeout=1.0)
            if msg is None:
                continue
            if msg.error():
                if msg.error().code() == KafkaError.UNKNOWN_TOPIC_OR_PART:
                    log.warning("El tópico %s todavía no existe; Kafka lo crea y sigo esperando", topic)
                else:
                    log.error("Kafka reportó un error: %s", msg.error())
                continue

            text = msg.value().decode("utf-8", errors="replace")
            if "\n" in text or "\r" in text:
                # Una línea = un mensaje. En un JSON válido los saltos de línea solo
                # pueden ser espacio en blanco entre campos, así que el contenido no cambia.
                log.warning("El mensaje del offset %s trae saltos de línea; se guardan como espacios",
                            msg.offset())
                text = text.replace("\r", " ").replace("\n", " ")

            path = raw_file_for(topic, datetime.now(timezone.utc))
            try:
                if path != current_path:
                    if current_file:
                        current_file.close()
                    current_file = open(path, "a", encoding="utf-8")
                    current_path = path
                    log.info("Archivo del crudo: %s", path)
                current_file.write(text + "\n")
                current_file.flush()
                os.fsync(current_file.fileno())
            except OSError as e:
                log.error("No se pudo escribir en el crudo (%s): %s", path, e)
                sys.exit(1)

            consumer.store_offsets(msg)
            log.info("Guardado en el crudo (offset %s): %s", msg.offset(), text)
    finally:
        if current_file:
            current_file.close()
        consumer.close()  # confirma los offsets guardados
        log.info("Detenido")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        log.exception("Error inesperado")
        sys.exit(1)

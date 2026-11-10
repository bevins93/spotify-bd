"""Procesa el crudo y actualiza los conteos en PostgreSQL. Lo ejecuta cron cada 5 minutos.

En cada corrida:
  1. Lee del crudo (/app/data/raw/<tópico>-*.log) solo las líneas completas que
     no ha procesado (recuerda hasta qué byte leyó de cada archivo).
  2. Quita los duplicados: un event_id que ya vio es la misma reproducción.
  3. Se queda con las reproducciones válidas (ms_played >= 30000).
  4. Suma los conteos en subscriber_song_play y song_daily_play (día en UTC),
     en una sola transacción.
  5. Anota en /app/logs/processor.log qué hizo, cuántos mensajes descartó y por qué.

Ningún mensaje se guarda en PostgreSQL: solo los conteos. Lo que el processor
recuerda entre corridas (hasta dónde leyó y los event_id recientes) vive en un
archivo de estado junto al crudo, no en la base.

cron no muestra lo que imprime un programa, por eso solo escribe en su .log.
"""
import fcntl
import json
import logging
import os
import re
import sys
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

import psycopg

LOG_DIR = Path("/app/logs")
LOG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S%z",
    handlers=[logging.FileHandler(LOG_DIR / "processor.log")],
)
log = logging.getLogger("processor")

DATA_DIR = Path("/app/data")
RAW_DIR = DATA_DIR / "raw"
STATE_DIR = DATA_DIR / "state"
STATE_FILE = STATE_DIR / "processor_state.json"
LOCK_FILE = STATE_DIR / "processor.lock"

MIN_MS_VALID = 30000          # regla 1: una reproducción válida dura al menos 30 s
SEEN_RETENTION_HOURS = 2      # cuántas horas de llegada se recuerdan los event_id (un duplicado llega en <= 5 min)
INT4_MAX = 2**31 - 1
FILE_RE = re.compile(r"-(\d{4}-\d{2}-\d{2}T\d{2})\.log$")


def file_hour(path):
    """La hora de llegada (en horas desde 1970, UTC) que indica el nombre del archivo."""
    m = FILE_RE.search(path.name)
    if not m:
        return None
    dt = datetime.strptime(m.group(1), "%Y-%m-%dT%H").replace(tzinfo=timezone.utc)
    return int(dt.timestamp() // 3600)


def load_state():
    if not STATE_FILE.exists():
        return {"offsets": {}, "seen": {}}
    with open(STATE_FILE, encoding="utf-8") as f:
        state = json.load(f)
    return {"offsets": state.get("offsets", {}), "seen": state.get("seen", {})}


def save_state(state):
    tmp = STATE_FILE.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, STATE_FILE)  # reemplazo atómico: nunca queda un estado a medias


def read_new_lines(files, offsets):
    """Líneas completas nuevas de cada archivo, en orden. Devuelve (líneas, offsets nuevos)."""
    lines, new_offsets = [], dict(offsets)
    for path in files:
        hour = file_hour(path)
        if hour is None:
            log.warning("Se ignora %s: su nombre no tiene la forma <tópico>-AAAA-MM-DDTHH.log", path.name)
            continue
        offset = offsets.get(path.name, 0)
        if path.stat().st_size <= offset:
            continue
        with open(path, "rb") as f:
            f.seek(offset)
            data = f.read()
        end = data.rfind(b"\n")
        if end < 0:
            continue  # la última línea todavía se está escribiendo
        chunk = data[:end + 1]  # solo líneas completas; el resto se lee en la próxima corrida
        new_offsets[path.name] = offset + len(chunk)
        for raw in chunk.split(b"\n")[:-1]:
            lines.append((hour, raw))
    return lines, new_offsets


def parse_event(raw):
    """Devuelve (evento, None) si el mensaje tiene el formato de la sección 2.3, o (None, motivo)."""
    try:
        ev = json.loads(raw.decode("utf-8", errors="replace"))
    except json.JSONDecodeError:
        return None, "no es JSON"
    if not isinstance(ev, dict):
        return None, "no es un objeto JSON"
    eid = ev.get("event_id")
    if not isinstance(eid, str) or not eid:
        return None, "event_id inválido"
    for field in ("subscriber_id", "song_id"):
        v = ev.get(field)
        if isinstance(v, bool) or not isinstance(v, int) or not 1 <= v <= INT4_MAX:
            return None, f"{field} inválido"
    ms = ev.get("ms_played")
    if isinstance(ms, bool) or not isinstance(ms, int) or ms < 0:
        return None, "ms_played inválido"
    played_at = ev.get("played_at")
    if not isinstance(played_at, str):
        return None, "played_at inválido"
    try:
        moment = datetime.fromisoformat(played_at)
    except ValueError:
        return None, "played_at inválido"
    if moment.tzinfo is None:
        return None, "played_at sin zona horaria"
    ev["_play_date"] = moment.astimezone(timezone.utc).date()  # regla 3: los días se definen en UTC
    return ev, None


def classify(lines, seen):
    """Quita duplicados y skips. Devuelve (válidas, contadores). Actualiza `seen` (event_id -> hora)."""
    stats = Counter()
    valid = []
    for hour, raw in lines:
        stats["leidos"] += 1
        if not raw.strip():
            stats["vacias"] += 1
            continue
        ev, reason = parse_event(raw)
        if ev is None:
            stats["malformados"] += 1
            log.warning("Mensaje descartado (%s): %s", reason, raw[:200].decode("utf-8", errors="replace"))
            continue
        if ev["event_id"] in seen:                      # regla 2: mismo event_id = misma reproducción
            stats["duplicados"] += 1
            continue
        seen[ev["event_id"]] = hour
        if ev["ms_played"] < MIN_MS_VALID:              # regla 1: skip
            stats["skips"] += 1
            continue
        valid.append(ev)
    return valid, stats


def prune_seen(seen):
    """Olvida los event_id demasiado viejos para que vuelva a llegar un duplicado suyo."""
    if not seen:
        return seen
    newest = max(seen.values())
    return {k: h for k, h in seen.items() if h >= newest - SEEN_RETENTION_HOURS}


def apply_counts(conn, valid, stats):
    """Descarta lo que no existe en la base y suma el resto en las dos tablas."""
    subs = {r[0] for r in conn.execute(
        "SELECT subscriber_id FROM subscribers WHERE subscriber_id = ANY(%s)",
        (sorted({e["subscriber_id"] for e in valid}),)).fetchall()}
    songs = {r[0] for r in conn.execute(
        "SELECT song_id FROM songs WHERE song_id = ANY(%s)",
        (sorted({e["song_id"] for e in valid}),)).fetchall()}

    by_sub_song, by_song_day = Counter(), Counter()
    for e in valid:
        if e["subscriber_id"] not in subs:
            stats["suscriptor_inexistente"] += 1
        elif e["song_id"] not in songs:
            stats["cancion_inexistente"] += 1
        else:
            by_sub_song[(e["subscriber_id"], e["song_id"])] += 1
            by_song_day[(e["song_id"], e["_play_date"])] += 1
            stats["validos"] += 1

    conn.cursor().executemany(
        """INSERT INTO subscriber_song_play (subscriber_id, song_id, num_rep) VALUES (%s, %s, %s)
           ON CONFLICT (subscriber_id, song_id)
           DO UPDATE SET num_rep = subscriber_song_play.num_rep + EXCLUDED.num_rep""",
        [(s, g, n) for (s, g), n in by_sub_song.items()])
    conn.cursor().executemany(
        """INSERT INTO song_daily_play (song_id, play_date, num_rep) VALUES (%s, %s, %s)
           ON CONFLICT (song_id, play_date)
           DO UPDATE SET num_rep = song_daily_play.num_rep + EXCLUDED.num_rep""",
        [(g, d, n) for (g, d), n in by_song_day.items()])
    return len(by_sub_song), len(by_song_day)


def run():
    started = time.monotonic()
    try:
        topic = os.environ["KAFKA_TOPIC"]
        pg = dict(host=os.environ["POSTGRES_HOST"], dbname=os.environ["POSTGRES_DB"],
                  user=os.environ["POSTGRES_USER"], password=os.environ["POSTGRES_PASSWORD"])
    except KeyError as e:
        log.error("Falta la variable de entorno %s. Si funciona a mano pero no con cron, revisa "
                  "/etc/environment y el command: del servicio processor en docker-compose.yml.", e)
        return 1

    if not RAW_DIR.exists():
        log.warning("El crudo %s todavía no existe: el consumer no ha guardado ningún mensaje", RAW_DIR)
        return 0
    STATE_DIR.mkdir(parents=True, exist_ok=True)

    with open(LOCK_FILE, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log.warning("Otra corrida del processor sigue en curso; esta se omite")
            return 0

        state = load_state()
        files = sorted(RAW_DIR.glob(f"{topic}-*.log"))
        lines, offsets = read_new_lines(files, state["offsets"])
        seen = dict(state["seen"])
        valid, stats = classify(lines, seen)

        n_ssp = n_sdp = 0
        if valid:
            try:
                # Todo dentro del mismo bloque: se aplica completo o no se aplica nada.
                with psycopg.connect(connect_timeout=10, **pg) as conn:
                    n_ssp, n_sdp = apply_counts(conn, valid, stats)
            except psycopg.OperationalError as e:
                log.error("No se pudo conectar a PostgreSQL; no se avanzó en el crudo, "
                          "la próxima corrida reintenta: %s", e)
                return 1
            except psycopg.errors.UndefinedTable as e:
                log.error("Faltan las tablas de conteos: aplica db/03_play_counts.sql: %s", e)
                return 1

        # El estado se guarda DESPUÉS del COMMIT. Si el proceso muriera justo entre los dos
        # pasos, la próxima corrida repetiría ese lote (límite documentado en el README).
        save_state({"offsets": offsets, "seen": prune_seen(seen)})

    discarded = (stats["duplicados"] + stats["skips"] + stats["malformados"]
                 + stats["suscriptor_inexistente"] + stats["cancion_inexistente"])
    log.info("Corrida OK: %d archivos, %d mensajes leídos, %d descartados "
             "(duplicados=%d, skips=%d, malformados=%d, suscriptor_inexistente=%d, "
             "cancion_inexistente=%d), %d reproducciones válidas; filas tocadas: "
             "subscriber_song_play=%d, song_daily_play=%d; %.2fs",
             len(files), stats["leidos"] - stats["vacias"], discarded,
             stats["duplicados"], stats["skips"], stats["malformados"],
             stats["suscriptor_inexistente"], stats["cancion_inexistente"],
             stats["validos"], n_ssp, n_sdp, time.monotonic() - started)
    return 0


if __name__ == "__main__":
    log.info("Inicia corrida")
    try:
        sys.exit(run())
    except SystemExit:
        raise
    except Exception:
        log.exception("Error inesperado en la corrida")
        sys.exit(1)

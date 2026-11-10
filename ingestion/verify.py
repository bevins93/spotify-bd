"""Verifica que los conteos de PostgreSQL coinciden con lo que se envió.

Compara:
  1. Por canción: reproducciones válidas únicas de sent.log  vs  subscriber_song_play.
  2. Por canción: reproducciones válidas únicas de sent.log  vs  song_daily_play.
  3. Por canción: total de subscriber_song_play  vs  total de song_daily_play.
  Además, con más detalle: por (suscriptor, canción) y por (canción, día UTC).

Muestra OK si todo coincide, o la lista de diferencias (y termina con código 1).

Uso (después de detener el producer y esperar la siguiente corrida del processor):
  docker compose exec processor /app/.venv/bin/python /app/ingestion/verify.py
"""
import json
import logging
import os
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

import psycopg

LOG_DIR = Path("/app/logs")
SENT_LOG = LOG_DIR / "sent.log"
MIN_MS_VALID = 30000

LOG_DIR.mkdir(parents=True, exist_ok=True)
file_handler = logging.FileHandler(LOG_DIR / "verify.log")
file_handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s",
                                            "%Y-%m-%dT%H:%M:%S%z"))
console = logging.StreamHandler(sys.stdout)
console.setFormatter(logging.Formatter("%(message)s"))  # el reporte se lee tal cual
logging.basicConfig(level=logging.INFO, handlers=[console, file_handler])
log = logging.getLogger("verify")


def read_sent():
    """Reproducciones válidas únicas de sent.log: por (suscriptor, canción) y por (canción, día UTC)."""
    by_sub_song, by_song_day, seen = Counter(), Counter(), set()
    total = skips = dups = 0
    with open(SENT_LOG, encoding="utf-8") as f:
        for line in f:
            if not line.strip():
                continue
            ev = json.loads(line)
            total += 1
            if ev["event_id"] in seen:
                dups += 1
                continue
            seen.add(ev["event_id"])
            if ev["ms_played"] < MIN_MS_VALID:
                skips += 1
                continue
            day = datetime.fromisoformat(ev["played_at"]).astimezone(timezone.utc).date()
            by_sub_song[(ev["subscriber_id"], ev["song_id"])] += 1
            by_song_day[(ev["song_id"], day)] += 1
    return by_sub_song, by_song_day, {"lineas": total, "unicos": len(seen), "skips": skips, "repetidos": dups}


def compare(name_a, a, name_b, b, label):
    """Lista las llaves donde los dos conteos difieren."""
    diffs = []
    for key in sorted(set(a) | set(b), key=str):
        if a.get(key, 0) != b.get(key, 0):
            shown = ", ".join(str(k) for k in key) if isinstance(key, tuple) else str(key)
            diffs.append(f"  {label} [{shown}]: {name_a}={a.get(key, 0)}  {name_b}={b.get(key, 0)}")
    return diffs


def main():
    try:
        pg = dict(host=os.environ["POSTGRES_HOST"], dbname=os.environ["POSTGRES_DB"],
                  user=os.environ["POSTGRES_USER"], password=os.environ["POSTGRES_PASSWORD"])
    except KeyError as e:
        log.error("Falta la variable de entorno %s (ejecútalo con docker compose exec processor ...)", e)
        return 2
    if not SENT_LOG.exists():
        log.error("No existe %s: el producer todavía no ha enviado nada (o se borró el volumen logs)", SENT_LOG)
        return 2

    sent_ss, sent_sd, info = read_sent()
    try:
        with psycopg.connect(connect_timeout=10, **pg) as conn:
            db_ss = Counter({(r[0], r[1]): r[2] for r in conn.execute(
                "SELECT subscriber_id, song_id, num_rep FROM subscriber_song_play").fetchall()})
            db_sd = Counter({(r[0], r[1]): r[2] for r in conn.execute(
                "SELECT song_id, play_date, num_rep FROM song_daily_play").fetchall()})
            titles = dict(conn.execute("SELECT song_id, title FROM songs").fetchall())
    except psycopg.OperationalError as e:
        log.error("No se pudo conectar a PostgreSQL: %s", e)
        return 2

    def per_song(counter, song_pos):
        out = Counter()
        for key, n in counter.items():
            out[key[song_pos]] += n
        return out

    sent_song = per_song(sent_ss, 1)          # válidas únicas enviadas, por canción
    ssp_song = per_song(db_ss, 1)             # subscriber_song_play, por canción
    sdp_song = per_song(db_sd, 0)             # song_daily_play, por canción

    log.info("sent.log: %d líneas, %d eventos únicos, %d skips, %d válidos",
             info["lineas"], info["unicos"], info["skips"], sum(sent_song.values()))
    log.info("")
    log.info("%-6s %-26s %10s %10s %10s", "song", "título", "enviadas", "ssp", "sdp")
    for song in sorted(set(sent_song) | set(ssp_song) | set(sdp_song)):
        log.info("%-6s %-26s %10d %10d %10d", song, titles.get(song, "?")[:26],
                 sent_song.get(song, 0), ssp_song.get(song, 0), sdp_song.get(song, 0))
    log.info("%-33s %10d %10d %10d", "TOTAL", sum(sent_song.values()),
             sum(ssp_song.values()), sum(sdp_song.values()))
    log.info("(ssp = subscriber_song_play, sdp = song_daily_play)")
    log.info("")

    problems = []
    problems += compare("enviadas", sent_song, "subscriber_song_play", ssp_song, "canción")
    problems += compare("enviadas", sent_song, "song_daily_play", sdp_song, "canción")
    problems += compare("subscriber_song_play", ssp_song, "song_daily_play", sdp_song, "canción")
    problems += compare("enviadas", sent_ss, "subscriber_song_play", db_ss, "(suscriptor, canción)")
    problems += compare("enviadas", sent_sd, "song_daily_play", db_sd, "(canción, día UTC)")

    if not problems:
        log.info("OK: los conteos de la base coinciden con los eventos únicos enviados, "
                 "y las dos tablas cuadran entre sí")
        return 0
    log.info("HAY DIFERENCIAS (%d):", len(problems))
    for line in problems:
        log.info(line)
    log.info("Si el producer sigue corriendo, o el processor aún no hace su siguiente corrida, "
             "es normal que falten mensajes por procesar.")
    return 1


if __name__ == "__main__":
    sys.exit(main())

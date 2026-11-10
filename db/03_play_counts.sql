-- =====================================================================
-- 03_play_counts.sql  (migración de la Tarea 4)
--
-- Conteos de reproducciones válidas. Los mensajes originales NO se
-- guardan aquí: viven en el crudo (archivos .log fuera de PostgreSQL).
--
-- Se puede ejecutar dos veces sin error (IF NOT EXISTS). Con el volumen
-- vacío la imagen de PostgreSQL la ejecuta sola, después de 01_ y 02_;
-- con una base que ya tiene datos se aplica a mano:
--   docker compose exec postgres psql -U admin -d spotify \
--       -f /docker-entrypoint-initdb.d/03_play_counts.sql
-- =====================================================================

-- Las 20 canciones más escuchadas de un suscriptor (desde siempre).
-- Una fila por par (suscriptor, canción). Sin ON DELETE CASCADE: borrar un
-- suscriptor exige borrar antes sus conteos (ver tests.sql).
CREATE TABLE IF NOT EXISTS subscriber_song_play (
    subscriber_id integer NOT NULL REFERENCES subscribers (subscriber_id),
    song_id       integer NOT NULL REFERENCES songs (song_id),
    num_rep       bigint  NOT NULL CHECK (num_rep > 0),   -- reproducciones válidas
    PRIMARY KEY (subscriber_id, song_id)
);

-- Reproducciones válidas de cada canción por día, con el día en UTC.
-- Alimenta el top 100 semanal. No lleva suscriptor: por eso borrar a un
-- suscriptor no cambia este top (ver tests.sql).
CREATE TABLE IF NOT EXISTS song_daily_play (
    song_id   integer NOT NULL REFERENCES songs (song_id),
    play_date date    NOT NULL,                            -- día UTC
    num_rep   bigint  NOT NULL CHECK (num_rep > 0),
    PRIMARY KEY (song_id, play_date)
);

-- El top semanal filtra por rango de fechas: la llave (song_id, play_date)
-- no sirve para eso, este índice sí.
CREATE INDEX IF NOT EXISTS song_daily_play_date_idx ON song_daily_play (play_date);

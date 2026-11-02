-- =====================================================================
-- tests.sql: preguntas de Laura, intentos de romper las reglas y
-- transacciones de registro y eliminación de suscriptores.
--
-- Ejecutar (con el contenedor corriendo):
--   docker compose exec postgres psql -U admin -d spotify -f /tests.sql
--
-- Los intentos de romper las reglas DEBEN mostrar un ERROR: significa
-- que PostgreSQL rechazó la operación y psql sigue con la siguiente.
-- El archivo se puede ejecutar varias veces: deja los datos como estaban.
-- =====================================================================

-- Sin paginador: muestra todos los resultados de corrido.
\pset pager off

\echo
\echo '=== a) PREGUNTAS DE LAURA ==='

\echo
\echo '--- 1. Canciones de la playlist 10, en orden, con sus artistas ---'
SELECT ps.position AS posicion,
       s.title     AS cancion,
       string_agg(a.name || ' (' || sa.role || ')', ', '
                  ORDER BY (sa.role <> 'principal'), a.name) AS artistas
FROM playlist_song ps
JOIN songs       s  ON s.song_id   = ps.song_id
JOIN song_artist sa ON sa.song_id  = s.song_id
JOIN artists     a  ON a.artist_id = sa.artist_id
WHERE ps.playlist_id = 10
GROUP BY ps.position, s.title
ORDER BY ps.position;

\echo
\echo '--- 2. Suscriptores por suscripción (incluye las que no tienen ninguno) ---'
SELECT sp.name AS suscripcion,
       count(sb.subscriber_id) AS suscriptores
FROM subscriptions sp
LEFT JOIN subscribers sb ON sb.subscription_id = sp.subscription_id
GROUP BY sp.subscription_id, sp.name
ORDER BY suscriptores DESC, sp.name;

\echo
\echo '--- 3. Canciones que no están en ningún álbum ---'
SELECT s.song_id, s.title
FROM songs s
WHERE NOT EXISTS (SELECT 1 FROM song_album sa WHERE sa.song_id = s.song_id)
ORDER BY s.song_id;

\echo
\echo '--- 4. Biblioteca de cada suscriptor (canciones y álbumes) ---'
SELECT sb.email, 'canción' AS tipo, s.title AS nombre
FROM subscribers sb
JOIN libraries    l  ON l.subscriber_id = sb.subscriber_id
JOIN library_song ls ON ls.library_id   = l.library_id
JOIN songs        s  ON s.song_id       = ls.song_id
UNION ALL
SELECT sb.email, 'álbum', al.title
FROM subscribers sb
JOIN libraries     l  ON l.subscriber_id = sb.subscriber_id
JOIN library_album la ON la.library_id   = l.library_id
JOIN albums        al ON al.album_id     = la.album_id
UNION ALL
-- Suscriptores sin nada guardado (marta), para que también aparezcan.
SELECT sb.email, '(nada guardado)', NULL
FROM subscribers sb
JOIN libraries l ON l.subscriber_id = sb.subscriber_id
WHERE NOT EXISTS (SELECT 1 FROM library_song  ls WHERE ls.library_id = l.library_id)
  AND NOT EXISTS (SELECT 1 FROM library_album la WHERE la.library_id = l.library_id)
ORDER BY email, tipo, nombre;

\echo
\echo '--- 5. Canción más escuchada ---'
-- NO SE PUEDE RESPONDER con esta base. Ninguna tabla registra
-- reproducciones: playlist_song y library_song solo dicen qué canciones
-- se agregaron o guardaron, no cuántas veces se escucharon.
-- Le falta una tabla de reproducciones, por ejemplo:
--   plays (play_id PK, subscriber_id FK, song_id FK, played_at timestamp)
-- y entonces la consulta sería:
--   SELECT s.title, count(*) FROM plays p JOIN songs s USING (song_id)
--   GROUP BY s.title ORDER BY count(*) DESC LIMIT 1;
\echo 'Sin respuesta: falta una tabla de reproducciones (ver comentario en tests.sql).'


\echo
\echo '=== b) INTENTOS DE ROMPER LAS REGLAS (cada uno debe dar ERROR) ==='

\echo
\echo '--- PRIMARY KEY: no puede haber dos canciones con el mismo id ---'
INSERT INTO songs (song_id, title, duration_seconds, genre)
VALUES (101, 'Canción repetida', 100, 'Pop');

\echo
\echo '--- FOREIGN KEY: una playlist no puede contener una canción que no existe ---'
INSERT INTO playlist_song (playlist_id, song_id, position, added_at)
VALUES (13, 999, 1, '2026-07-01');

\echo
\echo '--- FOREIGN KEY: no se borra una canción que está en una playlist ---'
DELETE FROM songs WHERE song_id = 101;

\echo
\echo '--- FOREIGN KEY: un perfil necesita un país que exista en el catálogo ---'
UPDATE profiles SET country_code = 'XX' WHERE profile_id = 1;

\echo
\echo '--- NOT NULL: toda playlist tiene un suscriptor creador (mínimo 1) ---'
INSERT INTO playlists (playlist_id, name, created_at, subscriber_id)
VALUES (99, 'Sin dueño', '2026-07-01', NULL);

\echo
\echo '--- NOT NULL: todo suscriptor tiene una suscripción (mínimo 1) ---'
INSERT INTO subscribers (subscriber_id, email, registered_at, subscription_id)
VALUES (99, 'sinplan@mail.com', '2026-07-01', NULL);

\echo
\echo '--- UNIQUE: el email identifica a un solo suscriptor ---'
INSERT INTO subscribers (subscriber_id, email, registered_at, subscription_id)
VALUES (99, 'ana@mail.com', '2026-07-01', 1);

\echo
\echo '--- UNIQUE (1:1): un suscriptor tiene un solo perfil ---'
INSERT INTO profiles (profile_id, subscriber_id, display_name, photo, country_code)
VALUES (99, 1, 'otro_perfil', NULL, 'MX');

\echo
\echo '--- UNIQUE: dos canciones no pueden tener la misma posición en una playlist ---'
INSERT INTO playlist_song (playlist_id, song_id, position, added_at)
VALUES (10, 104, 1, '2026-07-01');

\echo
\echo '--- UNIQUE: dos canciones no pueden tener la misma pista en un álbum ---'
INSERT INTO song_album (song_id, album_id, track_number)
VALUES (108, 205, 3);

\echo
\echo '--- CHECK: el rol de un artista es principal o feat. ---'
INSERT INTO song_artist (song_id, artist_id, role)
VALUES (108, 'A11', 'solista');

\echo
\echo '--- CHECK: el precio de una suscripción no puede ser negativo ---'
UPDATE subscriptions SET monthly_price = -10 WHERE subscription_id = 1;

\echo
\echo '--- CHECK: una canción dura más de 0 segundos ---'
INSERT INTO songs (song_id, title, duration_seconds, genre)
VALUES (999, 'Canción vacía', 0, 'Pop');


\echo
\echo '=== c) TRANSACCIONES ==='

-- Instantánea del catálogo y del suscriptor 1 (ana), para comparar antes y después.
-- (Se usa en las pruebas de fallo para mostrar que nada cambió.)

-- ---------------------------------------------------------------------
-- c1) REGISTRO de un suscriptor: suscriptor + perfil + biblioteca, todo o nada.
-- ---------------------------------------------------------------------
\echo
\echo '--- c1) Registro EXITOSO: sofia@mail.com ---'
BEGIN;
INSERT INTO subscribers (subscriber_id, email, registered_at, subscription_id)
VALUES (5, 'sofia@mail.com', '2026-11-02', 1);
INSERT INTO profiles (profile_id, subscriber_id, display_name, photo, country_code)
VALUES (5, 5, 'sofia.r', NULL, 'MX');
INSERT INTO libraries (library_id, subscriber_id)
VALUES (5, 5);
COMMIT;

-- Debe mostrar 1 suscriptor, 1 perfil y 1 biblioteca.
SELECT sb.email,
       (SELECT count(*) FROM profiles  p WHERE p.subscriber_id = sb.subscriber_id) AS perfiles,
       (SELECT count(*) FROM libraries l WHERE l.subscriber_id = sb.subscriber_id) AS bibliotecas
FROM subscribers sb
WHERE sb.subscriber_id = 5;

\echo
\echo '--- c1) Registro con FALLO a medio camino: el perfil usa un país inexistente ---'
SELECT (SELECT count(*) FROM subscribers) AS suscriptores_antes,
       (SELECT count(*) FROM profiles)    AS perfiles_antes,
       (SELECT count(*) FROM libraries)   AS bibliotecas_antes;

BEGIN;
INSERT INTO subscribers (subscriber_id, email, registered_at, subscription_id)
VALUES (6, 'fallo@mail.com', '2026-11-02', 1);
-- Falla: el país 'XX' no existe (FOREIGN KEY). La transacción queda abortada.
INSERT INTO profiles (profile_id, subscriber_id, display_name, photo, country_code)
VALUES (6, 6, 'fallo', NULL, 'XX');
-- Esta instrucción ya no se ejecuta: la transacción está abortada.
INSERT INTO libraries (library_id, subscriber_id)
VALUES (6, 6);
ROLLBACK;

-- Mismos números que antes: no quedó el suscriptor 6 sin perfil ni biblioteca.
SELECT (SELECT count(*) FROM subscribers) AS suscriptores_despues,
       (SELECT count(*) FROM profiles)    AS perfiles_despues,
       (SELECT count(*) FROM libraries)   AS bibliotecas_despues,
       (SELECT count(*) FROM subscribers WHERE email = 'fallo@mail.com') AS fallo_en_bd;

-- ---------------------------------------------------------------------
-- c2) ELIMINACIÓN de un suscriptor y todo lo que depende de él,
--     sin ON DELETE CASCADE: cada borrado es explícito.
--     No se borra ninguna canción, álbum ni artista del catálogo.
-- ---------------------------------------------------------------------

-- Para tener qué borrar, sofia (id 5) crea una playlist y guarda cosas.
INSERT INTO playlists (playlist_id, name, created_at, subscriber_id)
VALUES (15, 'Mis favoritas', '2026-11-02', 5);
INSERT INTO playlist_song (playlist_id, song_id, position, added_at)
VALUES (15, 101, 1, '2026-11-02'), (15, 106, 2, '2026-11-02');
INSERT INTO library_song  (library_id, song_id)  VALUES (5, 107);
INSERT INTO library_album (library_id, album_id) VALUES (5, 205);

\echo
\echo '--- c2) Eliminación con FALLO a medio camino (se olvida borrar el perfil) ---'
-- Estado de ana (suscriptor 1) y del catálogo ANTES.
SELECT (SELECT count(*) FROM playlists     WHERE subscriber_id = 1) AS playlists_ana,
       (SELECT count(*) FROM playlist_song WHERE playlist_id IN
            (SELECT playlist_id FROM playlists WHERE subscriber_id = 1)) AS canciones_en_playlists,
       (SELECT count(*) FROM library_song  WHERE library_id = 1) AS canciones_guardadas,
       (SELECT count(*) FROM library_album WHERE library_id = 1) AS albumes_guardados,
       (SELECT count(*) FROM profiles      WHERE subscriber_id = 1) AS perfil,
       (SELECT count(*) FROM subscribers   WHERE subscriber_id = 1) AS suscriptor,
       (SELECT count(*) FROM songs) AS songs,
       (SELECT count(*) FROM albums) AS albums,
       (SELECT count(*) FROM artists) AS artists;

BEGIN;
DELETE FROM playlist_song
 WHERE playlist_id IN (SELECT playlist_id FROM playlists WHERE subscriber_id = 1);
DELETE FROM playlists    WHERE subscriber_id = 1;
DELETE FROM library_song  WHERE library_id = (SELECT library_id FROM libraries WHERE subscriber_id = 1);
DELETE FROM library_album WHERE library_id = (SELECT library_id FROM libraries WHERE subscriber_id = 1);
DELETE FROM libraries    WHERE subscriber_id = 1;
-- Falla: el perfil todavía referencia al suscriptor (FOREIGN KEY).
DELETE FROM subscribers  WHERE subscriber_id = 1;
ROLLBACK;

-- Mismos números que antes: no se perdió nada de ana.
SELECT (SELECT count(*) FROM playlists     WHERE subscriber_id = 1) AS playlists_ana,
       (SELECT count(*) FROM playlist_song WHERE playlist_id IN
            (SELECT playlist_id FROM playlists WHERE subscriber_id = 1)) AS canciones_en_playlists,
       (SELECT count(*) FROM library_song  WHERE library_id = 1) AS canciones_guardadas,
       (SELECT count(*) FROM library_album WHERE library_id = 1) AS albumes_guardados,
       (SELECT count(*) FROM profiles      WHERE subscriber_id = 1) AS perfil,
       (SELECT count(*) FROM subscribers   WHERE subscriber_id = 1) AS suscriptor,
       (SELECT count(*) FROM songs) AS songs,
       (SELECT count(*) FROM albums) AS albums,
       (SELECT count(*) FROM artists) AS artists;

\echo
\echo '--- c2) Eliminación EXITOSA de sofia (suscriptor 5) ---'
SELECT (SELECT count(*) FROM playlists     WHERE subscriber_id = 5) AS playlists_sofia,
       (SELECT count(*) FROM playlist_song WHERE playlist_id = 15)  AS canciones_en_playlists,
       (SELECT count(*) FROM library_song  WHERE library_id = 5)    AS canciones_guardadas,
       (SELECT count(*) FROM library_album WHERE library_id = 5)    AS albumes_guardados,
       (SELECT count(*) FROM profiles      WHERE subscriber_id = 5) AS perfil,
       (SELECT count(*) FROM subscribers   WHERE subscriber_id = 5) AS suscriptor,
       (SELECT count(*) FROM songs) AS songs,
       (SELECT count(*) FROM albums) AS albums,
       (SELECT count(*) FROM artists) AS artists;

BEGIN;
DELETE FROM playlist_song
 WHERE playlist_id IN (SELECT playlist_id FROM playlists WHERE subscriber_id = 5);
DELETE FROM playlists     WHERE subscriber_id = 5;
DELETE FROM library_song  WHERE library_id = (SELECT library_id FROM libraries WHERE subscriber_id = 5);
DELETE FROM library_album WHERE library_id = (SELECT library_id FROM libraries WHERE subscriber_id = 5);
DELETE FROM libraries     WHERE subscriber_id = 5;
DELETE FROM profiles      WHERE subscriber_id = 5;
DELETE FROM subscribers   WHERE subscriber_id = 5;
COMMIT;

-- Todo lo de sofia en 0 y el catálogo intacto (8 canciones, 6 álbumes, 11 artistas).
SELECT (SELECT count(*) FROM playlists     WHERE subscriber_id = 5) AS playlists_sofia,
       (SELECT count(*) FROM playlist_song WHERE playlist_id = 15)  AS canciones_en_playlists,
       (SELECT count(*) FROM library_song  WHERE library_id = 5)    AS canciones_guardadas,
       (SELECT count(*) FROM library_album WHERE library_id = 5)    AS albumes_guardados,
       (SELECT count(*) FROM profiles      WHERE subscriber_id = 5) AS perfil,
       (SELECT count(*) FROM subscribers   WHERE subscriber_id = 5) AS suscriptor,
       (SELECT count(*) FROM songs) AS songs,
       (SELECT count(*) FROM albums) AS albums,
       (SELECT count(*) FROM artists) AS artists;

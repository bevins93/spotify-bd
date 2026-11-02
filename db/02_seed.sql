-- =====================================================================
-- 02_seed.sql: datos iniciales (tablas A, B, C y D de Laura)
-- Conserva sus identificadores (song_id, album_id, artist_id, playlist_id).
-- Orden: primero las tablas a las que otras hacen referencia.
-- =====================================================================

-- Países (de las tablas B y D)
INSERT INTO countries (country_code, name) VALUES
    ('US', 'Estados Unidos'),
    ('MX', 'México'),
    ('CO', 'Colombia'),
    ('AR', 'Argentina'),
    ('PR', 'Puerto Rico');

-- Suscripciones (tabla A). Los ids 1 a 3 son de Laura; el 4 es un dato
-- agregado para tener una suscripción sin suscriptores.
INSERT INTO subscriptions (subscription_id, name, monthly_price, has_ads) VALUES
    (1, 'Premium',    129, false),
    (2, 'Gratuita',     0, true),
    (3, 'Familiar',   199, false),
    (4, 'Estudiante',  59, false);   -- AGREGADO: suscripción sin suscriptores

-- Suscriptores (tabla D). subscriber_id es nuevo: 1 ana, 2 luis, 3 marta, 4 diego.
INSERT INTO subscribers (subscriber_id, email, registered_at, subscription_id) VALUES
    (1, 'ana@mail.com',   '2025-11-02', 1),
    (2, 'luis@mail.com',  '2026-01-15', 2),
    (3, 'marta@mail.com', '2026-05-20', 3),
    (4, 'diego@mail.com', '2026-09-01', 3);

-- Perfiles (tabla D): marta no tiene foto (NULL).
INSERT INTO profiles (profile_id, subscriber_id, display_name, photo, country_code) VALUES
    (1, 1, 'anaruiz', 'a1.jpg', 'MX'),
    (2, 2, 'luis.s',  'l2.jpg', 'MX'),
    (3, 3, 'marta_g', NULL,     'AR'),
    (4, 4, 'diegol',  'd4.jpg', 'MX');

-- Bibliotecas: una por suscriptor, con el mismo número.
INSERT INTO libraries (library_id, subscriber_id) VALUES
    (1, 1), (2, 2), (3, 3), (4, 4);

-- Artistas (tabla B)
INSERT INTO artists (artist_id, name, country_code) VALUES
    ('A1',  'Karol G',          'CO'),
    ('A2',  'Shakira',          'CO'),
    ('A3',  'Miley Cyrus',      'US'),
    ('A4',  'SZA',              'US'),
    ('A5',  'Bizarrap',         'AR'),
    ('A6',  'Eslabon Armado',   'US'),
    ('A7',  'Peso Pluma',       'MX'),
    ('A8',  'Bad Bunny',        'PR'),
    ('A9',  'Chencho Corleone', 'PR'),
    ('A10', 'Los del Pitic',    'MX'),
    ('A11', 'Grupo Frontera',   'MX');   -- AGREGADO: artista sin canciones ni álbumes

-- Canciones (tablas A y B). duración en segundos (2:45 = 165).
INSERT INTO songs (song_id, title, duration_seconds, genre) VALUES
    (101, 'Ella Baila Sola',          165, 'Regional mexicano'),
    (102, 'TQG',                      197, 'Reguetón'),
    (103, 'Bzrp Music Sessions #53',  213, 'Pop latino'),
    (104, 'Flowers',                  200, 'Pop'),
    (105, 'Kill Bill',                153, 'R&B'),
    (106, 'Tití Me Preguntó',         243, 'Reguetón'),
    (107, 'Me Porto Bonito',          178, 'Reguetón'),
    (108, 'Calor de Agosto',          185, 'Regional mexicano');   -- sin álbum

-- Álbumes (tabla C)
INSERT INTO albums (album_id, title, release_year, cover, artist_id) VALUES
    (201, 'Desvelado',               2023, 'desvelado.jpg', 'A6'),
    (202, 'Mañana Será Bonito',      2023, 'msb.jpg',       'A1'),
    (203, 'Endless Summer Vacation', 2023, 'esv.jpg',       'A3'),
    (204, 'SOS',                     2022, 'sos.jpg',       'A4'),
    (205, 'Un Verano Sin Ti',        2022, 'uvst.jpg',      'A8'),
    (206, 'Las Mujeres Ya No Lloran', 2024, 'lmynl.jpg',    'A2');

-- Playlists (tabla A). La 13 está vacía (caso de playlist vacía).
INSERT INTO playlists (playlist_id, name, created_at, subscriber_id) VALUES
    (10, 'Gym',           '2026-03-01', 1),
    (11, 'Para estudiar', '2026-04-10', 1),
    (12, 'Gym',           '2026-05-02', 2),
    (13, 'Viaje',         '2026-06-15', 3),
    (14, 'Favoritas',     '2026-06-20', 2);

-- Canciones de cada playlist (tabla A): posición = orden de la celda.
INSERT INTO playlist_song (playlist_id, song_id, position, added_at) VALUES
    (10, 101, 1, '2026-03-01'),
    (10, 102, 2, '2026-03-01'),
    (10, 103, 3, '2026-03-04'),
    (11, 104, 1, '2026-04-10'),
    (11, 101, 2, '2026-04-12'),
    (12, 102, 1, '2026-05-02'),
    (12, 105, 2, '2026-05-02'),
    (14, 103, 1, '2026-06-20'),
    (14, 104, 2, '2026-06-21'),
    (14, 102, 3, '2026-06-22');

-- Artistas de cada canción (tabla B)
INSERT INTO song_artist (song_id, artist_id, role) VALUES
    (101, 'A6',  'principal'),
    (101, 'A7',  'feat.'),
    (102, 'A1',  'principal'),
    (102, 'A2',  'feat.'),
    (103, 'A5',  'principal'),
    (103, 'A2',  'feat.'),
    (104, 'A3',  'principal'),
    (105, 'A4',  'principal'),
    (106, 'A8',  'principal'),
    (107, 'A8',  'principal'),
    (107, 'A9',  'feat.'),
    (108, 'A10', 'principal');

-- Canciones de cada álbum (tabla C)
INSERT INTO song_album (song_id, album_id, track_number) VALUES
    (101, 201, 6),
    (102, 202, 6),
    (104, 203, 1),
    (105, 204, 2),
    (107, 205, 3),
    (106, 205, 4),
    (103, 206, 11),
    (102, 206, 12);

-- Biblioteca de cada suscriptor (tabla D)
INSERT INTO library_song (library_id, song_id) VALUES
    (1, 102), (1, 104),     -- ana
    (2, 103),               -- luis
    (4, 101), (4, 108);     -- diego

INSERT INTO library_album (library_id, album_id) VALUES
    (1, 205),               -- ana
    (2, 204), (2, 206);     -- luis

-- Casos pedidos en la tarea:
--   suscripción sin suscriptores ... 4 'Estudiante' (agregada)
--   artista sin canciones ni álbumes  A11 'Grupo Frontera' (agregado)
--   playlist vacía ................. 13 'Viaje' (ya viene en los datos de Laura)
--   canción sin álbum .............. 108 'Calor de Agosto' (ya viene en los datos de Laura)

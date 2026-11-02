-- =====================================================================
-- 01_schema.sql: esquema de la BD de Spotify (PostgreSQL)
-- Implementa el diagrama ER de docs/diagrama_er.png.
-- Orden: primero las tablas a las que otras hacen referencia.
--
-- Cómo se reflejan las cardinalidades:
--   * mínimo 1 del lado "uno"  -> la llave foránea es NOT NULL
--   * máximo 1 del lado "uno"  -> la llave foránea en la tabla "muchos"
--   * relación 1:1             -> la llave foránea además es UNIQUE
--   * mínimo 0                 -> la llave foránea admite no tener filas hijas
-- Reglas que PostgreSQL NO puede imponer con restricciones simples (se
-- cuidan con las transacciones de tests.sql):
--   * todo suscriptor tiene exactamente un perfil y una biblioteca
--   * toda canción tiene al menos un artista (song_artist)
--   * todo álbum tiene al menos una canción (song_album)
-- =====================================================================

-- Catálogo de países, compartido por artistas y perfiles (entidad nueva
-- que surgió al normalizar: country_code -> name).
CREATE TABLE countries (
    country_code char(2)     PRIMARY KEY,
    name         varchar(60) NOT NULL UNIQUE
);

-- Planes de suscripción. El precio y los anuncios dependen del plan.
CREATE TABLE subscriptions (
    subscription_id integer     PRIMARY KEY,
    name            varchar(20) NOT NULL UNIQUE,
    monthly_price   integer     NOT NULL CHECK (monthly_price >= 0),  -- MXN al mes
    has_ads         boolean     NOT NULL
);

-- Un suscriptor tiene exactamente un plan (NOT NULL); un plan puede no
-- tener suscriptores (mínimo 0 en el otro extremo).
CREATE TABLE subscribers (
    subscriber_id   integer      PRIMARY KEY,
    email           varchar(255) NOT NULL UNIQUE,
    registered_at   date         NOT NULL,
    subscription_id integer      NOT NULL REFERENCES subscriptions (subscription_id)
);

-- Relación 1:1 con subscribers: UNIQUE + NOT NULL.
CREATE TABLE profiles (
    profile_id    integer      PRIMARY KEY,
    subscriber_id integer      NOT NULL UNIQUE REFERENCES subscribers (subscriber_id),
    display_name  varchar(50)  NOT NULL,
    photo         varchar(255),               -- opcional: marta no tiene foto
    country_code  char(2)      NOT NULL REFERENCES countries (country_code)
);

-- Relación 1:1 con subscribers.
CREATE TABLE libraries (
    library_id    integer PRIMARY KEY,
    subscriber_id integer NOT NULL UNIQUE REFERENCES subscribers (subscriber_id)
);

-- Un suscriptor crea de 0 a N playlists; toda playlist tiene un creador.
-- El nombre NO es único: dos suscriptores pueden tener una playlist "Gym".
CREATE TABLE playlists (
    playlist_id   integer      PRIMARY KEY,
    name          varchar(100) NOT NULL,
    created_at    date         NOT NULL,
    subscriber_id integer      NOT NULL REFERENCES subscribers (subscriber_id)
);

CREATE TABLE songs (
    song_id          integer      PRIMARY KEY,
    title            varchar(150) NOT NULL,
    duration_seconds integer      NOT NULL CHECK (duration_seconds > 0),
    genre            varchar(50)  NOT NULL
);

-- artist_id conserva los ids de Laura (A1, A2, ...).
CREATE TABLE artists (
    artist_id    varchar(10)  PRIMARY KEY,
    name         varchar(100) NOT NULL,
    country_code char(2)      NOT NULL REFERENCES countries (country_code)
);

-- El álbum guarda su propio artista (puede ser distinto del de sus canciones).
-- La portada es opcional: ninguna regla de negocio la exige.
CREATE TABLE albums (
    album_id     integer      PRIMARY KEY,
    title        varchar(150) NOT NULL,
    release_year integer      NOT NULL CHECK (release_year BETWEEN 1900 AND 2100),
    cover        varchar(255),
    artist_id    varchar(10)  NOT NULL REFERENCES artists (artist_id)
);

-- ---------------------------------------------------------------------
-- Tablas de unión (relaciones muchos a muchos)
-- ---------------------------------------------------------------------

-- Una canción no se repite dentro de una playlist (PK) ni dos canciones
-- comparten posición (UNIQUE).
CREATE TABLE playlist_song (
    playlist_id integer NOT NULL REFERENCES playlists (playlist_id),
    song_id     integer NOT NULL REFERENCES songs (song_id),
    position    integer NOT NULL CHECK (position > 0),
    added_at    date    NOT NULL,
    PRIMARY KEY (playlist_id, song_id),
    UNIQUE (playlist_id, position)
);

-- rol del artista en la canción: principal o feat.
CREATE TABLE song_artist (
    song_id   integer     NOT NULL REFERENCES songs (song_id),
    artist_id varchar(10) NOT NULL REFERENCES artists (artist_id),
    role      varchar(10) NOT NULL CHECK (role IN ('principal', 'feat.')),
    PRIMARY KEY (song_id, artist_id)
);

-- Una canción puede estar en 0 o más álbumes (108 no está en ninguno) y
-- en un álbum no hay dos canciones en la misma pista.
CREATE TABLE song_album (
    song_id      integer NOT NULL REFERENCES songs (song_id),
    album_id     integer NOT NULL REFERENCES albums (album_id),
    track_number integer NOT NULL CHECK (track_number > 0),
    PRIMARY KEY (song_id, album_id),
    UNIQUE (album_id, track_number)
);

CREATE TABLE library_song (
    library_id integer NOT NULL REFERENCES libraries (library_id),
    song_id    integer NOT NULL REFERENCES songs (song_id),
    PRIMARY KEY (library_id, song_id)
);

CREATE TABLE library_album (
    library_id integer NOT NULL REFERENCES libraries (library_id),
    album_id   integer NOT NULL REFERENCES albums (album_id),
    PRIMARY KEY (library_id, album_id)
);

# Base de datos de Spotify (PostgreSQL)

Implementación de la base de datos transaccional de Spotify a partir de los datos que envió Laura. El diseño sale de la normalización a 3FN de sus cuatro tablas (ver [`docs/Tarea_2_Normalizacion_Spotify.md`](docs/Tarea_2_Normalizacion_Spotify.md)) y del diagrama ER de [`docs/diagrama_er.png`](docs/diagrama_er.png).

## Contenido

```
.
├── db/
│   ├── 01_schema.sql        # tablas, tipos, llaves y restricciones
│   └── 02_seed.sql          # datos de Laura + casos agregados
├── docs/
│   ├── diagrama_conceptual.png
│   ├── diagrama_er.png
│   └── Tarea_2_Normalizacion_Spotify.md
├── .env.example             # plantilla de credenciales (el .env NO se sube)
├── .gitignore
├── docker-compose.yml
├── tests.sql                # preguntas de Laura, reglas y transacciones
└── README.md
```

## Variables del `.env`

El archivo `.env` contiene las credenciales y no se sube a Git. Se crea a partir de la plantilla:

```bash
cp .env.example .env
```

| Variable | Qué es | Valor de ejemplo |
| --- | --- | --- |
| `POSTGRES_USER` | Usuario que se crea en PostgreSQL | `admin` |
| `POSTGRES_PASSWORD` | Contraseña de ese usuario (cámbiala) | `cambia_esta_contrasena` |
| `POSTGRES_DB` | Nombre de la base de datos | `spotify` |

Estos valores solo se usan cuando PostgreSQL se inicializa con un volumen vacío. Si los cambias después, no tendrán efecto hasta borrar el volumen.

## Cómo iniciar PostgreSQL

Desde la carpeta del repositorio (donde está `docker-compose.yml`):

```bash
cp .env.example .env            # solo la primera vez
docker compose up -d            # crea el contenedor y, con el volumen vacío, ejecuta db/
sleep 10                        # la inicialización termina después del comando
docker compose logs postgres | grep ERROR    # no debe mostrar nada
```

Al iniciar con el volumen vacío, PostgreSQL ejecuta `db/01_schema.sql` y luego `db/02_seed.sql`, sin pasos manuales. Para reconstruir todo desde cero:

```bash
docker compose down -v && docker compose up -d
```

## Cómo ejecutar las pruebas

```bash
docker compose exec postgres psql -U admin -d spotify -f /tests.sql
```

Para explorar la base a mano: `docker compose exec postgres psql -U admin -d spotify` (se sale con `\q`).

Qué hace `tests.sql`:

- **a) Preguntas de Laura**: una consulta por pregunta. La 5 (canción más escuchada) no se puede responder: ninguna tabla guarda reproducciones. Falta una tabla `plays` (suscriptor, canción, fecha); la consulta queda explicada en el archivo.
- **b) Intentos de romper las reglas**: 13 operaciones que PostgreSQL rechaza (PRIMARY KEY, FOREIGN KEY, NOT NULL, UNIQUE y CHECK), cada una con la regla de negocio que protege. Deben mostrar `ERROR`.
- **c) Transacciones**: registro de un suscriptor (suscriptor + perfil + biblioteca) y eliminación (perfil, biblioteca con lo guardado, playlists con sus canciones), cada una con un caso exitoso y uno que falla a medio camino, y consultas que muestran que los datos quedaron como estaban. La eliminación no usa `ON DELETE CASCADE` ni toca el catálogo (canciones, álbumes, artistas).

El archivo se puede ejecutar varias veces: deja los datos como estaban.

## Supuestos

- Una canción no se repite dentro de una playlist ni dentro de un álbum; sí puede estar en varios álbumes (TQG está en 202 y 206) y puede no estar en ninguno (108).
- Cada suscriptor tiene un solo plan; el precio y los anuncios son del plan.
- Los códigos de país (US, MX, CO, AR, PR) forman un catálogo compartido por artistas y perfiles: `countries` es la entidad nueva que surgió al normalizar.
- `profiles` y `libraries` se conservan del diagrama conceptual como relaciones 1:1 con `subscribers` (`subscriber_id` es `UNIQUE`).
- Llaves: los ids de Laura se conservan (`song_id`, `album_id`, `playlist_id`, `artist_id` como `A1`…`A10`). `subscriber_id`, `subscription_id`, `profile_id` y `library_id` son ids nuevos (1 ana, 2 luis, 3 marta, 4 diego).
- `duración` (m:ss) se guarda como `duration_seconds` (2:45 = 165). Celdas vacías de Laura = `NULL` (foto de marta) o ninguna fila (playlist 13, bibliotecas sin guardados).
- Datos agregados para los casos pedidos: suscripción `Estudiante` (sin suscriptores) y artista `A11 Grupo Frontera` (sin canciones ni álbumes). La playlist vacía (13) y la canción sin álbum (108) ya venían en los datos de Laura.

## Reglas que no se pueden imponer con restricciones

PostgreSQL no puede exigir con un `CHECK` o una llave que:

- todo suscriptor tenga un perfil y una biblioteca,
- toda canción tenga al menos un artista,
- todo álbum tenga al menos una canción.

Son los "mínimo 1" de relaciones donde la llave foránea queda del otro lado. Se cuidan con las transacciones de registro (que crean el suscriptor, su perfil y su biblioteca juntos, o nada). Imponerlos del todo requeriría restricciones diferidas o triggers, fuera del alcance de esta tarea.

## Esquema vs. diagrama ER

El esquema coincide con el diagrama ER de la Tarea 2; no hubo cambios.

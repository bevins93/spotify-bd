# Plataforma de datos de Spotify

Base de datos transaccional de Spotify en PostgreSQL (Tareas 2 y 3) más la ingesta de reproducciones con Kafka (Tarea 4). El diseño de la base sale de la normalización a 3FN de las cuatro tablas de Laura ([`docs/Tarea_2_Normalizacion_Spotify.md`](docs/Tarea_2_Normalizacion_Spotify.md)); el diagrama ER está en [`docs/diagrama_er.png`](docs/diagrama_er.png).

## Qué hace

Laura pidió un top 100 semanal de canciones y las 20 canciones más escuchadas de cada suscriptor. La app no escribe en la base: cada reproducción se publica como mensaje en Kafka y esta plataforma mantiene los conteos.

```
producer ──→ Kafka (tópico streams) ──→ consumer ──→ archivos .log (el crudo)
                                                          │
                                                          ↓ cada 5 minutos
                                      processor: quita duplicados, filtra y suma ──→ PostgreSQL
```

| Servicio | Qué hace |
| --- | --- |
| `postgres` | Guarda el catálogo y los conteos (`subscriber_song_play`, `song_daily_play`) |
| `kafka` | Broker de Kafka 4.1 en modo KRaft, tópico `streams` |
| `producer` | Simula la app: publica reproducciones, con skips y duplicados |
| `consumer` | Lee el tópico y guarda cada mensaje, tal cual, en el crudo |
| `processor` | cron lo ejecuta cada 5 minutos: lee el crudo nuevo y actualiza los conteos |

**Ningún mensaje se guarda en PostgreSQL: solo los conteos.**

## Contenido

```
.
├── app_simulator/
│   └── producer.py          # simula la app de Spotify
├── ingestion/
│   ├── consumer.py          # Kafka → crudo
│   ├── processor.py         # crudo → conteos en PostgreSQL
│   ├── verify.py            # comprueba que los conteos cuadran con lo enviado
│   └── crontab              # el processor corre cada 5 minutos
├── db/
│   ├── 01_schema.sql        # tablas, tipos, llaves y restricciones
│   ├── 02_seed.sql          # datos de Laura + casos agregados
│   └── 03_play_counts.sql   # migración de la Tarea 4: tablas de conteos
├── docs/                    # diagramas ER y normalización
├── .env.example             # plantilla de variables (el .env NO se sube)
├── .gitignore
├── .python-version
├── Dockerfile               # una imagen para los tres programas de Python
├── docker-compose.yml       # los cinco servicios
├── pyproject.toml
├── uv.lock
├── tests.sql
└── README.md
```

## Variables del `.env`

El `.env` no se sube a Git. Se crea a partir de la plantilla:

```bash
cp .env.example .env            # en PowerShell: copy .env.example .env
```

| Variable | Qué es | Valor de ejemplo |
| --- | --- | --- |
| `POSTGRES_USER` | Usuario que se crea en PostgreSQL | `admin` |
| `POSTGRES_PASSWORD` | Contraseña de ese usuario (cámbiala) | `cambia_esta_contrasena` |
| `POSTGRES_DB` | Nombre de la base de datos | `spotify` |
| `KAFKA_TOPIC` | Tópico en el que se publican las reproducciones | `streams` |
| `INTERVAL_SECONDS` | Cada cuántos segundos publica un mensaje el productor | `1` |
| `SKIP_RATE` | Proporción de skips (`ms_played` < 30 000), entre 0 y 1 | `0.2` |
| `DUPLICATE_RATE` | Proporción de mensajes que se reenvían idénticos, entre 0 y 1 | `0.1` |
| `MAX_DUPLICATE_DELAY_SECONDS` | Retraso máximo de un duplicado (tope: 300) | `300` |
| `MAX_PLAY_AGE_DAYS` | Cuántos días hacia atrás puede caer `played_at` | `14` |

Las credenciales de PostgreSQL solo se usan cuando el volumen está vacío; si las cambias después, no tienen efecto hasta `docker compose down -v`.

## Cómo iniciar todo

Desde la carpeta del repositorio:

```bash
cp .env.example .env                 # solo la primera vez
docker compose up -d --build         # construye la imagen y crea los cinco servicios
docker compose ps                    # los cinco deben decir Up
```

Al iniciar hay errores de conexión pasajeros en `producer` y `consumer` (esperan a PostgreSQL y a Kafka); es normal y paran solos. Cada vez que cambies un `.py`, vuelve a ejecutar `docker compose up -d --build`.

Con el volumen vacío, PostgreSQL ejecuta `db/01_schema.sql`, `02_seed.sql` y `03_play_counts.sql` sin pasos manuales. Para una base que ya tiene datos, la migración se aplica a mano (se puede ejecutar dos veces sin error):

```bash
docker compose exec postgres psql -U admin -d spotify -f /docker-entrypoint-initdb.d/03_play_counts.sql
```

Para reconstruir todo desde cero (borra base, crudo y logs): `docker compose down -v && docker compose up -d --build`.

### Cómo revisar que funciona

```bash
docker compose logs --tail 3 producer                          # líneas "Enviado:"
docker compose logs --tail 3 consumer                          # líneas "Guardado en el crudo"
docker compose exec processor ls /app/data/raw                 # el crudo: un archivo por hora
docker compose exec processor cat /app/logs/processor.log      # una corrida cada 5 minutos
docker compose exec processor crontab -l                       # */5 * * * *
```

El log del processor no aparece en `docker compose logs` (cron no muestra lo que imprime un programa): se lee con el `cat` de arriba. Una corrida a mano, sin esperar a cron:

```bash
docker compose exec processor /app/.venv/bin/python /app/ingestion/processor.py
```

## Cómo ejecutar las pruebas

```bash
docker compose exec postgres psql -U admin -d spotify -f /tests.sql
```

`tests.sql` contiene:

- **a) Preguntas de Laura.** Las cinco de la Tarea 3; la 5 (canción más escuchada) ahora se responde con `song_daily_play`. Además, el **top 100 semanal** (última semana completa, lunes a domingo en UTC) y las **20 canciones más escuchadas** de un suscriptor.
- **b) Intentos de romper las reglas.** 16 operaciones que PostgreSQL rechaza (PRIMARY KEY, FOREIGN KEY, NOT NULL, UNIQUE y CHECK), incluidas las de las tablas nuevas. Deben mostrar `ERROR`.
- **c) Transacciones.** Registro y eliminación de un suscriptor, cada una con un caso exitoso y uno que falla a medio camino. La eliminación ahora también borra los conteos del suscriptor en `subscriber_song_play`; sigue sin `ON DELETE CASCADE`. El archivo explica por qué **el top semanal no cambia** al eliminar a un suscriptor: se calcula con `song_daily_play`, que no guarda de quién fue cada reproducción.

El archivo se puede ejecutar varias veces: deja los datos como estaban.

## Cómo verificar los conteos (`verify.py`)

`verify.py` compara, por canción, las reproducciones válidas únicas de `sent.log` (lo que el productor envió y Kafka confirmó) con los conteos de la base, y comprueba que `subscriber_song_play` y `song_daily_play` cuadren entre sí. También compara por (suscriptor, canción) y por (canción, día UTC). Muestra `OK` o la lista de diferencias.

```bash
docker compose down -v
docker compose up -d --build
# dejar correr al menos 15 minutos
docker compose stop producer                    # tarda ~10 segundos
# esperar la siguiente corrida del processor (cada 5 minutos: minutos 0, 5, 10…)
docker compose exec processor /app/.venv/bin/python /app/ingestion/verify.py
```

Se ejecuta en el contenedor `processor` porque ahí están el volumen `logs` (donde el productor escribe `sent.log`) y las variables de PostgreSQL.

### Salida de `verify.py`

Corrida desde cero de unos 19 minutos (producer iniciado a las 16:24): se detuvo a las 16:43 (hora de Hermosillo) y se ejecutó `verify.py` después de la corrida del processor de las 16:45.

```
sent.log: 1181 líneas, 1181 eventos únicos, 226 skips, 955 válidos

song   título                       enviadas        ssp        sdp
101    Ella Baila Sola                   103        103        103
102    TQG                               122        122        122
103    Bzrp Music Sessions #53           128        128        128
104    Flowers                           115        115        115
105    Kill Bill                         122        122        122
106    Tití Me Preguntó                  133        133        133
107    Me Porto Bonito                   109        109        109
108    Calor de Agosto                   123        123        123
TOTAL                                    955        955        955
(ssp = subscriber_song_play, sdp = song_daily_play)

OK: los conteos de la base coinciden con los eventos únicos enviados, y las dos tablas cuadran entre sí
```

## Decisiones de diseño

### Cómo se organiza el crudo

El consumer escribe un archivo por **hora de llegada (UTC)**: `/app/data/raw/streams-AAAA-MM-DDTHH.log`, con una línea por mensaje, tal cual llegó (no interpreta ni filtra). Los archivos no se borran: son el historial completo para análisis (el lado OLAP), y como el processor recuerda hasta dónde leyó, los archivos viejos no cuestan nada.

- **Por qué por hora**: un archivo que crece sin fin es incómodo de manejar; un archivo por mensaje, inmanejable. La hora además le da al processor la *llegada* del mensaje, que es lo que mide la regla de duplicados (no `played_at`). La hora se toma del reloj del consumer cuando recibe el mensaje, y no de los timestamps del mensaje, que un productor puede poner como quiera.
- **El offset de Kafka se confirma después de escribir** (con `fsync`) la línea en el archivo: si el consumer se cae, no pierde mensajes; a lo más repite alguno, y el processor lo quita como duplicado.
- Si un mensaje trae saltos de línea, se guardan como espacios para conservar "una línea = un mensaje" (en un JSON válido no cambia su contenido).

### Cómo se quitan los duplicados

Dos mensajes con el mismo `event_id` son la misma reproducción. El processor guarda, junto al crudo (`/app/data/state/processor_state.json`, no en PostgreSQL), dos cosas: hasta qué byte leyó de cada archivo y los `event_id` que vio en las últimas 2 horas de llegada. Un `event_id` que ya está ahí es un duplicado y no se cuenta; el primero que llegó es el que cuenta.

- Como un duplicado llega a lo más 5 minutos después del original, nunca puede caer fuera de la ventana de 2 horas, aunque el original y el duplicado caigan en archivos de horas distintas o en corridas distintas. Los `event_id` más viejos se olvidan para que el estado no crezca sin límite.
- El estado vive en el volumen `crudo`, y el processor lo escribe de forma atómica (archivo temporal + reemplazo). Se guarda **después** del `COMMIT` de los conteos.

### Qué hace el processor con cada mensaje

1. Lee solo las **líneas completas** nuevas (una línea a medio escribir espera a la siguiente corrida).
2. Descarta los **malformados** (no es JSON, falta un campo, tipo equivocado, `played_at` sin zona horaria), los **duplicados** y los **skips** (`ms_played` < 30 000).
3. Descarta las reproducciones de un suscriptor o una canción que **no existen** en la base (violarían la llave foránea y harían fallar todo el lote).
4. Suma el resto en `subscriber_song_play` y `song_daily_play` con `INSERT … ON CONFLICT DO UPDATE`, **en una sola transacción**. El día (`play_date`) es el de `played_at` convertido a **UTC**.
5. Anota en `/app/logs/processor.log` la hora, cuántos mensajes leyó, cuántos descartó y por qué, y cualquier error.

Funciona con cualquier productor que respete el formato de la sección 2.3 del enunciado, no solo con el mío. Una corrida no se encima con otra (usa un candado de archivo).

### Supuestos y límites

- **Entrega al menos una vez.** Si el processor muriera justo entre el `COMMIT` y el guardado de su estado, la siguiente corrida repetiría ese lote de la base de datos. Hacerlo exactamente una vez exigiría guardar los `event_id` en PostgreSQL, y la regla de la tarea es que ningún mensaje se guarda ahí.
- **`verify.py` espera datos coherentes.** Después de eliminar a un suscriptor con conteos, `subscriber_song_play` queda con menos reproducciones que `song_daily_play` (ver `tests.sql`), así que `verify.py` se corre antes de eso, como indica el procedimiento.
- El productor lee los suscriptores y las canciones **al iniciar**; si se agregan después, necesita reiniciarse. Un suscriptor eliminado cuyas reproducciones sigan llegando se descarta con el motivo `suscriptor_inexistente`.
- `ms_played` válido: entero ≥ 30 000. Un día se define en UTC, como pide el negocio.

## Esquema de la base (Tareas 2 y 3)

Los supuestos de normalización y las tablas de la Tarea 3 no cambiaron; las dos tablas nuevas se agregaron al diagrama ER en verde.

- Una canción no se repite dentro de una playlist ni dentro de un álbum; sí puede estar en varios álbumes (TQG en 202 y 206) y puede no estar en ninguno (108).
- Cada suscriptor tiene un solo plan; el precio y los anuncios son del plan.
- Los códigos de país (US, MX, CO, AR, PR) forman el catálogo `countries`, compartido por artistas y perfiles.
- `profiles` y `libraries` son relaciones 1:1 con `subscribers` (`subscriber_id` es `UNIQUE`).
- Los ids de Laura se conservan; `subscriber_id`, `subscription_id`, `profile_id` y `library_id` son nuevos (1 ana, 2 luis, 3 marta, 4 diego).
- `duración` (m:ss) se guarda como `duration_seconds`. Datos agregados para los casos pedidos: suscripción `Estudiante` (sin suscriptores) y artista `A11 Grupo Frontera` (sin canciones ni álbumes).

### Reglas que no se pueden imponer con restricciones

PostgreSQL no puede exigir con un `CHECK` o una llave que todo suscriptor tenga un perfil y una biblioteca, que toda canción tenga al menos un artista, ni que todo álbum tenga al menos una canción. Se cuidan con las transacciones de registro.

### Tablas de conteos (Tarea 4)

| Tabla | Llave primaria | Columnas | Responde |
| --- | --- | --- | --- |
| `subscriber_song_play` | `(subscriber_id, song_id)` | `num_rep` | Las 20 más escuchadas de un suscriptor |
| `song_daily_play` | `(song_id, play_date)` | `num_rep` | El top 100 semanal |

`num_rep` es `bigint` con `CHECK (num_rep > 0)`; las dos llaves foráneas no llevan `ON DELETE CASCADE`. `song_daily_play` tiene un índice sobre `play_date` para el rango de fechas del top semanal.

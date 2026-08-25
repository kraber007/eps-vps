# TimescaleDB setup

## 1. Start it

```bash
cp .env.example .env
# edit .env and set a real POSTGRES_PASSWORD

docker compose up -d timescaledb
```

`init.sql` runs automatically the **first time** the container creates its
data volume (Postgres only runs `docker-entrypoint-initdb.d` scripts on an
empty data directory). If you change `init.sql` after the volume already
exists, it will NOT re-run automatically — see "Resetting" below.

## 2. Verify it came up

```bash
docker compose ps
docker compose logs -f timescaledb
```

Wait until the healthcheck shows `healthy`.

## 3. Connect

```bash
docker exec -it mushroom-timescaledb psql -U mushroom -d mushroom_farm
```

Or from your host / bridge / backend service using a normal Postgres
connection string:

```
postgresql://mushroom:<password>@localhost:5432/mushroom_farm
```

## 4. Check the hypertable

```sql
SELECT * FROM timescaledb_information.hypertables;
```

You should see `readings` listed.

## Resetting during development

If you edit `init.sql` and want it to re-run from scratch (⚠️ destroys all
data):

```bash
docker compose down
docker volume rm mushroom-farm_timescale_data
docker compose up -d timescaledb
```

## Notes

- `readings` is a hypertable partitioned by `time`. Query it like a normal
  table — Timescale handles chunking internally.
- `slot_id` is denormalized onto every reading so the API can query "all
  history for this slot" with a single `WHERE slot_id = $1`, without caring
  how many physical devices have served that slot over time.
- Retention and continuous aggregate examples are commented out at the
  bottom of `init.sql` — enable them once you have a sense of real data
  volume and query patterns; no need to decide now.

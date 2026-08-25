-- ============================================================
-- Mushroom Farm IoT - initial schema
-- Runs automatically on first container start via
-- docker-entrypoint-initdb.d (TimescaleDB image already has the
-- extension available, we just need to enable it).
-- ============================================================

CREATE EXTENSION IF NOT EXISTS timescaledb;

-- ------------------------------------------------------------
-- Users
-- ------------------------------------------------------------
CREATE TABLE users (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email         TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------
-- Slots
-- The user-facing "sensor station" (e.g. "Grow Tent 1") AND the
-- current physical hardware assigned to it, merged into one row.
-- slot id is the permanent identity used everywhere: MQTT client
-- id/username, topics, thresholds, readings.
--
-- chip_id/mqtt credentials describe whichever physical ESP is
-- CURRENTLY serving this slot. On a hardware swap (repair/replace),
-- these fields get overwritten in place -- see slot_hardware_history
-- below for the audit trail of what used to be here.
--
-- IMPORTANT on swap: always rotate mqtt_password_hash (or reissue
-- the JWT) when reassigning chip_id, so the old physical chip's
-- stored credentials stop working immediately instead of being
-- able to reconnect under the same identity.
-- ------------------------------------------------------------
CREATE TABLE slots (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name                TEXT NOT NULL,
    chip_id             TEXT UNIQUE,             -- current hardware's factory chip id (bootstrap only)
    mqtt_username       TEXT UNIQUE,
    mqtt_password_hash  TEXT,
    status              TEXT NOT NULL DEFAULT 'awaiting_hardware'
                        CHECK (status IN ('awaiting_hardware', 'active', 'repair', 'retired')),
    firmware_version    TEXT,
    last_seen_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_slots_user_id ON slots(user_id);
CREATE INDEX idx_slots_status ON slots(status);

-- ------------------------------------------------------------
-- Slot hardware history
-- Lightweight append-only audit log of every physical chip that
-- has ever served a given slot. Not a live/queried-often table --
-- just here so swaps and repairs stay traceable (which chip had
-- issues, what firmware it was on, etc). unassigned_at IS NULL
-- means this row describes the slot's current hardware.
-- ------------------------------------------------------------
CREATE TABLE slot_hardware_history (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slot_id       UUID NOT NULL REFERENCES slots(id) ON DELETE CASCADE,
    user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    chip_id       TEXT NOT NULL,
    assigned_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    unassigned_at TIMESTAMPTZ
);

CREATE INDEX idx_shh_slot_id ON slot_hardware_history(slot_id);
CREATE INDEX idx_shh_user_id ON slot_hardware_history(user_id);
CREATE UNIQUE INDEX idx_shh_one_active_per_slot
    ON slot_hardware_history(slot_id)
    WHERE unassigned_at IS NULL;

-- ------------------------------------------------------------
-- Rules
-- Each row is one independent condition -> relay action, e.g.
--   temp > 60  -> turn relay 'fan' ON
--   temp < 40  -> turn relay 'heater' ON
-- A slot/sensor can have multiple rules (different directions,
-- different relays, or even multiple rules on the same relay).
-- The ESP receives these over MQTT, stores them in NVS, and
-- evaluates them locally/offline in its control loop.
-- ------------------------------------------------------------
CREATE TABLE rules (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slot_id         UUID NOT NULL REFERENCES slots(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sensor_type     TEXT NOT NULL,          -- e.g. 'temperature', 'humidity', 'co2'
    operator        TEXT NOT NULL CHECK (operator IN ('above', 'below')),
    threshold_value NUMERIC NOT NULL,
    relay_id        TEXT NOT NULL,          -- e.g. 'fan', 'humidifier', 'heater'
    action          TEXT NOT NULL DEFAULT 'on' CHECK (action IN ('on', 'off')),
    enabled         BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (slot_id, sensor_type, operator, relay_id)
);

CREATE INDEX idx_rules_slot_id ON rules(slot_id);
CREATE INDEX idx_rules_user_id ON rules(user_id);

-- ------------------------------------------------------------
-- Relay state
-- Source of truth is the ESP itself (it controls relays locally
-- from rules stored in NVS). The bridge just mirrors the last
-- retained MQTT state here for the dashboard/API to read.
-- ------------------------------------------------------------
CREATE TABLE relay_state (
    slot_id    UUID NOT NULL REFERENCES slots(id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    relay_id   TEXT NOT NULL,
    state      BOOLEAN NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (slot_id, relay_id)
);

CREATE INDEX idx_relay_state_user_id ON relay_state(user_id);

-- ------------------------------------------------------------
-- Readings (hypertable)
-- Tagged with user_id too so dashboard queries scoped to the
-- logged-in user ("everything across my account") don't need a
-- join through slots -- a direct WHERE user_id = $1.
-- ------------------------------------------------------------
-- Single-statement hypertable creation (TimescaleDB 2.20+).
-- tsdb.partition_column picks the time dimension explicitly.
-- tsdb.segmentby groups rows by slot_id in the columnstore, which
-- matches how you'll query ("all history for this slot") and makes
-- those queries much cheaper once chunks get compressed.
-- tsdb.orderby keeps rows time-ordered within each segment.
CREATE TABLE readings (
    time        TIMESTAMPTZ NOT NULL DEFAULT now(),
    slot_id     UUID NOT NULL REFERENCES slots(id),
    user_id     UUID NOT NULL REFERENCES users(id),
    sensor_type TEXT NOT NULL,
    value       NUMERIC NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.segmentby = 'slot_id',
    tsdb.orderby = 'time DESC'
);

CREATE INDEX idx_readings_slot_time ON readings(slot_id, time DESC);
CREATE INDEX idx_readings_user_time ON readings(user_id, time DESC);

-- Note: this also auto-creates a columnstore (compression) policy
-- that converts chunks after the default chunk interval (7 days).
-- You don't need to configure compression separately -- it's on by
-- default with this syntax. See the retention/rollup notes below
-- for further tuning once you have real data volume.

-- Optional, enable later once you know your retention needs, e.g.
-- keep raw readings for 1 year:
-- SELECT add_retention_policy('readings', INTERVAL '365 days');

-- Optional, enable later for cheaper long-range dashboard queries,
-- e.g. a 1-hour rollup continuous aggregate:
-- CREATE MATERIALIZED VIEW readings_hourly
-- WITH (timescaledb.continuous) AS
-- SELECT slot_id, user_id, sensor_type,
--        time_bucket('1 hour', time) AS bucket,
--        avg(value) AS avg_value,
--        min(value) AS min_value,
--        max(value) AS max_value
-- FROM readings
-- GROUP BY slot_id, user_id, sensor_type, bucket;

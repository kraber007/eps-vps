-- ============================================================
-- Mushroom Farm IoT - schema
-- Runs automatically on first container start via
-- docker-entrypoint-initdb.d.
--
-- CHANGE FROM PRIOR VERSION:
-- Removed slots.mqtt_username. The slot's own `id` (UUID) is now
-- used directly as the MQTT username -- one less credential to
-- generate/store/rotate, and it makes the EMQX ACL a single rule
-- (`slot/%u/#`) instead of needing a DB lookup to map username ->
-- slot_id. mqtt_password_hash stays, and is still what actually
-- authenticates the connection.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS pgcrypto; -- gen_random_uuid()

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
-- id is the permanent identity used everywhere: MQTT username,
-- topics, rules, readings. chip_id/mqtt_password_hash describe
-- whichever physical ESP is CURRENTLY serving this slot; on a
-- hardware swap these get overwritten in place (see
-- slot_hardware_history for the audit trail).
--
-- IMPORTANT on swap: always rotate mqtt_password_hash when
-- reassigning chip_id, so the old physical chip can't keep
-- connecting under the same slot identity.
-- ------------------------------------------------------------
-- tbd may also need to add available sensors in the slot
CREATE TABLE slots (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name                TEXT NOT NULL,
    chip_id             TEXT UNIQUE,             -- current hardware's factory chip id (bootstrap only)
    mqtt_password_hash  TEXT,                    -- bcrypt hash; id doubles as the MQTT username
    status              TEXT NOT NULL DEFAULT 'awaiting_hardware'
                        CHECK (status IN ('awaiting_hardware', 'active', 'repair', 'retired')), --remember to make chip_id as null whenever the status is not active
    firmware_version    TEXT,
    last_seen_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_slots_user_id ON slots(user_id);
CREATE INDEX idx_slots_status ON slots(status);

-- ------------------------------------------------------------
-- Slot hardware history
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
-- ------------------------------------------------------------
CREATE TABLE rules (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slot_id         UUID NOT NULL REFERENCES slots(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sensor_type     TEXT NOT NULL,
    operator        TEXT NOT NULL CHECK (operator IN ('above', 'below')),
    threshold_value NUMERIC NOT NULL,
    relay_id        TEXT NOT NULL,
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
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- EMQX auth role
-- A dedicated, read-only Postgres role for EMQX's authentication
-- backend to use, instead of handing the broker your app's main
-- DB credentials. It only needs SELECT on slots (to look up
-- mqtt_password_hash by id/username) -- nothing else.
--
-- Set a real password via env/secret before running this in
-- anything but local dev.
-- ------------------------------------------------------------
-- CREATE ROLE emqx_auth WITH LOGIN PASSWORD 'changeme';   -- role creattion will happen in separate script via env var
-- GRANT CONNECT ON DATABASE mushroom_farm TO emqx_auth;
-- GRANT USAGE ON SCHEMA public TO emqx_auth;
-- GRANT SELECT (id, mqtt_password_hash, status) ON slots TO emqx_auth;

-- Optional, enable later once you know your retention needs:
-- SELECT add_retention_policy('readings', INTERVAL '365 days');

-- Optional, enable later for cheaper long-range dashboard queries:
-- CREATE MATERIALIZED VIEW readings_hourly
-- WITH (timescaledb.continuous) AS
-- SELECT slot_id, user_id, sensor_type,
--        time_bucket('1 hour', time) AS bucket,
--        avg(value) AS avg_value,
--        min(value) AS min_value,
--        max(value) AS max_value
-- FROM readings
-- GROUP BY slot_id, user_id, sensor_type, bucket;

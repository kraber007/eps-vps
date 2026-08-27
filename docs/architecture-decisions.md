# Architecture Decisions

**Project status:** Prototyping  
**Last updated:** 2026-08-27

This document records decisions made during design discussions. It is intended to give future sessions a reliable project context.

## Finalized

### Broker and database

- Self-hosted EMQX runs on the VPS, targeting approximately 300 devices.
- PostgreSQL with TimescaleDB stores application data and sensor time-series data.
- EMQX and TimescaleDB run through `compose.yaml`.
- A dedicated read-only PostgreSQL role is used for EMQX authentication queries.

### MQTT identity and authorization

- A slot's UUID is its permanent identity and MQTT username.
- `slots.mqtt_password_hash` stores the bcrypt hash used to authenticate that slot.
- EMQX authenticates through a PostgreSQL query against `slots`.
- File-based EMQX ACLs confine a device to `slot/%u/#`.
- Authorization is static and does not require per-slot database lookups.
- Retired slots must not authenticate, even if an old password hash remains.

### Slot and hardware model

- `slots` represents the permanent logical sensor identity.
- `slots.chip_id` represents the physical ESP32 currently assigned to that slot.
- `slots.mqtt_password_hash` belongs to the current physical assignment and must be rotated when hardware is replaced.
- `slot_hardware_history` records hardware assignments and replacements.
- A replacement ESP32 keeps the existing slot UUID but receives new MQTT credentials.

### Provisioning

- ESP32 SoftAP provisioning is used instead of BLE.
- This keeps provisioning compatible with ordinary browser-based clients, including iOS.
- The ESP32 serves its provisioning page locally, likely at `http://192.168.4.1`, using a captive-portal-style flow.
- The backend creates the slot UUID and a short-lived, one-time claim token.
- The ESP does not need to know its permanent slot ID before provisioning.
- The user submits the claim token and Wi-Fi credentials through the ESP's local page.
- After joining the farm Wi-Fi, the ESP contacts the backend with the claim token and factory `chip_id`.
- The backend validates the claim, binds the ESP to the slot, generates the MQTT password, stores its bcrypt hash, and returns the slot UUID plus MQTT connection credentials.
- The ESP stores the returned credentials in secure NVS and uses the slot UUID as its MQTT username.
- The raw MQTT password is not exposed again through normal application APIs.

### Application stack

- Next.js App Router is the full-stack application framework.
- Prisma is the ORM, with raw SQL available for TimescaleDB-specific queries such as `time_bucket()`.
- Auth.js (NextAuth v5) handles login and sessions.
- Tailwind CSS and shadcn/ui are the planned UI stack.
- Dashboard updates use simple polling initially rather than WebSockets.
- The Node.js MQTT bridge remains a separate long-running service because it maintains a persistent EMQX subscription.

### Phase 1 scope

- Phase 1 focuses on sensor telemetry, device liveness, secure provisioning, and slot ownership.
- Relay control and automated rules are deliberately excluded from the initial sensor-validation period.
- Sensors should report correctly in a sample farm for several months before relay automation is introduced.

### Phase 1 MQTT namespace

The initial protocol uses these topic families:

- `slot/{slot_id}/telemetry/{sensor_name}` for sensor readings
- `slot/{slot_id}/status` for online/device health state
- `slot/{slot_id}/event/{event_name}` for lifecycle events
- `slot/{slot_id}/cmd/{command}` for backend-to-device commands

The slot ID in these paths is the same UUID used as the MQTT username.

## To Be Reviewed Later

### MQTT payload details

Before implementing the bridge and firmware, define and document the exact JSON schemas for:

- telemetry readings, including timestamp, value, unit, quality, and optional sequence number
- status and heartbeat messages, including firmware version, chip ID, and uptime
- lifecycle events such as boot, reboot, provisioning, and Wi-Fi changes
- commands and command acknowledgements, including request IDs and failure details

### Relay and rule protocol

These namespaces are reserved for a later phase:

- `slot/{slot_id}/relay/{relay_id}/state`
- `slot/{slot_id}/cmd/relay/{relay_id}/set`
- `slot/{slot_id}/rule/{rule_id}/set`
- `slot/{slot_id}/rule/{rule_id}/status`

Rule semantics, relay behavior, hysteresis/deadband, reset values, and rule-editing UI will be designed after Phase 1 sensor validation.

### Application and bridge implementation

- Build the Node.js bridge to ingest telemetry, update `relay_state` when relays exist, and update `slots.last_seen_at`.
- Scaffold the Next.js application with Prisma models matching the SQL schema.
- Add Auth.js login and registration.
- Add slot registration and replacement flows, including safe handling of reused `chip_id` values.
- Define ownership checks for every user-facing slot, reading, and future rule operation.

### Production hardening

Before connecting real devices outside a controlled environment:

- enable MQTT TLS
- protect Postgres connections appropriately
- replace development credentials with managed secrets
- put the EMQX dashboard behind a reverse proxy and firewall
- define backup, retention, monitoring, and alerting procedures
- add automated schema, authentication, ACL, bridge, and protocol tests

## Current next step

Finalize the Phase 1 MQTT topic and payload contract, then implement a minimal telemetry-only bridge and test it with a simulated ESP32 publisher before using real devices.

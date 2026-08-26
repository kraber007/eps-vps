#!/bin/bash
set -e

echo "Granting EMQX permissions..."

psql \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  --set=ON_ERROR_STOP=1 \
  --set=emqx_user="$EMQX_PG_USERNAME" \
  <<'SQL'
SELECT format(
    'GRANT CONNECT ON DATABASE %I TO %I',
    current_database(),
    :'emqx_user'
)
\gexec

SELECT format(
    'GRANT USAGE ON SCHEMA public TO %I',
    :'emqx_user'
)
\gexec

SELECT format(
    'GRANT SELECT (id, mqtt_password_hash, status) ON TABLE slots TO %I',
    :'emqx_user'
)
\gexec
SQL

echo "EMQX permissions granted."

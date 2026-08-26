#!/bin/sh
set -e

psql \
  -v ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  --set=emqx_user="$EMQX_PG_USERNAME" \
  --set=emqx_password="$EMQX_PG_PASSWORD" <<'SQL'

SELECT format(
    'CREATE ROLE %I WITH LOGIN PASSWORD %L',
    :'emqx_user',
    :'emqx_password'
)
\gexec

SQL

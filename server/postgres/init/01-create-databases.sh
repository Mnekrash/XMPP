#!/bin/bash
# Runs once, on first start of an empty PostgreSQL volume (docker-entrypoint-initdb.d).
# Creates separate roles and databases for ejabberd and the push gateway.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v ej_db="$EJABBERD_DB_NAME" -v ej_user="$EJABBERD_DB_USER" -v ej_pw="$EJABBERD_DB_PASSWORD" \
  -v pg_db="$PUSH_DB_NAME" -v pg_user="$PUSH_DB_USER" -v pg_pw="$PUSH_DB_PASSWORD" <<'SQL'
CREATE ROLE :"ej_user" LOGIN PASSWORD :'ej_pw';
CREATE DATABASE :"ej_db" OWNER :"ej_user" ENCODING 'UTF8';
REVOKE ALL ON DATABASE :"ej_db" FROM PUBLIC;
CREATE ROLE :"pg_user" LOGIN PASSWORD :'pg_pw';
CREATE DATABASE :"pg_db" OWNER :"pg_user" ENCODING 'UTF8';
REVOKE ALL ON DATABASE :"pg_db" FROM PUBLIC;
SQL

#!/usr/bin/env bash
# Connection comes from libpq env vars: PGHOST PGPORT PGUSER PGPASSWORD (e.g. the RDS endpoint).
set -euo pipefail
cd "$(dirname "$0")/.."
DB="${PGDATABASE:-queryme_library}"
psql -X -q -v ON_ERROR_STOP=1 -d postgres        -f sql/00_create_database.sql
psql -X -q -v ON_ERROR_STOP=1 -d "$DB"           -f sql/01_schema.sql


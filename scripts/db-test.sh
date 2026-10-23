#!/usr/bin/env bash
# -------------------------------------------------------------------------------------
# Rebuilds a throwaway Postgres database and runs the database checks.
#
#   1. supabase/tests/00_supabase_shim.sql  stands in for Supabase's auth schema and API roles
#   2. supabase/migrations/*.sql            every migration, in filename order
#   3. supabase/seed.sql                    TEC's starting reference lists
#   4. supabase/tests/10_access_and_rules.sql  the access and business-rule checks
#
# The last step fails (non-zero exit) if any check fails, so CI goes red.
#
# Usage (needs a superuser connection, because the checks switch roles):
#   DB_ADMIN_URL=postgresql://postgres:postgres@localhost:5432/postgres scripts/db-test.sh
#
# NEVER point this at the Supabase project: it drops and recreates the test database,
# and the shim must not run on Supabase.
# -------------------------------------------------------------------------------------
set -euo pipefail

# Admin connection to a local or CI Postgres server (defaults match the CI service).
ADMIN_URL="${DB_ADMIN_URL:-postgresql://postgres:postgres@localhost:5432/postgres}"
TEST_DB="gsquad_test"

# SECURITY REVIEW FIX J06: the old guard only matched lower-case "supabase.co" in the URL.
# "DB.X.SUPABASE.CO", a raw IP address, a "?host=" parameter, or PGHOST/PGHOSTADDR in the
# environment all got past it. Now the host must be named in the URL and be on an allow-list.

# libpq reads these from the environment and they can redirect the connection; ignore them.
unset PGHOST PGHOSTADDR PGSERVICE PGSERVICEFILE

refuse() { echo "Refusing to run: $1 Use a local or CI Postgres." >&2; exit 1; }

# Host names are case-insensitive, so compare in lower case.
url_lc="$(printf '%s' "$ADMIN_URL" | tr '[:upper:]' '[:lower:]')"
case "$url_lc" in
  postgres://*|postgresql://*) ;;
  *) refuse "DB_ADMIN_URL must be a postgresql:// URL." ;;
esac
case "$url_lc" in
  *supabase.co*|*supabase.com*) refuse "DB_ADMIN_URL points at Supabase." ;;
esac
# Connection parameters in the query string can override the host (host=, hostaddr=, service=).
case "$url_lc" in
  *\?*host*|*\?*service*) refuse "DB_ADMIN_URL must not set host or service in its parameters." ;;
esac

# Host part: drop the scheme, then the path and parameters, then any user:password@.
hostport="${url_lc#*://}"
hostport="${hostport%%[/?]*}"
hostport="${hostport##*@}"
if [[ "$hostport" == \[* ]]; then
  db_host="${hostport%%]*}]"   # IPv6 literal, e.g. [::1]:5432
else
  db_host="${hostport%%:*}"
fi

# Local hosts only. For another throwaway server (say a docker-compose service called "db"),
# list it explicitly: DB_TEST_ALLOWED_HOSTS="db" scripts/db-test.sh
allowed=" localhost 127.0.0.1 [::1] ${DB_TEST_ALLOWED_HOSTS:-} "
if [[ -z "$db_host" || "$allowed" != *" $db_host "* ]]; then
  refuse "DB_ADMIN_URL host '${db_host}' is not a local test server."
fi

# Same server, test database instead of the admin one (drops any trailing /dbname?params).
TEST_URL="$(printf '%s' "$ADMIN_URL" | sed -E 's#/[^/?]*(\?.*)?$##')/${TEST_DB}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root/supabase"

# SECURITY REVIEW FIX J06 (second check): a tunnel can make a hosted database look local.
# Supabase databases always have the supabase_admin role; plain Postgres (and the test shim)
# never does. This only reads the role list before anything is dropped.
# (A failed connection is reported as such, not mistaken for a Supabase server.)
admin_roles="$(psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -At -c "select count(*) from pg_roles where rolname = 'supabase_admin'")" \
  || { echo "Cannot connect to the test Postgres at DB_ADMIN_URL. Is it running?" >&2; exit 1; }
if [[ "$admin_roles" != "0" ]]; then
  refuse "this server has the supabase_admin role, so it looks like a Supabase database."
fi

# Fresh database each run, so results never depend on a previous run.
psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -q -c "drop database if exists ${TEST_DB}"
psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -q -c "create database ${TEST_DB}"

# Runs one SQL file and stops at the first error.
run() { psql "$TEST_URL" -v ON_ERROR_STOP=1 -q -f "$1"; }

run tests/00_supabase_shim.sql
for f in migrations/*.sql; do
  echo "== $f"
  run "$f"
done
echo "== seed"
run seed.sql

echo "== checks"
# Results go to a file so a failure keeps its exit code; only failing rows are printed.
# The "N of N checks passed" summary is a warning, so it appears on stderr.
out="$(mktemp)"
status=0
psql "$TEST_URL" -v ON_ERROR_STOP=1 -q -t -f tests/10_access_and_rules.sql > "$out" || status=$?
grep -E '\| FAIL \|' "$out" || true
rm -f "$out"
exit "$status"

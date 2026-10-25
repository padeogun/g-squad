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
# The result column is padded ("FAIL  "), so allow spaces before the bar.
grep -E '\| FAIL +\|' "$out" || true
rm -f "$out"
[[ "$status" == "0" ]] || exit "$status"

# Sample data (run by hand on Supabase from the "Sample data" workflow): check it loads,
# gives the tester the leader roles, can be removed and loaded again, on a clean database of
# its own so the checks above never see it. It reuses ADMIN_URL, which passed the J06 guard
# above (local host, no supabase_admin role), so this too can only reach a local server.
# SECURITY REVIEW 21: the SQL is built by the same scripts/sample-data-prepare.sh the workflow
# uses, and the checks cover the review's fixes (K02 Resident Pastor opt-in, K03 live church
# refused, K05 audit rows, K07 roles taken back, K08 other people's serving kept).
echo "== sample data"
SAMPLE_DB="gsquad_sample_check"
SAMPLE_URL="$(printf '%s' "$ADMIN_URL" | sed -E 's#/[^/?]*(\?.*)?$##')/${SAMPLE_DB}"
psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -q -c "drop database if exists ${SAMPLE_DB}" -c "create database ${SAMPLE_DB}"
srun() { psql "$SAMPLE_URL" -v ON_ERROR_STOP=1 -q -f "$1" > /dev/null; }
sq() { psql "$SAMPLE_URL" -v ON_ERROR_STOP=1 -At -c "$1"; }
srun tests/00_supabase_shim.sql
for f in migrations/*.sql; do srun "$f"; done
srun seed.sql
# A leader account, as the app's invite would make it.
sq "
  insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000aa01', 'tester@example.org');
  insert into public.app_users (id, church_id, display_name)
  select '00000000-0000-0000-0000-00000000aa01', id, 'Tester' from public.churches where slug = 'tec-manchester';" > /dev/null
work="$(mktemp -d)"
prep() { OUT="$work/$1.sql" RUN_BY=db-test RUN_ID=21 bash "$repo_root/scripts/sample-data-prepare.sh"; }
ACTION=load TESTER_EMAIL=' Tester@Example.org ' prep load
ACTION=load TESTER_EMAIL='Tester@Example.org' GIVE_RESIDENT_PASTOR=true prep load_rp
ACTION=load TESTER_EMAIL='second@example.org' ROLE_SET=team_lead prep load_tl
ACTION=remove prep remove
problems=()
expect() { [[ "$2" == "$3" ]] || problems+=("$1: expected $3, got $2"); }

srun "$work/load.sql"
srun "$work/load.sql"   # a second run changes nothing
expect "people loaded" "$(sq "select count(*) from public.people where email like '%@g-squad.example'")" 30
# (In the order the role type lists them.)
expect "tester roles without the Resident Pastor box" "$(sq "select string_agg(role::text, ',' order by role) from public.role_assignments where is_active")" \
  "purpose_head,gsquad_coordinator,teci_coordinator,unit_lead,operations_lead,pastoral_lead,newsletter_editor,finance"
expect "no duplicate roles after a re-run" "$(sq "select count(*) from public.role_assignments")" 8
srun "$work/load_rp.sql"
expect "Resident Pastor only when asked" "$(sq "select count(*) from public.role_assignments where role = 'resident_pastor' and is_active")" 1
expect "every grant is audited with the GitHub user" \
  "$(sq "select count(*) from public.audit_log where action = 'sample_data_grant' and detail->>'github_user' = 'db-test' and detail->>'github_run' = '21'")" 9
# One role only (a sign-in per role): a second leader gets Team Lead and nothing else, of the
# first sample team that has no Team Lead yet (the first tester leads Ushers).
sq "
  insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000aa02', 'second@example.org');
  insert into public.app_users (id, church_id, display_name)
  select '00000000-0000-0000-0000-00000000aa02', id, 'Second' from public.churches where slug = 'tec-manchester';" > /dev/null
srun "$work/load_tl.sql"
expect "Team Lead only" "$(sq "select string_agg(r.role::text || ':' || u.name, ',') from public.role_assignments r join public.units u on u.id = r.unit_id where r.user_id = '00000000-0000-0000-0000-00000000aa02' and r.is_active")" \
  "unit_lead:Hospitality"
expect "and no other role" "$(sq "select count(*) from public.role_assignments where user_id = '00000000-0000-0000-0000-00000000aa02'")" 1

# Someone not in the sample (as a tester would type in), serving in a sample role.
sq "
  insert into public.people (church_id, first_name, surname, email)
  select id, 'Kept', 'Person', 'kept@example.org' from public.churches where slug = 'tec-manchester';
  insert into public.projects (church_id, owner_user_id, name, description, level, status, starts_at, ends_at)
  select church_id, '00000000-0000-0000-0000-00000000aa01', 'Typed-in event', 'A tester event', 'church', 'approved',
         now() + interval '10 days', now() + interval '10 days 2 hours'
  from public.app_users where id = '00000000-0000-0000-0000-00000000aa01';
  insert into public.assignments (church_id, project_id, person_id, unit_id, church_role_id, serve_date)
  select p.church_id, pr.id, p.id, r.unit_id, r.id, (now() + interval '10 days')::date
  from public.people p, public.projects pr, public.church_roles r
  where p.email = 'kept@example.org' and pr.name = 'Typed-in event' and r.description = 'Sample data' limit 1;" > /dev/null

srun "$work/remove.sql"
expect "sample people left" "$(sq "select count(*) from public.people where email like '%@g-squad.example'")" 0
expect "sample projects left" "$(sq "select count(*) from public.projects where description like 'Sample data%'")" 0
expect "sample rota roles left" "$(sq "select count(*) from public.church_roles where description like 'Sample data%'")" 0
expect "test roles left switched on" "$(sq "select count(*) from public.role_assignments where is_active")" 0
expect "role removals audited" "$(sq "select count(*) from public.audit_log where action = 'sample_data_revoke' and detail->>'github_user' = 'db-test'")" 10
expect "other people's serving kept" "$(sq "select count(*) from public.assignments a join public.people p on p.id = a.person_id where p.email = 'kept@example.org' and a.church_role_id is null")" 1

srun "$work/load.sql"   # and it loads again after removal
expect "people reloaded" "$(sq "select count(*) from public.people where email like '%@g-squad.example'")" 30
# K03: once sending to members is on, loading is refused.
sq "update public.church_settings set newsletter_live = true" > /dev/null
if psql "$SAMPLE_URL" -v ON_ERROR_STOP=1 -q -f "$work/load.sql" > /dev/null 2>&1; then
  problems+=("loading into a live church was not refused")
fi
rm -rf "$work"
psql "$ADMIN_URL" -q -c "drop database if exists ${SAMPLE_DB}"
if (( ${#problems[@]} )); then
  printf 'Sample data check failed: %s\n' "${problems[@]}" >&2
  exit 1
fi
echo "Sample data loads, gives the roles asked for, removes cleanly and takes the roles back"

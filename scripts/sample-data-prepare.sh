#!/usr/bin/env bash
# -------------------------------------------------------------------------------------
# Builds the SQL file the "Sample data" workflow runs, from the reviewed files in supabase/.
#
# SECURITY REVIEW 21 (K01, K04): this used to be inline in the workflow, where it could not be
# tested. As a script, the same code runs in the workflow, in scripts/db-test.sh and in
# scripts/security-guards.test.ts, so the checks below are proved against hostile input.
#
# Everything comes in through environment variables, never pasted into a command line by
# GitHub (a "${{ inputs.x }}" inside a run: block would let a crafted value run commands):
#   ACTION                load | remove
#   TESTER_EMAIL          (load) a leader's sign-in email, or blank for no roles
#   GIVE_RESIDENT_PASTOR  (load) "true" to include the Resident Pastor role; anything else: not
#   ROLE_SET              (load) all | resident_pastor | team_lead (blank: all). Which roles the
#                         tester gets: every role, or one role to see that role's view alone
#   RUN_BY                who started the run (GitHub user name), for the audit log
#   RUN_ID                the GitHub run number, for the audit log
#   OUT                   where to write the SQL
#
# Every value that reaches the SQL is checked against a strict pattern first, so no quote,
# backslash, slash, ampersand or line break (which would break out of the SQL string or the
# sed replacement) can get through.
# -------------------------------------------------------------------------------------
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
: "${OUT:?OUT must name the file to write}"

fail() { echo "$1" >&2; exit 1; }

case "${ACTION:-}" in
  remove|load) ;;
  *) fail "ACTION must be load or remove." ;;
esac

# Who ran it: GitHub user names are letters, digits and single hyphens (at most 39). Anything
# else (or nothing) is logged as "unknown" rather than refused, as it is a label only.
run_by="${RUN_BY:-}"
[[ "$run_by" =~ ^[A-Za-z0-9-]{1,39}$ ]] || run_by="unknown"
run_id="${RUN_ID:-}"
[[ "$run_id" =~ ^[0-9]{1,20}$ ]] || run_id="0"

if [[ "$ACTION" == "remove" ]]; then
  sed -e "s/__RUN_BY__/${run_by}/g" -e "s/__RUN_ID__/${run_id}/g" \
    "$repo_root/supabase/sample-data-remove.sql" > "$OUT"
  exit 0
fi

# Spaces (including a pasted line break) are dropped before the check, so they cannot split
# the value across lines and slip past it.
email="$(printf '%s' "${TESTER_EMAIL:-}" | tr -d '[:space:]')"
# A plain address only: letters, digits and . _ % + - before the @, letters, digits, dots and
# hyphens after it. Matched by bash on the whole value (grep would test line by line).
if [[ -n "$email" ]] && ! [[ "$email" =~ ^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,180}\.[A-Za-z]{2,24}$ ]]; then
  fail "That doesn't look like a plain email address."
fi

# SECURITY REVIEW 21 (K02): the Resident Pastor role is only given when asked for in so many
# words. Left blank, the placeholder stays and the SQL treats it as "no".
give_rp="no"
[[ "${GIVE_RESIDENT_PASTOR:-}" == "true" ]] && give_rp="yes"

# One role or every role (Paul, 25 Oct 2026: a sign-in per role). A fixed list, so nothing
# else can reach the SQL; Resident Pastor alone still needs the box ticked (K02).
role_set="${ROLE_SET:-all}"
case "$role_set" in
  all|team_lead) ;;
  resident_pastor) [[ "$give_rp" == "yes" ]] || fail "Tick the Resident Pastor box to give the Resident Pastor role." ;;
  *) fail "ROLE_SET must be all, resident_pastor or team_lead." ;;
esac

# Blank email: the placeholder stays and matches no one, so no role is given.
sed_args=(-e "s/__RUN_BY__/${run_by}/g" -e "s/__RUN_ID__/${run_id}/g" -e "s/__GIVE_RESIDENT_PASTOR__/${give_rp}/g" -e "s/__ROLE_SET__/${role_set}/g")
[[ -n "$email" ]] && sed_args+=(-e "s/__TEST_EMAIL__/${email}/g")
sed "${sed_args[@]}" "$repo_root/supabase/sample-data.sql" > "$OUT"

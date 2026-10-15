#!/usr/bin/env bash
# Runs the pgTAP suites in supabase/tests/database against the LOCAL Supabase database
# (`supabase start`). Each file runs in a transaction that is rolled back.
# The connection string is the well-known local default; it never points at a hosted project.
set -euo pipefail
cd "$(dirname "$0")/database"
DB_URL="${SUPABASE_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
case "$DB_URL" in
  *127.0.0.1*|*localhost*) ;;
  *) echo "Refusing to run tests against a non-local database." >&2; exit 2 ;;
esac
status=0
for f in *.test.sql; do
  out="$(psql "$DB_URL" -X -q -t -A -v ON_ERROR_STOP=1 -f "$f" 2>&1)" || status=1
  echo "== $f"
  echo "$out" | grep -E '^(not ok|ok|# |1\.\.)|ERROR' || true
  if echo "$out" | grep -qE '^not ok|ERROR|Looks like you'; then status=1; fi
done
[ $status -eq 0 ] && echo "All database tests passed." || echo "Database tests FAILED."
exit $status

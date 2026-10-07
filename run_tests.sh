#!/usr/bin/env bash
# Installs every migration into a scratch database and runs every suite.
# Needs a local Postgres 16 — never point this at Supabase, the tests truncate tables.
set -euo pipefail
DB="${1:-slot_test}"

dropdb --if-exists "$DB"; createdb "$DB"
for f in supabase/migrations/*.sql; do
  printf '  %-40s ' "$(basename "$f")"
  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f" >/dev/null && echo OK
done

total=0
for t in engine spin rls accounts backoffice rewards rules storage update1 names delete reason; do
  out=$(psql -d "$DB" -f "tests/${t}_test.sql" 2>&1) || { echo "$out" | grep -iE "error|fail" | head -5; exit 1; }
  n=$(echo "$out" | grep -c 'NOTICE:  ok ')
  total=$((total + n))
  printf '  %-10s %3d passed\n' "$t" "$n"
done
printf '  TOTAL      %3d assertions\n' "$total"

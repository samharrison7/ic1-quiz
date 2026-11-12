#!/usr/bin/env bash
# Runs supabase/schema.sql in a throwaway local Postgres and checks that the
# publishable-key role ("anon") can submit and read counts, and nothing else.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR="$(mktemp -d)"
PORT=54399
trap 'pg_ctl -D "$DIR/data" stop -m immediate >/dev/null 2>&1 || true; rm -rf "$DIR"' EXIT
initdb -D "$DIR/data" -U postgres -A trust >/dev/null
pg_ctl -D "$DIR/data" -o "-p $PORT -k $DIR -c listen_addresses=''" -l "$DIR/log" -w start >/dev/null
P="psql -h $DIR -p $PORT -U postgres -v ON_ERROR_STOP=1 -q"
# Mimic Supabase: these roles exist and get broad default grants on new objects.
$P -c "create role anon nologin; create role authenticated nologin;
       grant usage on schema public to anon, authenticated;
       alter default privileges in schema public grant all on tables to anon, authenticated;
       alter default privileges in schema public grant all on functions to anon, authenticated;"
$P -f supabase/schema.sql
$P -f supabase/schema.sql   # must be safe to run twice

fail=0
ok()  { if $P -c "set role anon; $2" >/dev/null 2>&1; then echo "  ok    $1"; else echo "  FAIL  $1 (should be allowed)"; fail=1; fi; }
no()  { if $P -c "set role anon; $2" >/dev/null 2>&1; then echo "  FAIL  $1 (should be refused)"; fail=1; else echo "  ok    $1 refused"; fi; }
S="select public.submit_response"

ok "valid full answer"        "$S('aaaaaaaa01', '{\"org\":[\"academia\"],\"chem\":[\"pfas\",\"metals\",\"other\"],\"goal\":[\"science\",\"tools\"],\"area\":[\"a\",\"b\",\"c\",\"d\",\"e\"],\"support\":[\"monitoring\"],\"jet\":[\"valve\"]}', '{\"chem\":\"biocides\"}')"
ok "valid partial answer"     "$S('aaaaaaaa02', '{\"jet\":[\"gift\"]}')"
ok "resend of same answer"    "$S('aaaaaaaa02', '{\"jet\":[\"gift\"]}')"
ok "read counts"              "select public.get_results()"
no "empty answers"            "$S('aaaaaaaa03', '{}')"
no "unknown question"         "$S('aaaaaaaa04', '{\"nope\":[\"a\"]}')"
no "unknown option"           "$S('aaaaaaaa05', '{\"org\":[\"aliens\"]}')"
no "two picks on choose-one"  "$S('aaaaaaaa06', '{\"org\":[\"gov\",\"igo\"]}')"
no "four picks on up-to-three" "$S('aaaaaaaa11', '{\"chem\":[\"pfas\",\"metals\",\"pharma\",\"legacy\"]}')"
no "duplicate picks"          "$S('aaaaaaaa07', '{\"goal\":[\"science\",\"science\"]}')"
no "nested array as option"   "$S('aaaaaaaa08', '{\"org\":[[\"gov\"]]}')"
no "typed text too long"      "$S('aaaaaaaa09', '{\"chem\":[\"other\"]}', jsonb_build_object('chem', repeat('x', 81)))"
no "typed text without Other" "$S('aaaaaaaa10', '{\"chem\":[\"pfas\"]}', '{\"chem\":\"hello\"}')"
no "bad client id"            "$S('<script>', '{\"jet\":[\"gift\"]}')"
no "read raw rows"            "select * from public.responses"
no "read export view"         "select * from public.responses_export"
no "insert directly"          "insert into public.responses (client_id, answers) values ('zzzzzzzz01', '{}')"
no "delete rows"              "delete from public.responses"

got="$($P -At -c "select public.get_results()")"
want='{"total": 2, "counts": {"jet": {"gift": 1, "valve": 1}, "org": {"academia": 1}, "area": {"a": 1, "b": 1, "c": 1, "d": 1, "e": 1}, "chem": {"pfas": 1, "other": 1, "metals": 1}, "goal": {"tools": 1, "science": 1}, "support": {"monitoring": 1}}, "answered": {"jet": 2, "org": 1, "area": 1, "chem": 1, "goal": 1, "support": 1}}'
if [ "$got" = "$want" ]; then echo "  ok    counts are correct"; else echo "  FAIL  counts: $got"; fail=1; fi
echo "Export view (as owner):"; $P -c "select organisation, priority_chemicals, priority_chemicals_other, goals, jet_d_eau from public.responses_export"
[ "$fail" = 0 ] && echo "All database checks passed." || { echo "Some checks failed."; exit 1; }

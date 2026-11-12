-- IC1 quiz: database setup for Supabase.
-- Paste the whole file into the Supabase SQL editor and run it once.
-- It is safe to run again: it replaces the functions and keeps existing answers.
--
-- Design: the page only holds the publishable key, so visitors get exactly two
-- abilities, each through a function:
--   submit_response()  add one validated answer sheet
--   get_results()      read counts per option (never individual rows or typed text)
-- The table itself is closed to them.

create table if not exists public.responses (
  id         bigint generated always as identity primary key,
  client_id  text not null unique,           -- random id from the device, so a retried send is not counted twice
  created_at timestamptz not null default now(),
  answers    jsonb not null,                  -- {"org": ["academia"], "goal": ["science", "tools"], ...}
  other      jsonb not null default '{}'      -- typed "Other" text, e.g. {"chem": "biocides"}
);

alter table public.responses enable row level security;
revoke all on public.responses from anon, authenticated;

-- The questions and their allowed option ids. Keep in step with QUESTIONS in index.html.
create or replace function public.quiz_spec()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select '{
    "org":     {"multi": false, "opts": ["gov", "igo", "industry", "finance", "academia", "ngo", "health", "labour", "indigenous", "youth", "other"]},
    "chem":    {"multi": false, "opts": ["pfas", "plastics", "pesticides", "metals", "pharma", "legacy", "other"]},
    "goal":    {"multi": true,  "opts": ["negotiate", "partners", "science", "tools", "funding", "capacity", "showcase", "other"]},
    "area":    {"multi": false, "opts": ["a", "b", "c", "d", "e"]},
    "support": {"multi": true,  "opts": ["monitoring", "modelling", "indicators", "appraisal", "training", "opendata", "other"]},
    "jet":     {"multi": false, "opts": ["fireworks", "valve", "fire", "gift"]}
  }'::jsonb
$$;

create or replace function public.submit_response(
  p_client_id text,
  p_answers   jsonb,
  p_other     jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  spec jsonb := public.quiz_spec();
  k text;
  v jsonb;
  q jsonb;
  n int;
  max_picks int;
begin
  if p_client_id is null or p_client_id !~ '^[a-z0-9]{8,40}$' then
    raise exception 'invalid client id' using errcode = '22023';
  end if;
  if p_answers is null or jsonb_typeof(p_answers) <> 'object' or p_answers = '{}'::jsonb then
    raise exception 'answers must be a non-empty object' using errcode = '22023';
  end if;
  p_other := coalesce(p_other, '{}'::jsonb);
  if jsonb_typeof(p_other) <> 'object' then
    raise exception 'other must be an object' using errcode = '22023';
  end if;

  for k, v in select key, value from jsonb_each(p_answers) loop
    q := spec -> k;
    if q is null or jsonb_typeof(v) <> 'array' then
      raise exception 'unknown question or malformed answer: %', left(k, 20) using errcode = '22023';
    end if;
    n := jsonb_array_length(v);
    max_picks := 1;
    if (q ->> 'multi')::boolean then
      max_picks := jsonb_array_length(q -> 'opts');
    end if;
    if n < 1
       or n > max_picks
       or exists (
         select 1 from jsonb_array_elements(v) e
         where jsonb_typeof(e) <> 'string' or not (q -> 'opts') @> e
       )
       or (select count(distinct e) from jsonb_array_elements(v) e) <> n
    then
      raise exception 'invalid choice for question %', k using errcode = '22023';
    end if;
  end loop;

  for k, v in select key, value from jsonb_each(p_other) loop
    q := spec -> k;
    if q is null
       or jsonb_typeof(v) <> 'string'
       or char_length(v #>> '{}') not between 1 and 80
       or not coalesce(p_answers -> k, '[]'::jsonb) @> '"other"'::jsonb
    then
      raise exception 'invalid typed answer' using errcode = '22023';
    end if;
  end loop;

  -- A ceiling on junk if someone scripts the form. Far above any real booth.
  if (select count(*) from public.responses) >= 20000 then
    raise exception 'response limit reached' using errcode = '53400';
  end if;

  insert into public.responses (client_id, answers, other)
  values (p_client_id, p_answers, p_other)
  on conflict (client_id) do nothing;
end;
$$;

create or replace function public.get_results()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'total', (select count(*) from public.responses),
    'answered', coalesce((
      select jsonb_object_agg(q, n)
      from (
        select e.key as q, count(*) as n
        from public.responses r, jsonb_each(r.answers) e
        group by e.key
      ) a
    ), '{}'::jsonb),
    'counts', coalesce((
      select jsonb_object_agg(q, c)
      from (
        select q, jsonb_object_agg(opt, n) as c
        from (
          select e.key as q, o.value as opt, count(*) as n
          from public.responses r, jsonb_each(r.answers) e, jsonb_array_elements_text(e.value) o
          group by e.key, o.value
        ) x
        group by q
      ) y
    ), '{}'::jsonb)
  )
$$;

revoke all on function public.quiz_spec() from public, anon, authenticated;
revoke all on function public.submit_response(text, jsonb, jsonb) from public;
revoke all on function public.get_results() from public;
grant execute on function public.submit_response(text, jsonb, jsonb) to anon, authenticated;
grant execute on function public.get_results() to anon, authenticated;

-- For you, in the Supabase dashboard (Table Editor > responses_export > Export to CSV):
-- one row per person, one column per question. Not readable with the publishable key.
create or replace view public.responses_export
with (security_invoker = true)
as
select
  created_at as submitted_at,
  answers -> 'org' ->> 0  as organisation,
  other ->> 'org'         as organisation_other,
  answers -> 'chem' ->> 0 as priority_chemicals,
  other ->> 'chem'        as priority_chemicals_other,
  (select string_agg(x, '; ') from jsonb_array_elements_text(answers -> 'goal') x)    as goals,
  other ->> 'goal'        as goals_other,
  answers -> 'area' ->> 0 as area_of_work,
  (select string_agg(x, '; ') from jsonb_array_elements_text(answers -> 'support') x) as scientific_support,
  other ->> 'support'     as scientific_support_other,
  answers -> 'jet' ->> 0  as jet_d_eau
from public.responses
order by created_at;

revoke all on public.responses_export from anon, authenticated;

-- To wipe test answers before the event:
--   truncate public.responses restart identity;

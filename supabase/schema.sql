-- IC1 quiz: database setup for Supabase.
-- Paste the whole file into the Supabase SQL editor and run it once.
-- It is safe to run again: it replaces the functions and view and keeps existing answers.
--
-- Design: the page only holds the publishable key, so visitors get exactly two
-- abilities, each through a function:
--   submit_response()  add one validated answer sheet (and learn if it won a spot prize)
--   get_results()      read counts per option (never individual rows or typed text)
-- The tables themselves are closed to them. The booth team's page (#staff) uses
-- three more functions, which only work with the team passphrase.
--
-- After running this file for the first time, set the team passphrase (at least
-- 8 characters) by running this separately. Do not save it in the repository:
--   update public.quiz_settings set staff_passphrase = 'choose something long' where id;

create table if not exists public.responses (
  id         bigint generated always as identity primary key,
  client_id  text not null unique,           -- random id from the device, so a retried send is not counted twice
  created_at timestamptz not null default now(),
  answers    jsonb not null,                  -- {"org": ["academia"], "goal": ["science", "tools"], ...}
  other      jsonb not null default '{}'      -- typed "Other" text, e.g. {"chem": "biocides"}
);

alter table public.responses enable row level security;
revoke all on public.responses from anon, authenticated;

-- Spot prizes. One row of settings, changed from the #staff page (or here).
create table if not exists public.quiz_settings (
  id                boolean primary key default true check (id),   -- only ever one row
  prizes_on         boolean not null default true,
  prize_one_in      int not null default 25 check (prize_one_in >= 1),      -- chance of winning: 1 in this many
  prizes_total      int not null default 10 check (prizes_total >= 0),      -- stop once this many have been won
  prize_gap_minutes int not null default 20 check (prize_gap_minutes >= 0), -- shortest time between two winners
  staff_passphrase  text
);
insert into public.quiz_settings default values on conflict do nothing;

create table if not exists public.prizes (
  code        text primary key,               -- shown on the winner's screen, checked by the booth team
  response_id bigint not null unique references public.responses (id) on delete cascade,
  won_at      timestamptz not null default now(),
  claimed_at  timestamptz
);

alter table public.quiz_settings enable row level security;
alter table public.prizes enable row level security;
revoke all on public.quiz_settings, public.prizes from anon, authenticated;

-- The questions and their allowed option ids. "multi" allows several picks,
-- "max" caps how many. Keep in step with QUESTIONS in index.html.
create or replace function public.quiz_spec()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select '{
    "org":     {"multi": false, "opts": ["gov", "igo", "industry", "finance", "academia", "ngo", "health", "labour", "indigenous", "youth", "other"]},
    "chem":    {"multi": true,  "max": 3, "opts": ["pfas", "plastics", "pesticides", "metals", "pharma", "legacy", "other"]},
    "goal":    {"multi": true,  "opts": ["negotiate", "partners", "science", "tools", "funding", "capacity", "showcase", "other"]},
    "area":    {"multi": true,  "opts": ["a", "b", "c", "d", "e"]},
    "support": {"multi": true,  "opts": ["monitoring", "modelling", "indicators", "appraisal", "training", "opendata", "other"]},
    "jet":     {"multi": false, "opts": ["fireworks", "valve", "fire", "gift"]}
  }'::jsonb
$$;

-- Returns {"prize": "<code>"} if this answer sheet won a spot prize, else {"prize": null}.
-- p_prize is false when a device sends an answer late (it was offline), because
-- the person is no longer looking at the screen to see a win.
drop function if exists public.submit_response(text, jsonb, jsonb);
create or replace function public.submit_response(
  p_client_id text,
  p_answers   jsonb,
  p_other     jsonb default '{}'::jsonb,
  p_prize     boolean default true
)
returns jsonb
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
  rid bigint;
  v_code text;
  cfg public.quiz_settings%rowtype;
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
      max_picks := coalesce((q ->> 'max')::int, jsonb_array_length(q -> 'opts'));
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
  on conflict (client_id) do nothing
  returning id into rid;

  if not coalesce(p_prize, true) then
    return jsonb_build_object('prize', null);
  end if;

  if rid is null then
    -- A resend of an answer sheet we already have: repeat its result.
    select p.code into v_code
    from public.prizes p join public.responses r on r.id = p.response_id
    where r.client_id = p_client_id;
    return jsonb_build_object('prize', v_code);
  end if;

  -- Spot prize draw. Needs at least four questions answered, so skipping
  -- through doesn't count.
  select * into cfg from public.quiz_settings;
  if cfg.prizes_on and (select count(*) from jsonb_object_keys(p_answers)) >= 4 then
    perform pg_advisory_xact_lock(41001);   -- one draw at a time, so the limits hold
    if (select count(*) from public.prizes) < cfg.prizes_total
       and not exists (
         select 1 from public.prizes
         where won_at > clock_timestamp() - make_interval(mins => cfg.prize_gap_minutes)
       )
       and random() < 1.0 / cfg.prize_one_in
    then
      loop
        -- Four characters, leaving out look-alikes (I, O, 0, 1).
        select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '')
        into v_code
        from generate_series(1, 4);
        exit when not exists (select 1 from public.prizes p where p.code = v_code);
      end loop;
      insert into public.prizes (code, response_id) values (v_code, rid);
    end if;
  end if;

  return jsonb_build_object('prize', v_code);
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
revoke all on function public.submit_response(text, jsonb, jsonb, boolean) from public;
revoke all on function public.get_results() from public;
grant execute on function public.submit_response(text, jsonb, jsonb, boolean) to anon, authenticated;
grant execute on function public.get_results() to anon, authenticated;

-- ---------- Booth team (#staff page) ----------

-- Stops the calling function unless the passphrase is right.
create or replace function public.staff_guard(p_pass text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_real text;
begin
  select staff_passphrase into v_real from public.quiz_settings;
  if v_real is null or char_length(v_real) < 8 or p_pass is null or p_pass <> v_real then
    perform pg_sleep(0.5);   -- slows down guessing
    raise exception 'wrong passphrase' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.staff_prize_status(p_pass text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.staff_guard(p_pass);
  return jsonb_build_object(
    'settings', (
      select jsonb_build_object('on', prizes_on, 'one_in', prize_one_in, 'total', prizes_total, 'gap_minutes', prize_gap_minutes)
      from public.quiz_settings
    ),
    'responses', (select count(*) from public.responses),
    'prizes', coalesce((
      select jsonb_agg(jsonb_build_object('code', code, 'won_at', won_at, 'claimed_at', claimed_at) order by won_at desc)
      from public.prizes
    ), '[]'::jsonb)
  );
end;
$$;

-- Checks a winner's code and marks it as claimed, so a code only works once.
create or replace function public.staff_claim_prize(p_pass text, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
  v_won timestamptz;
  v_claimed timestamptz;
begin
  perform public.staff_guard(p_pass);
  update public.prizes set claimed_at = now()
  where code = v_code and claimed_at is null
  returning won_at into v_won;
  if found then
    return jsonb_build_object('status', 'ok', 'won_at', v_won);
  end if;
  select won_at, claimed_at into v_won, v_claimed from public.prizes where code = v_code;
  if found then
    return jsonb_build_object('status', 'already', 'won_at', v_won, 'claimed_at', v_claimed);
  end if;
  return jsonb_build_object('status', 'unknown');
end;
$$;

create or replace function public.staff_set_prizes(p_pass text, p_on boolean, p_one_in int, p_total int, p_gap_minutes int)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.staff_guard(p_pass);
  update public.quiz_settings
  set prizes_on = p_on, prize_one_in = p_one_in, prizes_total = p_total, prize_gap_minutes = p_gap_minutes
  where id;   -- Supabase refuses an UPDATE without a WHERE when it comes through the API
end;
$$;

revoke all on function public.staff_guard(text) from public, anon, authenticated;
revoke all on function public.staff_prize_status(text) from public;
revoke all on function public.staff_claim_prize(text, text) from public;
revoke all on function public.staff_set_prizes(text, boolean, int, int, int) from public;
grant execute on function public.staff_prize_status(text) to anon, authenticated;
grant execute on function public.staff_claim_prize(text, text) to anon, authenticated;
grant execute on function public.staff_set_prizes(text, boolean, int, int, int) to anon, authenticated;

-- For you, in the Supabase dashboard (Table Editor > responses_export > Export to CSV):
-- one row per person, one column per question. Not readable with the publishable key.
drop view if exists public.responses_export;
create view public.responses_export
with (security_invoker = true)
as
select
  created_at as submitted_at,
  answers -> 'org' ->> 0  as organisation,
  other ->> 'org'         as organisation_other,
  (select string_agg(x, '; ') from jsonb_array_elements_text(answers -> 'chem') x)    as priority_chemicals,
  other ->> 'chem'        as priority_chemicals_other,
  (select string_agg(x, '; ') from jsonb_array_elements_text(answers -> 'goal') x)    as goals,
  other ->> 'goal'        as goals_other,
  (select string_agg(x, '; ') from jsonb_array_elements_text(answers -> 'area') x)    as areas_of_work,
  (select string_agg(x, '; ') from jsonb_array_elements_text(answers -> 'support') x) as scientific_support,
  other ->> 'support'     as scientific_support_other,
  answers -> 'jet' ->> 0  as jet_d_eau,
  (select p.code from public.prizes p where p.response_id = responses.id) as prize_code
from public.responses
order by created_at;

revoke all on public.responses_export from anon, authenticated;

-- To wipe test answers (and any prizes they won) before the event:
--   truncate public.responses restart identity cascade;

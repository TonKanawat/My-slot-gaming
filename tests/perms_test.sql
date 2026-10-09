-- bluePi Slot — who may call what (0028)
-- Runs the website's own calls as the roles Supabase uses (authenticated / anon)
-- rather than as the database owner, which is what every other suite does.
-- Local Postgres only. This truncates tables; never run it against Supabase.

\set ON_ERROR_STOP on
set search_path to slot, public;

create or replace function slot.assert(p_label text, p_got anyelement, p_want anyelement)
returns void language plpgsql as $$
begin
  if p_got is distinct from p_want then
    raise exception 'FAIL % — got %, want %', p_label, p_got, p_want;
  end if;
  raise notice 'ok   %  (%)', p_label, p_got;
end $$;

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
end $$;

-- Re-apply the grants for a database whose roles were created after the
-- migrations ran (the first time this suite runs on a fresh cluster).
select slot.tidy_permissions();
grant usage on schema slot to anon, authenticated;
grant select on all tables in schema public to authenticated;
-- The test helper itself must be callable by every role this suite becomes.
grant execute on function slot.assert(text, anyelement, anyelement) to public;

-- A stand-in for Supabase's auth.uid(), so slot.play() and friends see a signed-in
-- user exactly as they do on Supabase. Dropped again at the end of this suite.
create schema if not exists auth;
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant usage on schema auth to anon, authenticated;
grant execute on function auth.uid() to public;

delete from slot.deleted_user;
delete from slot.point_request;
delete from slot.reward_claim;
delete from slot.spin_log;
delete from slot.ledger;
delete from slot.free_spin_state;
delete from slot.wallet;
delete from slot.app_user;
truncate slot.combination_symbol, slot.combination, slot.symbol cascade;

insert into slot.app_user (id, auth_user_id, email, role, first_login_at) values
  ('11110000-0000-0000-0000-000000000001', '11110000-0000-0000-0000-000000000001', 'master@bluepi.co.th', 'system_admin', now()),
  ('33330000-0000-0000-0000-000000000003', '33330000-0000-0000-0000-000000000003', 'p1@bluepi.co.th',     'player',       now());
insert into slot.wallet (user_id, free_points, points)
select id, 1000, 0 from slot.app_user;

insert into slot.symbol (name, image_path)
select 'S'||i, i||'.png' from generate_series(1, 8) i;
insert into slot.combination (name, bonus) values ('All', 0);
insert into slot.combination_symbol
select (select id from slot.combination), id from slot.symbol;

-- ---------------------------------------------------------------- a signed-in player
set role authenticated;
set request.jwt.claim.sub = '33330000-0000-0000-0000-000000000003';
do $$
declare r jsonb; n int; denied boolean; g uuid[];
begin
  perform slot.assert('the game is ready for a player', (public.game_ready()->>'ready')::boolean, true);
  r := public.play(25);
  perform slot.assert('a player can spin through the website call', (r ? 'grid'), true);
  perform slot.assert('and is charged', (select free_points from public.my_wallet()), 975::bigint);
  -- The grid the server just drew, turned back into uuid[][] the way the page sends it.
  g := array(select array(select (r->'grid'->i->>j)::uuid from generate_series(0, 4) j)
               from generate_series(0, 4) i);
  perform slot.assert('can ask why lines won', jsonb_array_length(to_jsonb(public.explain_grid(g))), 29);
  perform slot.assert('can read the ranking', (select count(*)::int from public.ranking()), 2);
  perform slot.assert('can read the grant schedule', (public.grant_schedule() ? 'days'), true);
  perform slot.assert('can read free spins', (select count(*)::int from public.my_free_spins()) <= 1, true);
  perform slot.assert('can check a display name', (public.check_display_name('Fluke')->>'ok')::boolean, true);
  perform slot.assert('can set their display name', public.set_display_name('Fluke')->>'display_name', 'Fluke');
  select count(*)::int into n from public.game_symbols;
  perform slot.assert('can read the symbols', n, 8);
  select count(*)::int into n from public.winning_combinations;
  perform slot.assert('can read the groups', n, 1);

  -- Admin-only calls still answer "admins only", not a permission error.
  denied := false;
  begin perform public.storage_report(); exception when insufficient_privilege then denied := true; end;
  perform slot.assert('admin calls still refuse a player', denied, true);

  -- The engine's internals are not callable directly.
  denied := false;
  begin
    perform slot.apply_spin('33330000-0000-0000-0000-000000000003', 25,
      '{"multiplier": 6, "free_spins": 0}'::jsonb, false);
  exception when insufficient_privilege then denied := true; end;
  perform slot.assert('nobody can call apply_spin directly', denied, true);

  denied := false;
  begin perform slot.spin('33330000-0000-0000-0000-000000000003', 25);
  exception when insufficient_privilege then denied := true; end;
  perform slot.assert('nor spin on someone else''s behalf', denied, true);

  denied := false;
  begin perform slot.evaluate_grid(slot.draw_grid());
  exception when insufficient_privilege then denied := true; end;
  perform slot.assert('nor the scoring engine', denied, true);

  denied := false;
  begin perform slot.grant_free_points();
  exception when insufficient_privilege then denied := true; end;
  perform slot.assert('nor the scheduled grant', denied, true);
end $$;
reset role;

-- ---------------------------------------------------------------- an admin
set role authenticated;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000001';
do $$
begin
  perform slot.assert('an admin reads the storage gauge', (public.storage_report() ? 'database_bytes'), true);
  perform slot.assert('and the rules', (public.game_rules() is not null), true);
  perform slot.assert('and runs the simulation', ((public.simulate_lines(50)->>'spins')::int), 50);
  perform slot.assert('and sees people', (select count(*)::int from public.players), 2);
end $$;
reset role;

-- ---------------------------------------------------------------- signed out
set role anon;
set request.jwt.claim.sub = '';
do $$
declare denied boolean := false;
begin
  begin perform public.play(25); exception when insufficient_privilege then denied := true; end;
  perform slot.assert('signed out: no website function can be called', denied, true);
  -- The row-level-security helpers stay callable, so a policy check never errors.
  perform slot.assert('signed out: the RLS helpers still answer', slot.is_admin(), false);
end $$;
reset role;
reset request.jwt.claim.sub;

-- ---------------------------------------------------------------- search paths
do $$
declare n int;
begin
  select count(*)::int into n from pg_proc p
   where p.pronamespace in ('slot'::regnamespace, 'public'::regnamespace)
     and p.prokind = 'f' and p.proconfig is null
     and (p.pronamespace = 'slot'::regnamespace or p.prosrc like '%slot.%')
     and p.proname <> 'assert';
  perform slot.assert('every game function has a fixed search_path', n, 0);
end $$;

drop schema auth cascade;

\echo ''
\echo 'All permission tests passed.'

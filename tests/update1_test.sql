-- bluePi Slot — Update 1: display names, ranking, grant schedule, point requests
-- Run:  psql -f tests/update1_test.sql
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

-- Runs p_sql and reports whether it failed with the expected SQLSTATE.
create or replace function slot.refused(p_sql text, p_state text)
returns boolean language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  if sqlstate = p_state then return true; end if;
  raise notice 'unexpected %: %', sqlstate, sqlerrm;
  return false;
end $$;

delete from slot.point_request;
delete from slot.reward_claim;
delete from slot.spin_log;
delete from slot.ledger;
delete from slot.free_spin_state;
delete from slot.wallet;
delete from slot.app_user;
delete from slot.setting where key = 'last_free_grant';
update slot.setting set value = '[200,0,200,0,200,0,0]'::jsonb where key = 'free_point_schedule';
update slot.setting set value = 'true'::jsonb  where key = 'free_point_ceiling_on';
update slot.setting set value = '1000'::jsonb  where key = 'free_point_ceiling';

insert into slot.app_user (id, email, role, display_name, first_login_at) values
  ('11110000-0000-0000-0000-000000000001', 'master@bluepi.co.th', 'system_admin', 'Ton',  now()),
  ('22220000-0000-0000-0000-000000000002', 'lead@bluepi.co.th',   'line_manager', 'Lead', now()),
  ('23230000-0000-0000-0000-000000000023', 'lead2@bluepi.co.th',  'line_manager', null,   now()),
  ('33330000-0000-0000-0000-000000000003', 'p1@bluepi.co.th',     'player',       'Aof',  now()),
  ('44440000-0000-0000-0000-000000000004', 'p2@bluepi.co.th',     'player',       null,   now()),
  ('55550000-0000-0000-0000-000000000005', 'new@bluepi.co.th',    'player',       null,   null);
insert into slot.wallet (user_id, free_points, points) values
  ('11110000-0000-0000-0000-000000000001',    0, 1200),
  ('22220000-0000-0000-0000-000000000002',    0,  800),
  ('23230000-0000-0000-0000-000000000023',    0,    0),
  ('33330000-0000-0000-0000-000000000003',  837, 5000),
  ('44440000-0000-0000-0000-000000000004',    0,  800),
  ('55550000-0000-0000-0000-000000000005',    0,    0);

-- ================================================================ display names
set slot.test_user = '44440000-0000-0000-0000-000000000004';
do $$
declare r jsonb;
begin
  r := slot.set_display_name('   Min    Kanya  ');
  perform slot.assert('a name is trimmed and its spaces collapsed', r->>'display_name', 'Min Kanya');
  perform slot.assert('and saved on the account',
    (select display_name from slot.app_user where id = '44440000-0000-0000-0000-000000000004'), 'Min Kanya');

  perform slot.assert('one character is too short',
    slot.refused($q$select slot.set_display_name('M')$q$, '23514'), true);
  perform slot.assert('31 characters is too long',
    slot.refused(format('select slot.set_display_name(%L)', repeat('x', 31)), '23514'), true);
  perform slot.assert('someone else''s name is refused, whatever the case',
    slot.refused($q$select slot.set_display_name('aOF')$q$, '23505'), true);

  r := slot.set_display_name('min kanya');
  perform slot.assert('re-casing your own name is fine', r->>'display_name', 'min kanya');
end $$;

reset slot.test_user;
do $$
begin
  perform slot.assert('signed-out callers cannot rename anyone',
    slot.refused($q$select slot.set_display_name('Ghost')$q$, '42501'), true);
end $$;

-- ================================================================ ranking
set slot.test_user = '44440000-0000-0000-0000-000000000004';
do $$
declare n int; r record;
begin
  select count(*)::int into n from slot.ranking();
  perform slot.assert('everyone who has signed in is ranked; the never-signed-in are not', n, 5);

  select * into r from slot.ranking() order by rank, name limit 1;
  perform slot.assert('the most Wallet points ranks first', r.name, 'Aof');
  perform slot.assert('ranked by Wallet points, not free points', r.points, 5000::bigint);

  select count(*)::int into n from slot.ranking() where rank = 3;
  perform slot.assert('equal points share a rank', n, 2);
  select min(rank)::int into n from slot.ranking() where points = 0;
  perform slot.assert('and the next rank skips past the tie (1, 2, 3, 3, 5)', n, 5);

  select count(*)::int into n from slot.ranking() where is_me;
  perform slot.assert('the caller is marked', n, 1);
  select name into r from slot.ranking() where is_me;
  perform slot.assert('with their new display name', r.name, 'min kanya');

  perform slot.assert('no display name falls back to the address before the @',
    (select name from slot.ranking() where user_id = '23230000-0000-0000-0000-000000000023'), 'lead2');
end $$;
reset slot.test_user;
do $$
begin
  perform slot.assert('the ranking needs a sign-in',
    slot.refused('select * from slot.ranking()', '42501'), true);
end $$;

-- ================================================================ grant schedule
do $$
declare n int; f bigint;
begin
  -- 2026-09-29 is a Tuesday: nothing is due by default.
  n := slot.grant_free_points('2026-09-29');
  perform slot.assert('a day with no amount pays nobody', n, 0);

  -- 2026-09-28 is a Monday: 200, topped up to the ceiling.
  n := slot.grant_free_points('2026-09-28');
  select free_points into f from slot.wallet where user_id = '33330000-0000-0000-0000-000000000003';
  perform slot.assert('ceiling on: 837 tops up to exactly 1,000', f, 1000::bigint);
  select free_points into f from slot.wallet where user_id = '44440000-0000-0000-0000-000000000004';
  perform slot.assert('ceiling on: 0 gets the day''s 200', f, 200::bigint);
  perform slot.assert('the ledger names the day',
    (select note from slot.ledger where reason = 'scheduled_grant' limit 1), 'Monday grant');

  n := slot.grant_free_points('2026-09-28');
  perform slot.assert('the same day is never paid twice', n, 0);
  perform slot.assert('and the last run is recorded',
    (select value->>'day' from slot.setting where key = 'last_free_grant'), '2026-09-28');
end $$;

set slot.test_user = '11110000-0000-0000-0000-000000000001';
do $$
declare r jsonb; n int; f bigint;
begin
  -- Tuesday 300, Saturday 50, ceiling off.
  r := slot.save_grant_schedule(array[0,300,0,0,0,50,0], false, 1500);
  perform slot.assert('the admin saves the weekdays', r->'days', '[0,300,0,0,0,50,0]'::jsonb);
  perform slot.assert('and switches the ceiling off', (r->>'ceiling_on')::boolean, false);
  perform slot.assert('and can change the ceiling value', (r->>'ceiling')::int, 1500);

  n := slot.grant_free_points('2026-09-29');   -- Tuesday
  select free_points into f from slot.wallet where user_id = '33330000-0000-0000-0000-000000000003';
  perform slot.assert('ceiling off: the full 300 lands even above the old ceiling', f, 1300::bigint);
  perform slot.assert('everyone active is paid', n, 6);

  n := slot.grant_free_points('2026-09-30');   -- Wednesday, now switched off
  perform slot.assert('a day switched off pays nothing', n, 0);

  -- Ceiling back on at 1,500: 1,300 gets 200 of the 300; the rest get the full 300.
  perform slot.save_grant_schedule(array[0,300,0,0,0,50,0], true, 1500);
  perform slot.grant_free_points('2026-10-06');  -- the next Tuesday
  select free_points into f from slot.wallet where user_id = '33330000-0000-0000-0000-000000000003';
  perform slot.assert('ceiling on again: tops up to the new 1,500', f, 1500::bigint);

  perform slot.assert('six amounts are refused',
    slot.refused('select slot.save_grant_schedule(array[1,2,3,4,5,6], true, 1000)', '23514'), true);
  perform slot.assert('a negative amount is refused',
    slot.refused('select slot.save_grant_schedule(array[0,-1,0,0,0,0,0], true, 1000)', '23514'), true);
  perform slot.assert('a zero ceiling is refused',
    slot.refused('select slot.save_grant_schedule(array[0,0,0,0,0,0,0], true, 0)', '23514'), true);

  r := slot.grant_schedule();
  perform slot.assert('the next grant is reported with its amount',
    ((r->'next'->>'amount')::int in (300, 50)), true);
end $$;

set slot.test_user = '33330000-0000-0000-0000-000000000003';
do $$
begin
  perform slot.assert('a player can read the schedule', (slot.grant_schedule() ? 'days'), true);
  perform slot.assert('but not change it',
    slot.refused('select slot.save_grant_schedule(array[9,9,9,9,9,9,9], false, 5)', '42501'), true);
end $$;

-- ================================================================ point requests
-- The line manager.
set slot.test_user = '22220000-0000-0000-0000-000000000002';
do $$
declare r jsonb; n int;
begin
  select count(*)::int into n from slot.request_targets();
  perform slot.assert('targets: the three players plus the manager', n, 4);
  select count(*)::int into n from slot.request_targets() where is_self;
  perform slot.assert('the manager is on the list as themselves', n, 1);
  select count(*)::int into n from slot.request_targets()
   where id in ('11110000-0000-0000-0000-000000000001', '23230000-0000-0000-0000-000000000023');
  perform slot.assert('admins and other managers are not', n, 0);

  r := slot.request_points('33330000-0000-0000-0000-000000000003', 1000000, 'quarter prize');
  perform slot.assert('a manager can ask for a player — no limit on the amount',
    (r->>'request_id') is not null, true);
  perform slot.assert('it expires 72 hours later',
    round(extract(epoch from ((r->>'expires_at')::timestamptz - now())) / 3600), 72::numeric);

  r := slot.request_points('22220000-0000-0000-0000-000000000002', 700, 'for running the demo');
  perform slot.assert('a manager can ask for themselves', (r->>'request_id') is not null, true);

  perform slot.request_points('44440000-0000-0000-0000-000000000004', 50, 'Bug bash helper');
  perform slot.request_points('44440000-0000-0000-0000-000000000004', 60, 'Bug bash winner');

  perform slot.assert('not for another line manager',
    slot.refused($q$select slot.request_points('23230000-0000-0000-0000-000000000023', 10)$q$, '42501'), true);
  perform slot.assert('not for an admin',
    slot.refused($q$select slot.request_points('11110000-0000-0000-0000-000000000001', 10)$q$, '42501'), true);
  perform slot.assert('zero points is refused',
    slot.refused($q$select slot.request_points('33330000-0000-0000-0000-000000000003', 0)$q$, '23514'), true);

  select count(*)::int into n from slot.point_requests();
  perform slot.assert('the manager sees every request they made', n, 4);
  select count(*)::int into n from slot.point_requests() where status = 'pending' and reminder is null;
  perform slot.assert('fresh requests carry no reminder yet', n, 4);
end $$;

-- Players.
set slot.test_user = '33330000-0000-0000-0000-000000000003';
do $$
declare n int;
begin
  perform slot.assert('a player cannot request free points',
    slot.refused($q$select slot.request_points('33330000-0000-0000-0000-000000000003', 10)$q$, '42501'), true);
  perform slot.assert('or list who to ask for',
    slot.refused('select * from slot.request_targets()', '42501'), true);
  select count(*)::int into n from slot.point_requests();
  perform slot.assert('a player sees the request made for them, and no other', n, 1);
  perform slot.assert('a player cannot approve',
    slot.refused('select slot.decide_point_request((select min(id) from slot.point_request), true)', '42501'), true);
  perform slot.assert('or cancel someone else''s request',
    slot.refused('select slot.cancel_point_request((select min(id) from slot.point_request))', '42501'), true);
end $$;

-- The admin decides.
set slot.test_user = '11110000-0000-0000-0000-000000000001';
do $$
declare r jsonb; big bigint; me_id bigint; f bigint; n int; l slot.ledger%rowtype;
begin
  select count(*)::int into n from slot.point_requests() where status = 'pending';
  perform slot.assert('the admin sees every pending request', n, 4);

  select id into big from slot.point_request where amount = 1000000;
  r := slot.decide_point_request(big, true, 'well played');
  perform slot.assert('approval is recorded', r->>'status', 'approved');
  select free_points into f from slot.wallet where user_id = '33330000-0000-0000-0000-000000000003';
  perform slot.assert('the full million lands in free points — no ceiling', f, 1001500::bigint);
  select * into l from slot.ledger where reason = 'request_grant' order by id desc limit 1;
  perform slot.assert('the ledger records the grant', l.free_delta, 1000000::bigint);
  perform slot.assert('with the approving admin', l.actor_id, '11110000-0000-0000-0000-000000000001'::uuid);
  perform slot.assert('and who asked', l.note, format('request #%s from lead@bluepi.co.th', big));

  perform slot.assert('a decided request cannot be decided again',
    slot.refused(format('select slot.decide_point_request(%s, true)', big), '23514'), true);

  select id into me_id from slot.point_request where amount = 700;
  r := slot.decide_point_request(me_id, false, 'not this month');
  select free_points into f from slot.wallet where user_id = '22220000-0000-0000-0000-000000000002';
  perform slot.assert('a declined request pays nothing', f, 800::bigint);
end $$;

-- The manager cancels one of theirs.
set slot.test_user = '22220000-0000-0000-0000-000000000002';
do $$
declare r jsonb; rid bigint;
begin
  select id into rid from slot.point_request where amount = 50;
  r := slot.cancel_point_request(rid);
  perform slot.assert('the requester can cancel while it waits', r->>'status', 'cancelled');
  perform slot.assert('but not twice',
    slot.refused(format('select slot.cancel_point_request(%s)', rid), '23514'), true);
  perform slot.assert('and not a decided one',
    slot.refused('select slot.cancel_point_request((select id from slot.point_request where amount = 700))', '23514'), true);
end $$;

-- Reminders and expiry. Move the last pending request's deadline around by hand.
reset slot.test_user;
do $$
declare rid bigint;
begin
  select id into rid from slot.point_request where amount = 60;
  update slot.point_request set expires_at = now() + interval '40 hours' where id = rid;
end $$;
set slot.test_user = '11110000-0000-0000-0000-000000000001';
do $$
begin
  perform slot.assert('under 48 hours left shows the 48-hour warning',
    (select reminder from slot.point_requests() where amount = 60), '48h');
end $$;
reset slot.test_user;
update slot.point_request set expires_at = now() + interval '20 hours' where amount = 60;
set slot.test_user = '11110000-0000-0000-0000-000000000001';
do $$
begin
  perform slot.assert('under 24 hours, the 24-hour warning',
    (select reminder from slot.point_requests() where amount = 60), '24h');
end $$;
reset slot.test_user;
update slot.point_request set expires_at = now() + interval '3 hours' where amount = 60;
set slot.test_user = '11110000-0000-0000-0000-000000000001';
do $$
begin
  perform slot.assert('under 12 hours, the 12-hour warning',
    (select reminder from slot.point_requests() where amount = 60), '12h');
end $$;
reset slot.test_user;
update slot.point_request set expires_at = now() - interval '1 minute' where amount = 60;
set slot.test_user = '11110000-0000-0000-0000-000000000001';
do $$
declare n int;
begin
  perform slot.assert('past the deadline it reads as expired straight away',
    (select status from slot.point_requests() where amount = 60), 'expired');
  perform slot.assert('and can no longer be approved',
    slot.refused('select slot.decide_point_request((select id from slot.point_request where amount = 60), true)', '23514'), true);
  n := slot.expire_point_requests();
  perform slot.assert('the hourly job marks it expired for good', n, 1);
  perform slot.assert('stored as expired',
    (select status::text from slot.point_request where amount = 60), 'expired');
end $$;

-- ---------------------------------------------------------------- row-level security
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'slot_client') then
    create role slot_client nologin;
  end if;
end $$;
grant usage on schema slot to slot_client;
grant select on slot.point_request to slot_client;

set role slot_client;
set slot.test_user = '44440000-0000-0000-0000-000000000004';
do $$
declare n int;
begin
  select count(*)::int into n from slot.point_request;
  perform slot.assert('RLS: a player reads only the requests made for them', n, 2);
end $$;
set slot.test_user = '23230000-0000-0000-0000-000000000023';
do $$
declare n int;
begin
  select count(*)::int into n from slot.point_request;
  perform slot.assert('RLS: another manager reads none of them', n, 0);
end $$;
reset role;
reset slot.test_user;

drop function slot.refused(text, text);

\echo ''
\echo 'All Update 1 tests passed.'

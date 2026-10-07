-- bluePi Slot — a line manager's request must say why (0026)
-- Run:  psql -f tests/reason_test.sql
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

delete from slot.deleted_user;
delete from slot.point_request;
delete from slot.reward_claim;
delete from slot.spin_log;
delete from slot.ledger;
delete from slot.free_spin_state;
delete from slot.wallet;
delete from slot.app_user;

insert into slot.app_user (id, email, role) values
  ('22220000-0000-0000-0000-000000000002', 'lead@bluepi.co.th', 'line_manager'),
  ('33330000-0000-0000-0000-000000000003', 'aof@bluepi.co.th',  'player');
insert into slot.wallet (user_id) select id from slot.app_user;

set slot.test_user = '22220000-0000-0000-0000-000000000002';
do $$
declare r jsonb; n int;
begin
  perform slot.assert('no description is refused',
    slot.refused($q$select slot.request_points('33330000-0000-0000-0000-000000000003', 500)$q$, '23514'), true);
  perform slot.assert('an empty description is refused',
    slot.refused($q$select slot.request_points('33330000-0000-0000-0000-000000000003', 500, '')$q$, '23514'), true);
  perform slot.assert('spaces only are refused',
    slot.refused($q$select slot.request_points('33330000-0000-0000-0000-000000000003', 500, '      ')$q$, '23514'), true);
  perform slot.assert('four characters is too short',
    slot.refused($q$select slot.request_points('33330000-0000-0000-0000-000000000003', 500, ' abcd ')$q$, '23514'), true);
  perform slot.assert('301 characters is too long',
    slot.refused(format('select slot.request_points(%L, 500, %L)',
                        '33330000-0000-0000-0000-000000000003', repeat('x', 301)), '23514'), true);
  perform slot.assert('an amount is still required',
    slot.refused($q$select slot.request_points('33330000-0000-0000-0000-000000000003', null, 'Sprint demo winner')$q$, '23514'), true);

  select count(*)::int into n from slot.point_request;
  perform slot.assert('none of those created a request', n, 0);

  r := slot.request_points('33330000-0000-0000-0000-000000000003', 500, '   Sprint   demo winner  ');
  perform slot.assert('a proper description is accepted', (r->>'request_id') is not null, true);
  perform slot.assert('and stored tidied',
    (select note from slot.point_request order by id desc limit 1), 'Sprint demo winner');
  perform slot.assert('the admin sees it with the request',
    (select note from slot.point_requests() limit 1), 'Sprint demo winner');

  r := slot.request_points('22220000-0000-0000-0000-000000000002', 300, 'คัดเลือกทีม');
  perform slot.assert('Thai text counts like any other', (r->>'request_id') is not null, true);
end $$;

reset slot.test_user;
drop function slot.refused(text, text);

\echo ''
\echo 'All request-reason tests passed.'

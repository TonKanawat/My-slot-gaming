-- bluePi Slot — display-name duplicate warnings (0024)
-- Run:  psql -f tests/names_test.sql
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

delete from slot.point_request;
delete from slot.reward_claim;
delete from slot.spin_log;
delete from slot.ledger;
delete from slot.free_spin_state;
delete from slot.wallet;
delete from slot.app_user;

insert into slot.app_user (id, email, role, display_name, first_login_at) values
  ('11110000-0000-0000-0000-000000000001', 'master@bluepi.co.th', 'system_admin', 'Ton',       now()),
  ('33330000-0000-0000-0000-000000000003', 'aof@bluepi.co.th',    'player',       'Aof',       now()),
  ('44440000-0000-0000-0000-000000000004', 'min@bluepi.co.th',    'player',       'Min Kanya', now()),
  -- No display name: everyone sees "noey".
  ('55550000-0000-0000-0000-000000000005', 'noey@bluepi.co.th',   'player',       null,        now()),
  -- Two people already sharing a name, from before anything checked.
  ('66660000-0000-0000-0000-000000000006', 'jay1@bluepi.co.th',   'player',       'Jay',       now()),
  ('77770000-0000-0000-0000-000000000007', 'jay2@bluepi.co.th',   'player',       ' jay ',     now()),
  -- Deactivated people don't hold on to their name.
  ('88880000-0000-0000-0000-000000000008', 'gone@bluepi.co.th',   'player',       'Sun',       now());
update slot.app_user set is_active = false where id = '88880000-0000-0000-0000-000000000008';
insert into slot.wallet (user_id) select id from slot.app_user;

-- ---------------------------------------------------------------- the live check (player)
set slot.test_user = '44440000-0000-0000-0000-000000000004';
do $$
declare r jsonb;
begin
  r := slot.check_display_name('Fluke');
  perform slot.assert('a free name is fine', (r->>'ok')::boolean, true);

  r := slot.check_display_name('  aOF ');
  perform slot.assert('a taken name is flagged, whatever the case and spacing', (r->>'ok')::boolean, false);
  perform slot.assert('and the reason is that it is taken', r->>'reason', 'taken');
  perform slot.assert('naming the name as others see it', r->>'taken_by', 'Aof');
  perform slot.assert('a player is not told the holder''s email', r->>'taken_by_email', null::text);
  perform slot.assert('with a message to show', (r->>'message') like '“Aof” is already used%', true);

  r := slot.check_display_name('min   kanya');
  perform slot.assert('your own current name is not "taken"', (r->>'ok')::boolean, true);

  r := slot.check_display_name('Noey');
  perform slot.assert('the email-based name of someone with no display name is protected too',
    r->>'taken_by', 'noey');

  r := slot.check_display_name('Sun');
  perform slot.assert('a deactivated person''s old name is free again', (r->>'ok')::boolean, true);

  r := slot.check_display_name('M');
  perform slot.assert('too short is reported as a length problem', r->>'reason', 'length');

  perform slot.assert('a player cannot check names for new registrations',
    slot.refused($q$select slot.check_display_name('Fluke', true)$q$, '42501'), true);
end $$;

-- ---------------------------------------------------------------- saving still enforces it
do $$
begin
  perform slot.assert('saving a taken name is refused',
    slot.refused($q$select slot.set_display_name('AOF')$q$, '23505'), true);
  perform slot.assert('saving someone''s email-based name is refused',
    slot.refused($q$select slot.set_display_name('noey')$q$, '23505'), true);
  perform slot.assert('the name was left unchanged',
    (select display_name from slot.app_user where id = '44440000-0000-0000-0000-000000000004'), 'Min Kanya');
end $$;

-- ---------------------------------------------------------------- admins
set slot.test_user = '11110000-0000-0000-0000-000000000001';
do $$
declare r jsonb; n int; d record;
begin
  r := slot.check_display_name('aof', true);
  perform slot.assert('an admin sees who holds the name', r->>'taken_by_email', 'aof@bluepi.co.th');

  r := slot.check_display_name('Ton', true);
  perform slot.assert('checking for a new person, even the admin''s own name counts', (r->>'ok')::boolean, false);

  perform slot.assert('registering someone with a taken display name is refused',
    slot.refused($q$select slot.register_email('new1@bluepi.co.th', 'Min  kanya')$q$, '23505'), true);
  perform slot.register_email('new2@bluepi.co.th', '  Fluke   Jr ');
  perform slot.assert('a free name registers, tidied',
    (select display_name from slot.app_user where email = 'new2@bluepi.co.th'), 'Fluke Jr');
  perform slot.register_email('new3@bluepi.co.th');
  perform slot.assert('registering with no name still works',
    (select display_name from slot.app_user where email = 'new3@bluepi.co.th'), null::text);

  select count(*)::int into n from slot.duplicate_names();
  perform slot.assert('the back office lists names already shared', n, 1);
  select * into d from slot.duplicate_names();
  perform slot.assert('by how many people', d.people, 2);
  perform slot.assert('with their addresses', d.emails, array['jay1@bluepi.co.th','jay2@bluepi.co.th']);
end $$;

set slot.test_user = '33330000-0000-0000-0000-000000000003';
do $$
begin
  perform slot.assert('players cannot list duplicates',
    slot.refused('select * from slot.duplicate_names()', '42501'), true);
end $$;

-- One of the Jays renames: the clash is gone.
set slot.test_user = '77770000-0000-0000-0000-000000000007';
do $$
begin
  perform slot.set_display_name('Jay QA');
end $$;
set slot.test_user = '11110000-0000-0000-0000-000000000001';
do $$
declare n int;
begin
  select count(*)::int into n from slot.duplicate_names();
  perform slot.assert('after a rename nobody shares a name', n, 0);
end $$;

reset slot.test_user;
drop function slot.refused(text, text);

\echo ''
\echo 'All name tests passed.'

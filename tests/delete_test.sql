-- bluePi Slot — deleting a person (0025)
-- Run:  psql -f tests/delete_test.sql
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

insert into slot.app_user (id, email, role, display_name, first_login_at) values
  ('11110000-0000-0000-0000-000000000001', 'master@bluepi.co.th', 'system_admin', 'Ton',    now()),
  ('12120000-0000-0000-0000-000000000012', 'deputy@bluepi.co.th', 'deputy_admin', 'Dep',    now()),
  ('13130000-0000-0000-0000-000000000013', 'deputy2@bluepi.co.th','deputy_admin', 'Dep2',   now()),
  ('22220000-0000-0000-0000-000000000002', 'lead@bluepi.co.th',   'line_manager', 'Lead',   now()),
  ('33330000-0000-0000-0000-000000000003', 'aof@bluepi.co.th',    'player',       'Aof',    now()),
  ('44440000-0000-0000-0000-000000000004', 'min@bluepi.co.th',    'player',       'Min',    now());
insert into slot.wallet (user_id, free_points, points) values
  ('11110000-0000-0000-0000-000000000001',   0,    0),
  ('12120000-0000-0000-0000-000000000012',   0,    0),
  ('13130000-0000-0000-0000-000000000013',   0,    0),
  ('22220000-0000-0000-0000-000000000002', 500,    0),
  ('33330000-0000-0000-0000-000000000003', 640, 3000),
  ('44440000-0000-0000-0000-000000000004', 100,  200);

-- Give Aof a history: a spin, a pending prize claim (2,000 held), and an admin edit
-- made BY the deputy on Min's wallet, so deleting the deputy later must not fail.
insert into slot.spin_log (user_id, bet, is_free, line_count, multiplier, payout, free_spins, grid)
values ('33330000-0000-0000-0000-000000000003', 25, false, 0, 0, 0, 0, decode(repeat('00', 50), 'hex'));
insert into slot.reward_claim (user_id, reward_id, reward_name, price)
select '33330000-0000-0000-0000-000000000003', id, name, price from slot.reward where name = 'Bronze Coin';
insert into slot.ledger (user_id, reason, free_delta, points_delta, free_after, points_after, actor_id, note)
values ('44440000-0000-0000-0000-000000000004', 'admin_edit', 100, 0, 100, 200,
        '12120000-0000-0000-0000-000000000012', 'from the deputy'),
       ('33330000-0000-0000-0000-000000000003', 'bet', -25, 0, 640, 3000, null, null);
-- A pending request by the line manager for Aof.
insert into slot.point_request (requested_by, target_id, amount, expires_at)
values ('22220000-0000-0000-0000-000000000002', '33330000-0000-0000-0000-000000000003', 300, now() + interval '72 hours');

-- ---------------------------------------------------------------- the preview
set slot.test_user = '12120000-0000-0000-0000-000000000012';   -- a deputy
do $$
declare p jsonb;
begin
  p := slot.delete_preview('33330000-0000-0000-0000-000000000003');
  perform slot.assert('the preview names the person', p->>'name', 'Aof');
  perform slot.assert('shows their free points', (p->>'free_points')::bigint, 640::bigint);
  perform slot.assert('and Wallet', (p->>'points')::bigint, 3000::bigint);
  perform slot.assert('their spins', (p->>'spins')::int, 1);
  perform slot.assert('points held by a pending claim', (p->>'held_points')::int, 2000);
  perform slot.assert('pending requests involving them', (p->>'pending_requests')::int, 1);
  perform slot.assert('and that the deletion is allowed', (p->>'allowed')::boolean, true);

  p := slot.delete_preview('11110000-0000-0000-0000-000000000001');
  perform slot.assert('the master is shown as not deletable', (p->>'allowed')::boolean, false);
  p := slot.delete_preview('13130000-0000-0000-0000-000000000013');
  perform slot.assert('a deputy cannot delete another deputy', p->>'blocked_reason',
    'only the master admin can delete a deputy admin');
  p := slot.delete_preview('12120000-0000-0000-0000-000000000012');
  perform slot.assert('nor themselves', p->>'blocked_reason', 'you cannot delete your own account');
end $$;

-- ---------------------------------------------------------------- the confirmation
do $$
declare n int;
begin
  perform slot.assert('no confirmation, no deletion',
    slot.refused($q$select slot.delete_user('33330000-0000-0000-0000-000000000003', null)$q$, '23514'), true);
  perform slot.assert('the wrong email, no deletion',
    slot.refused($q$select slot.delete_user('33330000-0000-0000-0000-000000000003', 'min@bluepi.co.th')$q$, '23514'), true);
  select count(*)::int into n from slot.app_user where id = '33330000-0000-0000-0000-000000000003';
  perform slot.assert('Aof is still there after both refusals', n, 1);

  perform slot.assert('the master cannot be deleted',
    slot.refused($q$select slot.delete_user('11110000-0000-0000-0000-000000000001', 'master@bluepi.co.th')$q$, '42501'), true);
  perform slot.assert('a deputy cannot delete a deputy',
    slot.refused($q$select slot.delete_user('13130000-0000-0000-0000-000000000013', 'deputy2@bluepi.co.th')$q$, '42501'), true);
  perform slot.assert('no one can delete themselves',
    slot.refused($q$select slot.delete_user('12120000-0000-0000-0000-000000000012', 'deputy@bluepi.co.th')$q$, '42501'), true);
end $$;

-- ---------------------------------------------------------------- the deletion
do $$
declare r jsonb; n int; d slot.deleted_user;
begin
  -- Typed with different case and spaces: still the same address.
  r := slot.delete_user('33330000-0000-0000-0000-000000000003', '  AOF@bluepi.co.th ', 'left the company');
  perform slot.assert('the right email deletes', r->>'deleted', 'aof@bluepi.co.th');

  select count(*)::int into n from slot.app_user where id = '33330000-0000-0000-0000-000000000003';
  perform slot.assert('the profile is gone', n, 0);
  select count(*)::int into n from slot.wallet where user_id = '33330000-0000-0000-0000-000000000003';
  perform slot.assert('so is the wallet', n, 0);
  select count(*)::int into n from slot.ledger where user_id = '33330000-0000-0000-0000-000000000003';
  perform slot.assert('and their ledger', n, 0);
  select count(*)::int into n from slot.spin_log where user_id = '33330000-0000-0000-0000-000000000003';
  perform slot.assert('and their spins', n, 0);
  select count(*)::int into n from slot.reward_claim where user_id = '33330000-0000-0000-0000-000000000003';
  perform slot.assert('and their claims', n, 0);
  select count(*)::int into n from slot.point_request where target_id = '33330000-0000-0000-0000-000000000003';
  perform slot.assert('and requests made for them', n, 0);

  select * into d from slot.deleted_user order by id desc limit 1;
  perform slot.assert('the deletion is recorded', d.email, 'aof@bluepi.co.th');
  perform slot.assert('with their balances at the time', d.points, 3000::bigint);
  perform slot.assert('who did it', d.deleted_by, 'deputy@bluepi.co.th');
  perform slot.assert('and why', d.reason, 'left the company');

  select count(*)::int into n from slot.ranking() where name = 'Aof';
  perform slot.assert('they drop out of the ranking', n, 0);
  select count(*)::int into n from slot.app_user;
  perform slot.assert('nobody else was touched', n, 5);
end $$;

-- The master deletes the deputy, who had edited Min's wallet.
set slot.test_user = '11110000-0000-0000-0000-000000000001';
do $$
declare n int; l slot.ledger;
begin
  perform slot.delete_user('12120000-0000-0000-0000-000000000012', 'deputy@bluepi.co.th');
  perform slot.assert('the master can delete a deputy',
    (select count(*)::int from slot.app_user where id = '12120000-0000-0000-0000-000000000012'), 0);
  select * into l from slot.ledger where user_id = '44440000-0000-0000-0000-000000000004' and reason = 'admin_edit';
  perform slot.assert('the edit they made on Min''s wallet stays', l.note, 'from the deputy');
  perform slot.assert('just without the link to them', l.actor_id, null::uuid);
  perform slot.assert('Min''s balance is untouched',
    (select free_points from slot.wallet where user_id = '44440000-0000-0000-0000-000000000004'), 100::bigint);

  -- A line manager: their pending request goes with them.
  perform slot.delete_user('22220000-0000-0000-0000-000000000002', 'lead@bluepi.co.th');
  select count(*)::int into n from slot.point_request;
  perform slot.assert('requests a deleted manager made are gone', n, 0);

  select count(*)::int into n from slot.deleted_users();
  perform slot.assert('the admin list shows every deletion', n, 3);

  -- The same address can be registered again from scratch.
  perform slot.register_email('aof@bluepi.co.th', 'Aof');
  perform slot.assert('a deleted address can be registered again',
    (select count(*)::int from slot.app_user where email = 'aof@bluepi.co.th'), 1);
  perform slot.assert('with a fresh, empty wallet',
    (select points from slot.wallet w join slot.app_user u on u.id = w.user_id where u.email = 'aof@bluepi.co.th'), 0::bigint);
end $$;

-- ---------------------------------------------------------------- non-admins
set slot.test_user = '44440000-0000-0000-0000-000000000004';
do $$
begin
  perform slot.assert('a player cannot delete anyone',
    slot.refused($q$select slot.delete_user('13130000-0000-0000-0000-000000000013', 'deputy2@bluepi.co.th')$q$, '42501'), true);
  perform slot.assert('or preview a deletion',
    slot.refused($q$select slot.delete_preview('13130000-0000-0000-0000-000000000013')$q$, '42501'), true);
  perform slot.assert('or read the deletion record',
    slot.refused('select * from slot.deleted_users()', '42501'), true);
end $$;

reset slot.test_user;
drop function slot.refused(text, text);

\echo ''
\echo 'All deletion tests passed.'

-- bluePi Slot — accounts, admin powers and the scheduled grant
-- Run:  psql -f tests/accounts_test.sql

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

delete from slot.ledger;
delete from slot.free_spin_state;
delete from slot.wallet;
delete from slot.app_user;

insert into slot.app_user (id, email, role) values
  ('11110000-0000-0000-0000-000000000001', 'master@bluepi.co.th', 'system_admin'),
  ('22220000-0000-0000-0000-000000000002', 'lead@bluepi.co.th',   'line_manager'),
  ('33330000-0000-0000-0000-000000000003', 'p1@bluepi.co.th',     'player'),
  ('44440000-0000-0000-0000-000000000004', 'p2@bluepi.co.th',     'player');
insert into slot.wallet (user_id, free_points, points)
select id, 0, 0 from slot.app_user;

-- ---------------------------------------------------------------- the address rule
-- 0020 removed the @bluepi.co.th restriction: the admin decides who plays, and the
-- address can be from any domain. What is still enforced is lower case (claim_account
-- matches auth.email() against this column exactly) and a usable shape.
do $$
declare ok boolean := true; n int;
begin
  insert into slot.app_user (email) values ('outsider@gmail.com');
  select count(*)::int into n from slot.app_user where email = 'outsider@gmail.com';
  perform slot.assert('any domain can be registered', n, 1);
  delete from slot.app_user where email = 'outsider@gmail.com';

  ok := false;
  begin
    insert into slot.app_user (email) values ('MixedCase@bluepi.co.th');
  exception when check_violation then ok := true;
  end;
  perform slot.assert('addresses must be stored lower-case', ok, true);

  ok := false;
  begin
    insert into slot.app_user (email) values ('not-an-address');
  exception when check_violation then ok := true;
  end;
  perform slot.assert('something that is not an address is refused', ok, true);

  ok := false;
  begin
    insert into slot.app_user (email) values ('bob@nodot');
  exception when check_violation then ok := true;
  end;
  perform slot.assert('a domain with no dot is refused', ok, true);
end $$;

-- register_email lower-cases and trims, so an admin can type it however they like.
set slot.test_user = '11110000-0000-0000-0000-000000000001';
do $$
declare uid uuid; e text; ok boolean := false;
begin
  uid := slot.register_email('  Someone@Example.COM ', '  Someone  ');
  select u.email into e from slot.app_user u where u.id = uid;
  perform slot.assert('a mixed-case outside address is registered lower-case',
    e, 'someone@example.com');
  perform slot.assert('and gets a wallet',
    (select count(*)::int from slot.wallet w where w.user_id = uid), 1);

  begin
    perform slot.register_email('SOMEONE@example.com');
  exception when unique_violation then ok := true;
  end;
  perform slot.assert('registering the same address twice is refused', ok, true);

  delete from slot.app_user u where u.id = uid;
end $$;
reset slot.test_user;

-- ---------------------------------------------------------------- one master only
do $$
declare ok boolean := false;
begin
  begin
    insert into slot.app_user (email, role)
    values ('second@bluepi.co.th', 'system_admin');
  exception when unique_violation then ok := true;
  end;
  perform slot.assert('there can only be one master', ok, true);
end $$;

-- ---------------------------------------------------------------- the top-up rule
do $$
declare n int; f bigint;
begin
  -- 837 should become exactly 1,000 — the doc's worked example.
  update slot.wallet set free_points = 837
   where user_id = '33330000-0000-0000-0000-000000000003';
  -- 0 gets the flat 200, not a jump to the ceiling.
  update slot.wallet set free_points = 0
   where user_id = '44440000-0000-0000-0000-000000000004';
  -- Already over the ceiling: untouched.
  update slot.wallet set free_points = 1050
   where user_id = '22220000-0000-0000-0000-000000000002';

  delete from slot.setting where key = 'last_free_grant';
  n := slot.grant_free_points('2026-09-28');  -- a Monday

  select free_points into f from slot.wallet
   where user_id = '33330000-0000-0000-0000-000000000003';
  perform slot.assert('837 tops up to exactly 1,000', f, 1000::bigint);

  select free_points into f from slot.wallet
   where user_id = '44440000-0000-0000-0000-000000000004';
  perform slot.assert('0 receives the flat 200', f, 200::bigint);

  select free_points into f from slot.wallet
   where user_id = '22220000-0000-0000-0000-000000000002';
  perform slot.assert('above the ceiling is left alone', f, 1050::bigint);

  select count(*)::int into n from slot.ledger where reason = 'scheduled_grant';
  perform slot.assert('each top-up is logged', n, 3);
end $$;

-- A second run on the same day must not stack, because everyone is now at or above
-- the ceiling except the one who received 200.
do $$
declare f bigint;
begin
  perform slot.grant_free_points('2026-09-28');
  select free_points into f from slot.wallet
   where user_id = '33330000-0000-0000-0000-000000000003';
  perform slot.assert('a repeat run cannot exceed the ceiling', f, 1000::bigint);
end $$;

-- ---------------------------------------------------------------- admin edits
set slot.test_user = '11110000-0000-0000-0000-000000000001';

do $$
declare r jsonb; n int; ok boolean := false;
begin
  r := slot.admin_adjust_points('33330000-0000-0000-0000-000000000003', 0, 2500, 'prize top-up');
  perform slot.assert('admin can add prize points', (r->>'points')::int, 2500);

  select count(*)::int into n from slot.ledger
   where reason = 'admin_edit'
     and actor_id = '11110000-0000-0000-0000-000000000001';
  perform slot.assert('the edit names the admin who made it', n, 1);

  begin
    perform slot.admin_adjust_points('33330000-0000-0000-0000-000000000003', 0, -99999, 'oops');
  exception when check_violation then ok := true;
  end;
  perform slot.assert('an edit cannot push a balance negative', ok, true);
end $$;

-- ---------------------------------------------------------------- roles
do $$
declare r slot.user_role; ok boolean := false;
begin
  perform slot.set_user_role('44440000-0000-0000-0000-000000000004', 'line_manager');
  select role into r from slot.app_user where id = '44440000-0000-0000-0000-000000000004';
  perform slot.assert('admin can appoint a line manager', r::text, 'line_manager');

  begin
    perform slot.set_user_role('11110000-0000-0000-0000-000000000001', 'player');
  exception when insufficient_privilege then ok := true;
  end;
  perform slot.assert('the master cannot be demoted this way', ok, true);

  ok := false;
  begin
    perform slot.set_user_role('44440000-0000-0000-0000-000000000004', 'system_admin');
  exception when insufficient_privilege then ok := true;
  end;
  perform slot.assert('the master role cannot be handed out this way', ok, true);
end $$;

-- ---------------------------------------------------------------- transferring master
do $$
declare r slot.user_role; ok boolean := false;
begin
  perform slot.transfer_master('33330000-0000-0000-0000-000000000003');

  select role into r from slot.app_user where id = '33330000-0000-0000-0000-000000000003';
  perform slot.assert('the target becomes master', r::text, 'system_admin');
  select role into r from slot.app_user where id = '11110000-0000-0000-0000-000000000001';
  perform slot.assert('the outgoing master becomes a deputy', r::text, 'deputy_admin');

  -- The old master is now only a deputy and can no longer transfer.
  begin
    perform slot.transfer_master('44440000-0000-0000-0000-000000000004');
  exception when insufficient_privilege then ok := true;
  end;
  perform slot.assert('a deputy cannot transfer the master role', ok, true);
end $$;

-- A line manager has no admin powers at all.
set slot.test_user = '22220000-0000-0000-0000-000000000002';
do $$
declare ok boolean := false;
begin
  begin
    perform slot.admin_adjust_points('44440000-0000-0000-0000-000000000004', 5000, 0, 'nope');
  exception when insufficient_privilege then ok := true;
  end;
  perform slot.assert('a line manager cannot edit wallets', ok, true);

  ok := false;
  begin
    perform slot.register_email('sneaky@bluepi.co.th');
  exception when insufficient_privilege then ok := true;
  end;
  perform slot.assert('a line manager cannot register accounts', ok, true);
end $$;

reset slot.test_user;


-- ---------------------------------------------------------------- 0008 decisions
do $$
declare r jsonb; ok boolean := false; n int;
begin
  -- With no symbols configured the game must refuse to spin, and say why.
  delete from slot.combination_symbol; delete from slot.combination; delete from slot.symbol;
  r := slot.game_ready();
  perform slot.assert('an unconfigured game is not ready', (r->>'ready')::boolean, false);
  perform slot.assert('and says what is missing',
    (select count(*)::int from jsonb_array_elements_text(r->'missing')), 2);

  begin
    perform slot.spin('44440000-0000-0000-0000-000000000004', 25);
  exception when others then ok := true;
  end;
  perform slot.assert('spinning an unconfigured game is refused', ok, true);

  -- Configure the minimum and it becomes playable.
  insert into slot.symbol (name, image_path)
  select 'T'||i, 't'||i||'.png' from generate_series(1,5) i;
  insert into slot.combination (name) values ('Test Group');
  insert into slot.combination_symbol
  select (select id from slot.combination where name='Test Group'), id from slot.symbol;

  r := slot.game_ready();
  perform slot.assert('once configured the game is ready', (r->>'ready')::boolean, true);
  perform slot.assert('five symbols counted', (r->>'symbols')::int, 5);

  -- Wild and scatter stay optional.
  perform slot.assert('no wild needed to be ready', (r->>'wilds')::int, 0);
end $$;

-- The Play Dashboard is public to anyone signed in.
set slot.test_user = '44440000-0000-0000-0000-000000000004';
do $$
declare n int; mine int;
begin
  select count(*)::int into n from slot.play_dashboard;
  select count(*)::int into mine from slot.play_dashboard
   where player_email = 'p2@bluepi.co.th';
  perform slot.assert('a player sees the whole dashboard', (n > mine), true);
end $$;
reset slot.test_user;

\echo ''
\echo 'All account tests passed.'

-- ---------------------------------------------------------------- 0011: settings must not fail silently
do $$
declare v numeric; ok boolean := false; msg text;
begin
  -- Readable regardless of who is asking: the lookup runs as its owner now.
  perform slot.assert('setting readable by the owner',
    slot.setting_int('first_login_grant'), 500::numeric);

  -- A missing key raises with the key named, instead of returning NULL.
  begin
    perform slot.setting_int('no_such_setting');
  exception when others then
    ok := true; msg := sqlerrm;
  end;
  perform slot.assert('a missing setting raises', ok, true);
  perform slot.assert('and names the key',
    (position('no_such_setting' in msg) > 0), true);
end $$;

-- The exact bug from sign-in: a null grant must never reach the wallet.
set slot.test_user = '';
do $$
declare v numeric;
begin
  set local role slot_client;
  v := slot.setting_int('first_login_grant');
  perform slot.assert('a signed-out caller still reads settings', v, 500::numeric);
end $$;
reset slot.test_user;

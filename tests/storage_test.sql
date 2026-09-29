-- bluePi Slot — compact spin log, nightly clean-up, ledger roll-up, storage gauge
-- Run:  psql -f tests/storage_test.sql
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

delete from slot.reward_claim;
delete from slot.spin_log;
delete from slot.ledger;
delete from slot.free_spin_state;
delete from slot.wallet;
delete from slot.app_user;
delete from slot.combination_symbol;
delete from slot.combination;
delete from slot.symbol;
update slot.setting set value = '90'::jsonb where key = 'history_days';

insert into slot.app_user (id, email, role) values
  ('11110000-0000-0000-0000-000000000001', 'master@bluepi.co.th', 'system_admin'),
  ('33330000-0000-0000-0000-000000000003', 'p1@bluepi.co.th',     'player'),
  ('44440000-0000-0000-0000-000000000004', 'p2@bluepi.co.th',     'player');
insert into slot.wallet (user_id, free_points, points) values
  ('11110000-0000-0000-0000-000000000001', 0, 0),
  ('33330000-0000-0000-0000-000000000003', 1000000, 0),
  ('44440000-0000-0000-0000-000000000004', 1000000, 0);

insert into slot.symbol (name, image_path, is_wild, is_scatter, scatter_free_spins)
select 'S'||i, i||'.png', i = 7, i = 11, case when i = 11 then 2 else 0 end
  from generate_series(1,12) i;
insert into slot.combination (name, bonus) values ('All', 0);
insert into slot.combination_symbol
  select (select id from slot.combination where name = 'All'), id from slot.symbol;

-- ---------------------------------------------------------------- symbol codes
do $$
declare n int; c smallint;
begin
  select count(distinct code)::int into n from slot.symbol;
  perform slot.assert('every symbol has its own code', n, 12);

  insert into slot.symbol (name, image_path) values ('Newcomer', 'n.png') returning code into c;
  perform slot.assert('a new symbol is given a code automatically', (c is not null), true);
  delete from slot.symbol where name = 'Newcomer';
end $$;

-- ---------------------------------------------------------------- the grid encoding
do $$
declare g uuid[]; b bytea; i int; same int := 0;
begin
  for i in 1..200 loop
    g := slot.draw_grid();
    b := slot.grid_to_bytes(g);
    if length(b) = 50 and slot.grid_from_bytes(b) = g then same := same + 1; end if;
  end loop;
  perform slot.assert('200 random grids encode to 50 bytes and decode exactly', same, 200);
end $$;

do $$
declare ok boolean := false;
begin
  begin
    perform slot.grid_from_bytes('\x0001'::bytea);
  exception when invalid_parameter_value then ok := true;
  end;
  perform slot.assert('a truncated grid is refused rather than half-decoded', ok, true);
end $$;

-- ---------------------------------------------------------------- spins write compact rows
do $$
declare r jsonb; l slot.spin_log%rowtype; i int; ok int := 0;
begin
  for i in 1..100 loop
    r := slot.spin('33330000-0000-0000-0000-000000000003', 25);
    select * into l from slot.spin_log order by id desc limit 1;
    if l.line_count = (r->>'line_count')::int
       and l.multiplier = (r->>'multiplier')::numeric
       and l.payout = (r->>'payout')::int
       and l.free_spins = (r->>'free_spins')::int
       and to_jsonb(slot.grid_from_bytes(l.grid)) = r->'grid'
    then ok := ok + 1; end if;
  end loop;
  perform slot.assert('100 logged spins match what the player was shown and paid', ok, 100);
end $$;

-- Re-scoring a logged grid gives the same answer as the spin did.
do $$
declare n int;
begin
  select count(*)::int into n from slot.spin_log l
   where (slot.evaluate_grid(slot.grid_from_bytes(l.grid))->>'line_count')::int = l.line_count;
  perform slot.assert('every logged grid re-scores to the same line count', n, 100);
end $$;

-- The browser still gets the full result, including the grid and every line.
do $$
declare r jsonb;
begin
  r := slot.spin('33330000-0000-0000-0000-000000000003', 25);
  perform slot.assert('the spin still returns the grid', (r ? 'grid'), true);
  perform slot.assert('and the winning lines', (r ? 'lines'), true);
end $$;

-- ---------------------------------------------------------------- the clean-up
-- Build a history that straddles the 90-day line: spins and ledger rows 120, 100,
-- and 10 days old, plus the kinds of row that must never be touched.
do $$
declare d int; k int;
begin
  foreach d in array array[120, 100, 10] loop
    for k in 1..5 loop
      insert into slot.spin_log (user_id, bet, is_free, line_count, multiplier, payout,
                                 free_spins, grid, created_at)
      values ('44440000-0000-0000-0000-000000000004', 25, false, 1, 0.5, 13, 0,
              slot.grid_to_bytes(slot.draw_grid()),
              now() - make_interval(days => d) + make_interval(mins => k));

      insert into slot.ledger (user_id, reason, free_delta, points_delta, free_after,
                               points_after, created_at)
      values ('44440000-0000-0000-0000-000000000004', 'bet', -25, 0,
              1000000 - 25 * (d * 10 + k), 13 * (d * 10 + k - 1),
              now() - make_interval(days => d) + make_interval(mins => k)),
             ('44440000-0000-0000-0000-000000000004', 'win', 0, 13,
              1000000 - 25 * (d * 10 + k), 13 * (d * 10 + k),
              now() - make_interval(days => d) + make_interval(mins => k, secs => 1));
    end loop;
  end loop;

  -- Old, but not play: these stay exactly as they are.
  insert into slot.ledger (user_id, reason, free_delta, points_delta, free_after, points_after, created_at)
  values ('44440000-0000-0000-0000-000000000004', 'first_login_grant', 500, 0, 500, 0, now() - interval '200 days'),
         ('44440000-0000-0000-0000-000000000004', 'admin_edit',        0, 100, 500, 100, now() - interval '150 days'),
         ('44440000-0000-0000-0000-000000000004', 'scheduled_grant', 200, 0, 700, 100, now() - interval '140 days'),
         ('44440000-0000-0000-0000-000000000004', 'reward_hold',       0, -50, 700, 50, now() - interval '130 days');
end $$;

create temp table before_prune as
  select user_id, sum(free_delta) as free_total, sum(points_delta) as points_total,
         count(*) filter (where reason not in ('bet','win','play_summary')) as protected
    from slot.ledger group by user_id;

do $$
declare r jsonb; n int;
begin
  r := slot.prune_history();

  perform slot.assert('the 120- and 100-day-old spins are deleted',
    (r->>'spins_deleted')::int, 10);
  select count(*)::int into n from slot.spin_log
   where user_id = '44440000-0000-0000-0000-000000000004';
  perform slot.assert('the 10-day-old spins are kept', n, 5);

  perform slot.assert('twenty old bet and win rows are rolled up',
    (r->>'ledger_rows_rolled_up')::int, 20);
  perform slot.assert('into one summary per person per day — two days here',
    (r->>'summary_rows_written')::int, 2);
end $$;

do $$
declare b record; a record; n int;
begin
  for b in select * from before_prune loop
    select sum(free_delta) as free_total, sum(points_delta) as points_total,
           count(*) filter (where reason not in ('bet','win','play_summary')) as protected
      into a from slot.ledger where user_id = b.user_id;
    perform slot.assert('free-point history still adds up for ' || b.user_id, a.free_total, b.free_total);
    perform slot.assert('Wallet history still adds up for ' || b.user_id, a.points_total, b.points_total);
    perform slot.assert('grants, edits and prize rows are untouched for ' || b.user_id, a.protected, b.protected);
  end loop;

  select count(*)::int into n from slot.ledger
   where reason = 'first_login_grant' and user_id = '44440000-0000-0000-0000-000000000004';
  perform slot.assert('the welcome-grant row survives, so it can never be paid twice', n, 1);
end $$;

-- The summary for a day carries the balance after that day's last movement.
do $$
declare s slot.ledger%rowtype;
begin
  select * into s from slot.ledger
   where reason = 'play_summary' and user_id = '44440000-0000-0000-0000-000000000004'
   order by created_at limit 1;
  perform slot.assert('the summary nets the day: 5 bets of 25 out', s.free_delta, -125::bigint);
  perform slot.assert('and 5 wins of 13 in', s.points_delta, 65::bigint);
  perform slot.assert('and records the Wallet as it stood at the end of that day',
    s.points_after, (13 * (120 * 10 + 5))::bigint);
end $$;

-- A second run the same night changes nothing.
do $$
declare r jsonb;
begin
  r := slot.prune_history();
  perform slot.assert('a second clean-up deletes no spins', (r->>'spins_deleted')::int, 0);
  perform slot.assert('and rolls nothing up twice', (r->>'ledger_rows_rolled_up')::int, 0);
end $$;

-- The run is recorded for the gauge.
do $$
begin
  perform slot.assert('the last clean-up is recorded',
    ((select value from slot.setting where key = 'last_prune') ? 'at'), true);
end $$;

-- ---------------------------------------------------------------- the gauge and the setting
set slot.test_user = '11110000-0000-0000-0000-000000000001';
do $$
declare r jsonb; ok boolean := false;
begin
  r := slot.storage_report();
  perform slot.assert('the gauge reports the database size', ((r->>'database_bytes')::bigint > 0), true);
  perform slot.assert('against a 500 MB limit', (r->>'limit_bytes')::bigint, 524288000::bigint);
  perform slot.assert('with the retention window', (r->>'history_days')::int, 90);

  perform slot.save_history_days(30);
  perform slot.assert('an admin can change the window', slot.setting_int('history_days'), 30::numeric);

  begin
    perform slot.save_history_days(3);
  exception when check_violation then ok := true;
  end;
  perform slot.assert('fewer than 7 days is refused', ok, true);

  perform slot.save_history_days(90);
  perform slot.assert('an admin can run the clean-up by hand',
    (public.prune_history_now() ? 'spins_deleted'), true);
end $$;

set slot.test_user = '33330000-0000-0000-0000-000000000003';
do $$
declare ok boolean := false;
begin
  begin
    perform slot.storage_report();
  exception when insufficient_privilege then ok := true;
  end;
  perform slot.assert('a player cannot read the gauge', ok, true);

  ok := false;
  begin
    perform public.prune_history_now();
  exception when insufficient_privilege then ok := true;
  end;
  perform slot.assert('a player cannot trigger the clean-up', ok, true);

  ok := false;
  begin
    perform slot.save_history_days(3650);
  exception when insufficient_privilege then ok := true;
  end;
  perform slot.assert('a player cannot change the window', ok, true);
end $$;
reset slot.test_user;

\echo ''
\echo 'All storage tests passed.'

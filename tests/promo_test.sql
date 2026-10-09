-- bluePi Slot — promotions (0029)
-- Run:  psql -f tests/promo_test.sql
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

-- A Bangkok wall-clock time as a timestamptz.
create or replace function slot.bkk(p text) returns timestamptz
language sql immutable as $$ select (p::timestamp) at time zone 'Asia/Bangkok' $$;

delete from slot.promotion_dismissal;
delete from slot.promotion;
delete from slot.deleted_user;
delete from slot.point_request;
delete from slot.reward_claim;
delete from slot.spin_log;
delete from slot.ledger;
delete from slot.free_spin_state;
delete from slot.wallet;
delete from slot.app_user;

insert into slot.app_user (id, email, role, first_login_at) values
  ('11110000-0000-0000-0000-000000000001', 'master@bluepi.co.th', 'system_admin', now()),
  ('33330000-0000-0000-0000-000000000003', 'p1@bluepi.co.th',     'player',       now());
insert into slot.wallet (user_id, free_points, points) values
  ('11110000-0000-0000-0000-000000000001', 0, 0),
  ('33330000-0000-0000-0000-000000000003', 1000, 6000);

-- ================================================================ saving
set slot.test_user = '33330000-0000-0000-0000-000000000003';
do $$
begin
  perform slot.assert('a player cannot create a promotion',
    slot.refused($q$select slot.save_promotion(null, 'Mine', 'slot_boost', current_date, current_date, 1)$q$, '42501'), true);
end $$;

set slot.test_user = '11110000-0000-0000-0000-000000000001';
do $$
declare pid uuid;
begin
  perform slot.assert('the end before the start is refused',
    slot.refused($q$select slot.save_promotion(null, 'Bad', 'slot_boost', '2026-10-20', '2026-10-19', 1)$q$, '23514'), true);
  perform slot.assert('a zero extra is refused',
    slot.refused($q$select slot.save_promotion(null, 'Bad', 'slot_boost', '2026-10-19', '2026-10-20', 0)$q$, '23514'), true);
  perform slot.assert('more than x10 extra is refused',
    slot.refused($q$select slot.save_promotion(null, 'Bad', 'slot_boost', '2026-10-19', '2026-10-20', 10.5)$q$, '23514'), true);
  perform slot.assert('a start time without an end time is refused',
    slot.refused($q$select slot.save_promotion(null, 'Bad', 'slot_boost', '2026-10-19', '2026-10-20', 1, null, '16:00', null)$q$, '23514'), true);
  perform slot.assert('an end time before the start time is refused',
    slot.refused($q$select slot.save_promotion(null, 'Bad', 'slot_boost', '2026-10-19', '2026-10-20', 1, null, '17:00', '16:00')$q$, '23514'), true);
  perform slot.assert('weekday 8 is refused',
    slot.refused($q$select slot.save_promotion(null, 'Bad', 'slot_boost', '2026-10-19', '2026-10-20', 1, '{8}')$q$, '23514'), true);
  perform slot.assert('a discount needs a prize',
    slot.refused($q$select slot.save_promotion(null, 'Bad', 'reward_discount', '2026-10-19', '2026-10-23', null, null, null, null, null, 20::smallint)$q$, '23514'), true);
  perform slot.assert('100% off is refused',
    slot.refused(format('select slot.save_promotion(null, %L, %L, %L, %L, null, null, null, null, %L, 100::smallint)',
      'Bad', 'reward_discount', '2026-10-19', '2026-10-23', (select id from slot.reward where name = 'Gold Coin')), '23514'), true);

  pid := slot.save_promotion(null, 'Every day', 'slot_boost', '2026-10-19', '2026-10-20', 1, '{1,2,3,4,5,6,7}');
  perform slot.assert('all seven days are stored as "every day"',
    (select weekdays from slot.promotion where id = pid), null::smallint[]);
  delete from slot.promotion where id = pid;
end $$;

-- ================================================================ when a boost is on
-- M's example: every Monday 16:00-17:00, 19 Oct to 1 Nov 2026, x1.5.
do $$
declare pid uuid; r record;
begin
  pid := slot.save_promotion(null, 'Monday Happy Hour', 'slot_boost', '2026-10-19', '2026-11-01',
                            1.5, '{1}', '16:00', '17:00');

  select * into r from slot.slot_boost_now(slot.bkk('2026-10-19 16:30'));
  perform slot.assert('on: Monday 19 Oct 16:30', r.name, 'Monday Happy Hour');
  perform slot.assert('with its extra', r.extra, 1.50::numeric);
  perform slot.assert('and the window end', r.window_end, slot.bkk('2026-10-19 17:00'));
  perform slot.assert('on: 16:00 exactly',
    (select count(*)::int from slot.slot_boost_now(slot.bkk('2026-10-19 16:00'))), 1);
  perform slot.assert('off: 17:00 exactly (the end is not included)',
    (select count(*)::int from slot.slot_boost_now(slot.bkk('2026-10-19 17:00'))), 0);
  perform slot.assert('off: 15:59',
    (select count(*)::int from slot.slot_boost_now(slot.bkk('2026-10-19 15:59'))), 0);
  perform slot.assert('off: Tuesday at 16:30',
    (select count(*)::int from slot.slot_boost_now(slot.bkk('2026-10-20 16:30'))), 0);
  perform slot.assert('on: the next Monday',
    (select count(*)::int from slot.slot_boost_now(slot.bkk('2026-10-26 16:30'))), 1);
  perform slot.assert('off: the Monday after it ends',
    (select count(*)::int from slot.slot_boost_now(slot.bkk('2026-11-02 16:30'))), 0);
  perform slot.assert('off: the Monday before it starts',
    (select count(*)::int from slot.slot_boost_now(slot.bkk('2026-10-12 16:30'))), 0);

  -- A smaller one at the same time: only the biggest counts.
  perform slot.save_promotion(null, 'Small one', 'slot_boost', '2026-10-19', '2026-10-19', 1, null, '16:00', '18:00');
  select * into r from slot.slot_boost_now(slot.bkk('2026-10-19 16:30'));
  perform slot.assert('two at once: the biggest wins', r.extra, 1.50::numeric);
  select * into r from slot.slot_boost_now(slot.bkk('2026-10-19 17:30'));
  perform slot.assert('after the big one ends the small one still runs', r.extra, 1.00::numeric);

  perform slot.end_promotion(pid);
  select * into r from slot.slot_boost_now(slot.bkk('2026-10-19 16:30'));
  perform slot.assert('an ended promotion stops at once', r.name, 'Small one');
end $$;

-- ================================================================ the payout
delete from slot.promotion;
do $$
declare r jsonb; p bigint;
begin
  -- No promotion: 25 x 0.84 = 21.
  r := slot.apply_spin('33330000-0000-0000-0000-000000000003', 25,
                       '{"multiplier": 0.84, "free_spins": 0}'::jsonb, false);
  perform slot.assert('no promotion: the normal 21', (r->>'payout')::int, 21);
  perform slot.assert('and no promo in the result', r->'promo', 'null'::jsonb);

  -- M's first example: x1 all day today -> 21 + 21 = 42.
  perform slot.save_promotion(null, 'Double day', 'slot_boost', current_date - 1, current_date + 1, 1);
  r := slot.apply_spin('33330000-0000-0000-0000-000000000003', 25,
                       '{"multiplier": 0.84, "free_spins": 0}'::jsonb, false);
  perform slot.assert('x1 promotion: 21 + 21 = 42', (r->>'payout')::int, 42);
  perform slot.assert('the result keeps the normal payout', (r->>'base_payout')::int, 21);
  perform slot.assert('and the bonus', (r->'promo'->>'bonus')::int, 21);
  perform slot.assert('and the name', r->'promo'->>'name', 'Double day');
  perform slot.assert('the ledger says why',
    (select note from slot.ledger where reason = 'win' order by id desc limit 1), 'Double day x1.00: 21 + 21');

  -- A bigger one alongside: x1.5 -> 21 + 31.5, rounded half up = 53.
  perform slot.save_promotion(null, 'Big day', 'slot_boost', current_date, current_date, 1.5);
  r := slot.apply_spin('33330000-0000-0000-0000-000000000003', 25,
                       '{"multiplier": 0.84, "free_spins": 0}'::jsonb, false);
  perform slot.assert('two running: only the biggest, 21 + 32 = 53', (r->>'payout')::int, 53);

  -- After the x6 cap: a 150 bet at x6 = 900, then +1.5x = 900 + 1350.
  r := slot.apply_spin('33330000-0000-0000-0000-000000000003', 150,
                       '{"multiplier": 6, "free_spins": 0}'::jsonb, false);
  perform slot.assert('the promotion goes on top of the x6 cap', (r->>'payout')::int, 2250);

  -- Free spins get it too (give the player one free spin to play).
  update slot.free_spin_state set remaining = 1, round = 1, stake = 25, pending = 0
   where user_id = '33330000-0000-0000-0000-000000000003';
  r := slot.apply_spin('33330000-0000-0000-0000-000000000003', 25,
                       '{"multiplier": 0.84, "free_spins": 0}'::jsonb, true);
  perform slot.assert('a free-spin win is boosted too', (r->>'payout')::int, 53);

  -- A losing spin stays a losing spin.
  r := slot.apply_spin('33330000-0000-0000-0000-000000000003', 25,
                       '{"multiplier": 0, "free_spins": 0}'::jsonb, false);
  perform slot.assert('no win, no bonus', (r->>'payout')::int, 0);
  perform slot.assert('and no promo shown', r->'promo', 'null'::jsonb);
end $$;

-- ================================================================ reward discounts
delete from slot.promotion;
do $$
declare gold uuid := (select id from slot.reward where name = 'Gold Coin');
        r jsonb; pr record; n int; w bigint; cid bigint;
begin
  select * into pr from slot.reward_price_now(gold, now());
  perform slot.assert('no sale: full price', pr.price, 5000);

  perform slot.save_promotion(null, 'Gold rush', 'reward_discount', current_date, current_date + 2,
                              null, null, null, null, gold, 20::smallint);
  perform slot.save_promotion(null, 'Small sale', 'reward_discount', current_date, current_date,
                              null, null, null, null, gold, 10::smallint);
  perform slot.save_promotion(null, 'Next week', 'reward_discount', current_date + 7, current_date + 9,
                              null, null, null, null, gold, 50::smallint);

  select * into pr from slot.reward_price_now(gold, now());
  perform slot.assert('20% off 5,000 = 4,000 (the bigger of two sales)', pr.price, 4000);
  perform slot.assert('the list price is kept', pr.list_price, 5000);
  perform slot.assert('a sale next week does not count yet', pr.discount_pct, 20::smallint);
  select * into pr from slot.reward_price_now(gold, now() + interval '7 days');
  perform slot.assert('next week it is 50% off', pr.price, 2500);

  perform slot.assert('the rewards page sees the sale',
    (select price from slot.reward_prices() where reward_id = gold), 4000);
end $$;

-- The player claims.
set slot.test_user = '33330000-0000-0000-0000-000000000003';
do $$
declare gold uuid := (select id from slot.reward where name = 'Gold Coin');
        r jsonb; w bigint; cid bigint;
begin

  perform slot.assert('a claim at a stale price is refused',
    slot.refused(format('select slot.submit_claim(%L, 5000)', gold), '23514'), true);

  r := slot.submit_claim(gold, 4000);
  perform slot.assert('the claim holds the sale price', (r->>'price')::int, 4000);
  select points into w from slot.wallet where user_id = '33330000-0000-0000-0000-000000000003';
  cid := (r->>'claim_id')::bigint;
  perform slot.assert('the claim records the list price',
    (select list_price from slot.reward_claim where id = cid), 5000);
  perform slot.cancel_claim(cid);
  perform slot.assert('cancelling refunds what was paid',
    (select points from slot.wallet where user_id = '33330000-0000-0000-0000-000000000003'), w + 4000);
end $$;

-- ================================================================ the banner feed
set slot.test_user = '11110000-0000-0000-0000-000000000001';
delete from slot.reward_claim;
delete from slot.promotion;
do $$
declare a uuid; b uuid; c uuid; f record; n int;
begin
  a := slot.save_promotion(null, 'Running now', 'slot_boost', current_date, current_date + 3, 1);
  b := slot.save_promotion(null, 'Coming soon', 'slot_boost', current_date + 2, current_date + 9, 0.5, null, '16:00', '17:00');
  c := slot.save_promotion(null, 'Old one', 'slot_boost', current_date - 9, current_date - 2, 1);

  select count(*)::int into n from slot.promotions();
  perform slot.assert('the feed lists what is running or to come, not what is over', n, 2);

  select * into f from slot.promotions() where id = a;
  perform slot.assert('running now is live', f.live_now, true);
  perform slot.assert('with status running', f.status, 'running');
  perform slot.assert('and says until when today',
    f.live_until, ((current_date + time '23:59:59.999999') at time zone 'Asia/Bangkok'));

  select * into f from slot.promotions() where id = b;
  perform slot.assert('coming soon is upcoming', f.status, 'upcoming');
  perform slot.assert('and starts on its first day at 16:00',
    f.next_start, ((current_date + 2 + time '16:00') at time zone 'Asia/Bangkok'));

  select count(*)::int into n from slot.promotions(true);
  perform slot.assert('the admin list has everything', n, 3);
end $$;

set slot.test_user = '33330000-0000-0000-0000-000000000003';
do $$
declare n int;
begin
  perform slot.assert('a player cannot read the full admin list',
    slot.refused('select * from slot.promotions(true)', '42501'), true);
  perform slot.assert('nothing dismissed yet',
    (select count(*)::int from slot.promotions() where dismissed), 0);

  n := slot.dismiss_promotions(array(select id from slot.promotion where name = 'Running now'));
  perform slot.assert('"never show again" is stored', n, 1);
  perform slot.assert('and comes back as dismissed',
    (select dismissed from slot.promotions() where name = 'Running now'), true);
  perform slot.assert('the other one still shows',
    (select dismissed from slot.promotions() where name = 'Coming soon'), false);
  n := slot.dismiss_promotions(array(select id from slot.promotion where name = 'Running now'));
  perform slot.assert('dismissing twice is harmless', n, 0);
end $$;

-- Another player still sees everything.
set slot.test_user = '11110000-0000-0000-0000-000000000001';
do $$
begin
  perform slot.assert('dismissal is per person',
    (select count(*)::int from slot.promotions() where dismissed), 0);
end $$;
reset slot.test_user;

drop function slot.refused(text, text);
drop function slot.bkk(text);

\echo ''
\echo 'All promotion tests passed.'

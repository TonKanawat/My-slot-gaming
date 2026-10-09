-- bluePi Slot — 0029 promotions
--
-- Two kinds, both set up by admins in the back office:
--
--   * SLOT BOOST — an extra multiplier on every win, paid and free spins alike,
--     added ON TOP of the finished payout (after the x6 cap):
--         21 points won at x1   ->  21 + 21x1   = 42
--         21 points won at x1.5 ->  21 + 31.5   = 53 (rounded half up)
--     Runs on chosen weekdays, in an optional time window (Bangkok time), between
--     a start date and an end date. Example: every Monday 16:00-17:00, from
--     19 Oct 2026 to 1 Nov 2026, x1.5. If two boosts run at the same moment, only
--     the biggest counts (decided with M, 2026-10-09).
--
--   * REWARD DISCOUNT — X% off one prize, whole days from a start date to an end
--     date (Bangkok). The discounted price is what is held when the claim is sent,
--     and what a cancel or a decline refunds. Several discounts on one prize at
--     once: the biggest wins.
--
-- Players see upcoming and running promotions in a banner on the home page. They
-- can close it for now, or choose "never show again" for one promotion; that
-- choice is stored here, so it holds on every device.
--
-- Also here: slot.tidy_permissions(), the 0028 permission rules as a function
-- that this and every later migration calls at the end (see supabase/README.md).
--
-- Safe to run twice.

-- ================================================================ tables
do $$ begin
  create type slot.promotion_kind as enum ('slot_boost', 'reward_discount');
exception when duplicate_object then null; end $$;

create table if not exists slot.promotion (
  id           uuid primary key default gen_random_uuid(),
  name         text not null check (char_length(btrim(name)) between 2 and 60),
  kind         slot.promotion_kind not null,
  start_date   date not null,
  end_date     date not null,
  -- slot boost
  extra        numeric(5,2) check (extra > 0 and extra <= 10),
  weekdays     smallint[],                 -- ISO 1 = Monday .. 7 = Sunday; null = every day
  start_time   time,                       -- null with end_time = all day
  end_time     time,
  -- reward discount
  reward_id    uuid references slot.reward(id) on delete cascade,
  discount_pct smallint check (discount_pct between 1 and 99),
  is_active    boolean not null default true,   -- false = ended early by an admin
  created_by   uuid references slot.app_user(id) on delete set null,
  created_at   timestamptz not null default now(),
  constraint promotion_dates check (end_date >= start_date),
  constraint promotion_times check (
    (start_time is null and end_time is null) or
    (start_time is not null and end_time is not null and start_time < end_time)),
  constraint promotion_shape check (
    (kind = 'slot_boost' and extra is not null and reward_id is null and discount_pct is null)
    or
    (kind = 'reward_discount' and reward_id is not null and discount_pct is not null
     and extra is null and weekdays is null and start_time is null and end_time is null))
);
create index if not exists promotion_live on slot.promotion (kind, end_date) where is_active;

create table if not exists slot.promotion_dismissal (
  user_id      uuid not null references slot.app_user(id) on delete cascade,
  promotion_id uuid not null references slot.promotion(id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (user_id, promotion_id)
);

alter table slot.reward_claim add column if not exists list_price integer;
alter table slot.reward_claim add column if not exists promotion_id uuid
  references slot.promotion(id) on delete set null;

alter table slot.promotion enable row level security;
alter table slot.promotion_dismissal enable row level security;
drop policy if exists promotion_read on slot.promotion;
create policy promotion_read on slot.promotion for select
  using (slot.current_user_id() is not null);
drop policy if exists promotion_dismissal_read on slot.promotion_dismissal;
create policy promotion_dismissal_read on slot.promotion_dismissal for select
  using (user_id = slot.current_user_id());
-- No write policies: only the functions below change promotions.

-- ================================================================ what is on, when
-- The biggest slot boost running at p_at, with the end of its current window.
create or replace function slot.slot_boost_now(p_at timestamptz)
returns table (id uuid, name text, extra numeric, window_end timestamptz)
language sql stable security definer set search_path = '' as $$
  with t as (select (p_at at time zone 'Asia/Bangkok') as local)
  select p.id, p.name, p.extra,
         (((t.local)::date + coalesce(p.end_time, time '23:59:59.999999'))
            at time zone 'Asia/Bangkok')
    from slot.promotion p, t
   where p.is_active and p.kind = 'slot_boost'
     and t.local::date between p.start_date and p.end_date
     and (p.weekdays is null or extract(isodow from t.local)::smallint = any (p.weekdays))
     and (p.start_time is null or (t.local::time >= p.start_time and t.local::time < p.end_time))
   order by p.extra desc, p.created_at
   limit 1;
$$;

-- What a prize costs at p_at: the biggest discount running that day, if any.
create or replace function slot.reward_price_now(p_reward_id uuid, p_at timestamptz)
returns table (list_price integer, price integer, discount_pct smallint,
               promotion_id uuid, promotion_name text, sale_ends date)
language sql stable security definer set search_path = '' as $$
  select r.price,
         case when d.id is null then r.price
              else greatest(1, round(r.price * (100 - d.discount_pct) / 100.0))::integer end,
         d.discount_pct, d.id, d.name, d.end_date
    from slot.reward r
    left join lateral (
      select p.id, p.name, p.discount_pct, p.end_date
        from slot.promotion p
       where p.is_active and p.kind = 'reward_discount' and p.reward_id = r.id
         and (p_at at time zone 'Asia/Bangkok')::date between p.start_date and p.end_date
       order by p.discount_pct desc, p.created_at
       limit 1
    ) d on true
   where r.id = p_reward_id;
$$;

-- ================================================================ the spin pays the boost
-- Same as 0005, plus the promotion on the payout and the promo details in the result.
create or replace function slot.apply_spin(
  p_user_id uuid,
  p_bet     integer,
  p_result  jsonb,
  p_is_free boolean
) returns jsonb language plpgsql volatile set search_path = '' as $$
declare
  v_rounds_max int := slot.setting_int('free_spin_rounds_max');
  v_ban_bets   int := slot.setting_int('yellow_card_bets');
  v_per_round  int := slot.setting_int('free_spins_per_round');

  w            slot.wallet%rowtype;
  st           slot.free_spin_state%rowtype;
  from_free    bigint;
  from_points  bigint;
  payout       bigint;
  awarded      int;
  chain_ended  boolean := false;
  yellow       boolean := false;
  spin_id      bigint;
  base_payout  bigint;
  promo        record;
  promo_bonus  bigint  := 0;
  promo_info   jsonb   := null;
begin
  -- Serialise everything for this player behind the wallet row.
  select * into w from slot.wallet where user_id = p_user_id for update;
  if not found then
    raise exception 'no wallet for user %', p_user_id using errcode = 'no_data_found';
  end if;

  insert into slot.free_spin_state (user_id) values (p_user_id)
    on conflict (user_id) do nothing;
  select * into st from slot.free_spin_state where user_id = p_user_id for update;

  -- ---- charge the stake (free spins are free) ----
  if p_is_free then
    from_free := 0; from_points := 0;
  else
    if p_bet > w.free_points + w.points then
      raise exception 'not enough points: bet % against % available',
        p_bet, w.free_points + w.points using errcode = 'check_violation';
    end if;
    -- Free points always go first.
    from_free   := least(w.free_points, p_bet);
    from_points := p_bet - from_free;

    update slot.wallet
       set free_points = free_points - from_free,
           points      = points - from_points,
           updated_at  = now()
     where user_id = p_user_id
     returning * into w;

    insert into slot.ledger (user_id, reason, free_delta, points_delta,
                             free_after, points_after, is_free_spin)
    values (p_user_id, 'bet', -from_free, -from_points, w.free_points, w.points, false)
    returning id into spin_id;

    -- A paid bet burns one round of the Yellow Card.
    if st.ban_bets_left > 0 then
      st.ban_bets_left := st.ban_bets_left - 1;
    end if;
  end if;

  -- ---- pay the win into the Wallet, never the free wallet ----
  base_payout := round(p_bet * (p_result->>'multiplier')::numeric);
  payout := base_payout;

  -- 0029: a slot promotion running right now adds its extra ON TOP of the finished
  -- payout (after the x6 cap): 21 points at x1.5 -> 21 + round(21 x 1.5) = 53.
  -- Paid and free spins alike. If several run at once, only the biggest counts.
  if base_payout > 0 then
    select * into promo from slot.slot_boost_now(now());
    if promo.id is not null then
      promo_bonus := round(base_payout * promo.extra);
      payout := base_payout + promo_bonus;
      promo_info := jsonb_build_object('id', promo.id, 'name', promo.name,
                                       'extra', promo.extra, 'bonus', promo_bonus,
                                       'base_payout', base_payout,
                                       'window_end', promo.window_end);
    end if;
  end if;

  if payout > 0 then
    update slot.wallet
       set points = points + payout, updated_at = now()
     where user_id = p_user_id
     returning * into w;

    insert into slot.ledger (user_id, reason, free_delta, points_delta,
                             free_after, points_after, spin_id, is_free_spin, note)
    values (p_user_id, 'win', 0, payout, w.free_points, w.points, spin_id, p_is_free,
            case when promo_bonus > 0
                 then format('%s x%s: %s + %s', promo.name, promo.extra, base_payout, promo_bonus)
            end);
  end if;

  -- ---- advance the free-spin chain ----
  awarded := (p_result->>'free_spins')::int;
  if st.ban_bets_left > 0 then
    awarded := 0;                       -- Yellow Card: scatters pay nothing
  end if;

  if p_is_free then
    st.remaining := st.remaining - 1;
    st.pending   := least(st.pending + awarded, v_per_round);

    if st.remaining = 0 then
      if st.pending > 0 and st.round < v_rounds_max then
        st.round     := st.round + 1;
        st.remaining := st.pending;
        st.pending   := 0;
      else
        -- The chain is over. The Yellow Card only applies if the player actually
        -- used all three rounds; a chain that fizzles in round 1 costs nothing.
        chain_ended := true;
        yellow      := st.round >= v_rounds_max;
        if yellow then st.ban_bets_left := v_ban_bets; end if;
        st.round := 0; st.pending := 0; st.stake := null;
      end if;
    end if;

  elsif awarded > 0 then
    st.round     := 1;
    st.remaining := least(awarded, v_per_round);
    st.pending   := 0;
    st.stake     := p_bet;
  end if;

  update slot.free_spin_state
     set remaining = st.remaining, pending = st.pending, round = st.round,
         stake = st.stake, ban_bets_left = st.ban_bets_left, updated_at = now()
   where user_id = p_user_id;

  return p_result || jsonb_build_object(
    'bet',             p_bet,
    'was_free_spin',   p_is_free,
    'paid_from_free',  from_free,
    'paid_from_wallet',from_points,
    'payout',          payout,
    'base_payout',     base_payout,
    'promo',           promo_info,
    'free_points',     w.free_points,
    'points',          w.points,
    'free_spins_left', st.remaining,
    'free_spin_round', st.round,
    'chain_ended',     chain_ended,
    'yellow_card',     yellow,
    'ban_bets_left',   st.ban_bets_left
  );
end $$;

-- ================================================================ claims use the sale price
-- The page sends the price it showed. If a sale ended (or started) in between, the
-- claim is refused with the new price instead of charging something unexpected.
drop function if exists public.claim_reward(uuid);
drop function if exists slot.submit_claim(uuid);

create or replace function slot.submit_claim(p_reward_id uuid, p_expected_price integer default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  me   uuid := slot.current_user_id();
  r    slot.reward%rowtype;
  pr   record;
  w    slot.wallet%rowtype;
  cid  bigint;
begin
  if me is null then
    raise exception 'sign in first' using errcode = 'insufficient_privilege';
  end if;

  select * into r from slot.reward where id = p_reward_id and is_active;
  if not found then
    raise exception 'that prize is not available' using errcode = 'no_data_found';
  end if;
  select * into pr from slot.reward_price_now(r.id, now());

  if p_expected_price is not null and p_expected_price <> pr.price then
    raise exception '% now costs % points (the price changed since the page loaded)',
      r.name, pr.price using errcode = 'check_violation';
  end if;

  -- Serialise against a spin landing at the same moment.
  select * into w from slot.wallet where user_id = me for update;
  if not found then
    raise exception 'no wallet' using errcode = 'no_data_found';
  end if;

  if w.points < pr.price then
    raise exception 'the Wallet holds % points, and % needs %',
      w.points, r.name, pr.price using errcode = 'check_violation';
  end if;

  update slot.wallet
     set points = points - pr.price, updated_at = now()
   where user_id = me
   returning * into w;

  insert into slot.reward_claim (user_id, reward_id, reward_name, price, list_price, promotion_id)
  values (me, r.id, r.name, pr.price, pr.list_price, pr.promotion_id)
  returning id into cid;

  insert into slot.ledger (user_id, reason, free_delta, points_delta,
                           free_after, points_after, actor_id, note)
  values (me, 'reward_hold', 0, -pr.price, w.free_points, w.points, me,
          format('claim #%s — %s', cid, r.name)
          || case when pr.discount_pct is not null
                  then format(' (%s%% off %s)', pr.discount_pct, pr.list_price) else '' end);

  return jsonb_build_object('claim_id', cid, 'reward', r.name, 'price', pr.price,
                            'list_price', pr.list_price, 'discount_pct', pr.discount_pct,
                            'points', w.points);
end $$;

create or replace function public.claim_reward(p_reward_id uuid, p_expected_price integer default null)
returns jsonb language sql volatile set search_path = '' as $$
  select slot.submit_claim(p_reward_id, p_expected_price);
$$;

-- The claims list shows what the prize normally costs next to what was paid.
-- Same as 0019's view with list_price added at the end.
create or replace view public.reward_claims
  with (security_invoker = true) as
  select c.id, c.user_id, u.email as claimed_by, u.display_name,
         c.reward_id, c.reward_name, c.price, c.status::text as status,
         c.created_at, c.decided_at, a.email as decided_by, c.note,
         c.list_price
    from slot.reward_claim c
    join slot.app_user u on u.id = c.user_id
    left join slot.app_user a on a.id = c.decided_by;

-- Prices for the rewards page: list price, today's price, and the sale if any.
create or replace function slot.reward_prices()
returns table (reward_id uuid, list_price integer, price integer, discount_pct smallint,
               promotion_name text, sale_ends date)
language plpgsql stable security definer set search_path = '' as $$
begin
  if slot.current_user_id() is null then
    raise exception 'sign in first' using errcode = 'insufficient_privilege';
  end if;
  return query
    select r.id, p.list_price, p.price, p.discount_pct, p.promotion_name, p.sale_ends
      from slot.reward r
      cross join lateral slot.reward_price_now(r.id, now()) p
     where r.is_active;
end $$;

-- ================================================================ admin
create or replace function slot.save_promotion(
  p_id           uuid,
  p_name         text,
  p_kind         text,
  p_start_date   date,
  p_end_date     date,
  p_extra        numeric  default null,
  p_weekdays     smallint[] default null,
  p_start_time   time     default null,
  p_end_time     time     default null,
  p_reward_id    uuid     default null,
  p_discount_pct smallint default null
) returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare
  v_id   uuid;
  v_kind slot.promotion_kind;
  v_days smallint[];
  d      smallint;
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;
  begin
    v_kind := p_kind::slot.promotion_kind;
  exception when invalid_text_representation then
    raise exception 'unknown promotion type %', p_kind using errcode = 'check_violation';
  end;
  if p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    raise exception 'the end date must be on or after the start date'
      using errcode = 'check_violation';
  end if;

  if v_kind = 'slot_boost' then
    if p_extra is null or p_extra <= 0 or p_extra > 10 then
      raise exception 'the extra multiplier must be more than 0 and at most 10'
        using errcode = 'check_violation';
    end if;
    if (p_start_time is null) <> (p_end_time is null) or p_start_time >= p_end_time then
      raise exception 'give both a start and an end time, with the end after the start — or neither for all day'
        using errcode = 'check_violation';
    end if;
    -- Every day selected is the same as "every day".
    if p_weekdays is not null and cardinality(p_weekdays) > 0 then
      foreach d in array p_weekdays loop
        if d < 1 or d > 7 then
          raise exception 'weekdays are 1 (Monday) to 7 (Sunday)' using errcode = 'check_violation';
        end if;
      end loop;
      select array_agg(distinct x order by x) into v_days from unnest(p_weekdays) x;
      if cardinality(v_days) = 7 then v_days := null; end if;
    elsif p_weekdays is not null then
      raise exception 'choose at least one weekday' using errcode = 'check_violation';
    end if;
  else
    if p_reward_id is null or not exists (select 1 from slot.reward where id = p_reward_id) then
      raise exception 'choose the prize to discount' using errcode = 'check_violation';
    end if;
    if p_discount_pct is null or p_discount_pct < 1 or p_discount_pct > 99 then
      raise exception 'the discount must be 1 to 99 percent' using errcode = 'check_violation';
    end if;
  end if;

  if p_id is null then
    insert into slot.promotion (name, kind, start_date, end_date, extra, weekdays,
                                start_time, end_time, reward_id, discount_pct, created_by)
    values (btrim(p_name), v_kind, p_start_date, p_end_date,
            case when v_kind = 'slot_boost' then p_extra end, v_days,
            case when v_kind = 'slot_boost' then p_start_time end,
            case when v_kind = 'slot_boost' then p_end_time end,
            case when v_kind = 'reward_discount' then p_reward_id end,
            case when v_kind = 'reward_discount' then p_discount_pct end,
            slot.current_user_id())
    returning id into v_id;
  else
    update slot.promotion
       set name = btrim(p_name), kind = v_kind, start_date = p_start_date, end_date = p_end_date,
           extra        = case when v_kind = 'slot_boost' then p_extra end,
           weekdays     = v_days,
           start_time   = case when v_kind = 'slot_boost' then p_start_time end,
           end_time     = case when v_kind = 'slot_boost' then p_end_time end,
           reward_id    = case when v_kind = 'reward_discount' then p_reward_id end,
           discount_pct = case when v_kind = 'reward_discount' then p_discount_pct end,
           is_active    = true
     where id = p_id
     returning id into v_id;
    if v_id is null then
      raise exception 'no such promotion' using errcode = 'no_data_found';
    end if;
  end if;
  return v_id;
end $$;

-- Ends a promotion now. Kept, not deleted: past claims point at it.
create or replace function slot.end_promotion(p_id uuid)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;
  update slot.promotion set is_active = false where id = p_id;
end $$;

-- ================================================================ the feed
-- Every promotion a signed-in person might care about: everything still to come
-- or running (or, for admins with p_all, everything), with the moments the page
-- needs to write "starts Monday 16:00" or "on now until 17:00".
create or replace function slot.promotions(p_all boolean default false)
returns table (
  id uuid, name text, kind text, status text,
  start_date date, end_date date,
  extra numeric, weekdays smallint[], start_time time, end_time time,
  reward_id uuid, reward_name text, list_price integer, sale_price integer, discount_pct smallint,
  live_now boolean, next_start timestamptz, live_until timestamptz,
  dismissed boolean, is_active boolean, created_at timestamptz
) language plpgsql stable security definer set search_path = '' as $$
declare
  me    uuid := slot.current_user_id();
  v_now timestamptz := now();
  local timestamp := v_now at time zone 'Asia/Bangkok';
begin
  if me is null then
    raise exception 'sign in first' using errcode = 'insufficient_privilege';
  end if;
  if p_all and not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;

  return query
  with base as (
    select p.*,
           rw.name as rw_name, rw.price as rw_price,
           (p.is_active and local::date between p.start_date and p.end_date
             and (p.weekdays is null or extract(isodow from local)::smallint = any (p.weekdays))
             and (p.start_time is null or (local::time >= p.start_time and local::time < p.end_time))
           ) as on_now
      from slot.promotion p
      left join slot.reward rw on rw.id = p.reward_id
     where p_all or (p.is_active and p.end_date >= local::date)
  ),
  nxt as (
    -- The next moment each one starts (or starts again): the first matching day
    -- from today, at its start time, that is still in the future.
    select b.id,
           (select ((d)::date + coalesce(b.start_time, time '00:00')) at time zone 'Asia/Bangkok'
              from generate_series(greatest(b.start_date, local::date), b.end_date, interval '1 day') d
             where (b.weekdays is null or extract(isodow from d)::smallint = any (b.weekdays))
               and ((d)::date + coalesce(b.start_time, time '00:00')) at time zone 'Asia/Bangkok' > v_now
             order by d limit 1) as ns
      from base b
  )
  select b.id, b.name, b.kind::text,
         case when not b.is_active then 'ended'
              when local::date > b.end_date then 'ended'
              when b.on_now then 'running'
              when local::date >= b.start_date then 'between'   -- in its dates, outside its hours
              else 'upcoming' end,
         b.start_date, b.end_date, b.extra, b.weekdays, b.start_time, b.end_time,
         b.reward_id, b.rw_name, b.rw_price,
         case when b.kind = 'reward_discount'
              then greatest(1, round(b.rw_price * (100 - b.discount_pct) / 100.0))::integer end,
         b.discount_pct,
         b.on_now,
         n.ns,
         case when b.on_now then
           ((local::date + coalesce(b.end_time, time '23:59:59.999999')) at time zone 'Asia/Bangkok')
         end,
         exists (select 1 from slot.promotion_dismissal x where x.user_id = me and x.promotion_id = b.id),
         b.is_active, b.created_at
    from base b join nxt n on n.id = b.id
   order by b.on_now desc, coalesce(n.ns, 'infinity'::timestamptz), b.created_at;
end $$;

create or replace function slot.dismiss_promotions(p_ids uuid[])
returns integer language plpgsql volatile security definer set search_path = '' as $$
declare me uuid := slot.current_user_id(); n int;
begin
  if me is null then
    raise exception 'sign in first' using errcode = 'insufficient_privilege';
  end if;
  insert into slot.promotion_dismissal (user_id, promotion_id)
  select me, p.id from slot.promotion p where p.id = any (p_ids)
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- ================================================================ public API
create or replace function public.reward_prices()
returns table (reward_id uuid, list_price integer, price integer, discount_pct smallint,
               promotion_name text, sale_ends date)
language sql stable set search_path = '' as $$ select * from slot.reward_prices(); $$;

create or replace function public.save_promotion(
  p_id uuid, p_name text, p_kind text, p_start_date date, p_end_date date,
  p_extra numeric default null, p_weekdays smallint[] default null,
  p_start_time time default null, p_end_time time default null,
  p_reward_id uuid default null, p_discount_pct smallint default null
) returns uuid language sql volatile set search_path = '' as $$
  select slot.save_promotion(p_id, p_name, p_kind, p_start_date, p_end_date, p_extra,
                             p_weekdays, p_start_time, p_end_time, p_reward_id, p_discount_pct);
$$;

create or replace function public.end_promotion(p_id uuid)
returns void language sql volatile set search_path = '' as $$ select slot.end_promotion(p_id); $$;

create or replace function public.promotions(p_all boolean default false)
returns table (
  id uuid, name text, kind text, status text,
  start_date date, end_date date,
  extra numeric, weekdays smallint[], start_time time, end_time time,
  reward_id uuid, reward_name text, list_price integer, sale_price integer, discount_pct smallint,
  live_now boolean, next_start timestamptz, live_until timestamptz,
  dismissed boolean, is_active boolean, created_at timestamptz
) language sql stable set search_path = '' as $$ select * from slot.promotions(p_all); $$;

create or replace function public.dismiss_promotions(p_ids uuid[])
returns integer language sql volatile set search_path = '' as $$
  select slot.dismiss_promotions(p_ids);
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on slot.promotion, slot.promotion_dismissal to authenticated;
  end if;
end $$;

-- ================================================================ permissions, as a function
-- 0028's rules, kept in one place. Every later migration ends with
--   select slot.tidy_permissions();
-- and adds any new internal-only function name to the list below.
create or replace function slot.tidy_permissions()
returns text language plpgsql volatile set search_path = '' as $$
declare
  f        record;
  internal text[] := array[
    'apply_spin', 'spin', 'draw_grid', 'evaluate_grid', 'line_symbols',
    'grid_to_bytes', 'grid_from_bytes', 'public_name', 'name_key', 'name_holder', 'delete_blocked',
    'grant_free_points', 'expire_point_requests', 'prune_history',
    'slot_boost_now', 'reward_price_now', 'tidy_permissions'];
  rls_helpers text[] := array['current_user_id', 'is_admin', 'is_master'];
  has_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  has_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  n_internal int := 0; n_site int := 0; n_pinned int := 0;
begin
  for f in
    select p.oid::regprocedure as sig, p.proname, p.proconfig
      from pg_proc p
     where p.pronamespace = 'slot'::regnamespace and p.prokind = 'f'
  loop
    execute format('revoke execute on function %s from public', f.sig);
    if has_anon then execute format('revoke execute on function %s from anon', f.sig); end if;
    if f.proname = any (rls_helpers) then
      execute format('grant execute on function %s to public', f.sig);
    elsif f.proname = any (internal) then
      if has_auth then execute format('revoke execute on function %s from authenticated', f.sig); end if;
      n_internal := n_internal + 1;
    else
      if has_auth then execute format('grant execute on function %s to authenticated', f.sig); end if;
    end if;
    if f.proconfig is null then
      execute format('alter function %s set search_path = %L', f.sig, '');
      n_pinned := n_pinned + 1;
    end if;
  end loop;

  for f in
    select p.oid::regprocedure as sig, p.proconfig
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
       and p.prosrc like '%slot.%'
  loop
    execute format('revoke execute on function %s from public', f.sig);
    if has_anon then execute format('revoke execute on function %s from anon', f.sig); end if;
    if has_auth then execute format('grant execute on function %s to authenticated', f.sig); end if;
    n_site := n_site + 1;
    if f.proconfig is null then
      execute format('alter function %s set search_path = %L', f.sig, '');
      n_pinned := n_pinned + 1;
    end if;
  end loop;

  return format('%s internal functions locked; %s website functions signed-in only; search_path pinned on %s',
                n_internal, n_site, n_pinned);
end $$;

do $$ begin raise notice '%', slot.tidy_permissions(); end $$;

-- ============================================================================
-- ⚠ ALREADY APPLIED — DO NOT RUN THIS FILE AGAIN.
-- Later files replaced parts of it. Running it again would silently put these
-- old versions back over the current ones:
--   slot.spin        → current version is in 0022_storage_diet.sql
--   slot.apply_spin  → current version is in 0029_promotions.sql (pays promotions)
-- The old spin does not write the spin log, so spins would silently stop being
-- recorded (and the storage clean-up would have nothing to do) until 0022 is run again.
-- Kept as history only. See supabase/README.md.
-- ============================================================================

-- bluePi Slot — 0005 spin transaction
-- The only path by which points move because of play. Draw, evaluate, charge,
-- credit and log happen in one statement so a dropped connection can neither
-- double-charge a bet nor pay a win twice.

-- ---------------------------------------------------------------- free-spin state
-- One row per player, tracking the free-spin chain and the Yellow Card countdown.
create table if not exists slot.free_spin_state (
  user_id       uuid primary key references slot.app_user(id) on delete cascade,
  remaining     smallint not null default 0 check (remaining >= 0),   -- left in this round
  pending       smallint not null default 0 check (pending >= 0),     -- earned toward the next round
  round         smallint not null default 0 check (round between 0 and 3),
  stake         integer,                                              -- bet the chain replays
  ban_bets_left smallint not null default 0 check (ban_bets_left >= 0),
  updated_at    timestamptz not null default now()
);

alter table slot.ledger
  add column if not exists is_free_spin boolean not null default false;

-- ---------------------------------------------------------------- wallet mutation
-- Pure state change: given an already-evaluated result, charge the stake, pay the
-- win, advance the free-spin chain. Separated from drawing so the rules can be
-- tested against hand-built grids without a backdoor in the live spin path.
create or replace function slot.apply_spin(
  p_user_id uuid,
  p_bet     integer,
  p_result  jsonb,
  p_is_free boolean
) returns jsonb language plpgsql volatile as $$
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
  payout := round(p_bet * (p_result->>'multiplier')::numeric);
  if payout > 0 then
    update slot.wallet
       set points = points + payout, updated_at = now()
     where user_id = p_user_id
     returning * into w;

    insert into slot.ledger (user_id, reason, free_delta, points_delta,
                             free_after, points_after, spin_id, is_free_spin)
    values (p_user_id, 'win', 0, payout, w.free_points, w.points, spin_id, p_is_free);
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
    'free_points',     w.free_points,
    'points',          w.points,
    'free_spins_left', st.remaining,
    'free_spin_round', st.round,
    'chain_ended',     chain_ended,
    'yellow_card',     yellow,
    'ban_bets_left',   st.ban_bets_left
  );
end $$;

-- ---------------------------------------------------------------- the spin itself
-- If the player has free spins banked they are consumed first, at the stake that
-- won them. p_bet is ignored in that case.
create or replace function slot.spin(p_user_id uuid, p_bet integer)
returns jsonb language plpgsql volatile as $$
declare
  st      slot.free_spin_state%rowtype;
  is_free boolean := false;
  stake   integer := p_bet;
  result  jsonb;
begin
  select * into st from slot.free_spin_state where user_id = p_user_id;

  if found and st.remaining > 0 then
    is_free := true;
    stake   := st.stake;
  else
    if not (to_jsonb(p_bet) <@ (select value from slot.setting where key = 'bet_options')) then
      raise exception 'bet % is not one of the allowed amounts', p_bet
        using errcode = 'check_violation';
    end if;
  end if;

  result := slot.evaluate_grid(slot.draw_grid());
  return slot.apply_spin(p_user_id, stake, result, is_free);
end $$;

-- Thin wrapper for the browser: resolves the caller from their Supabase session so
-- a client can never spin as somebody else. Every name below is schema-qualified and
-- search_path is emptied, which is what stops a hostile search_path from hijacking a
-- security-definer function. auth.uid() only exists on Supabase; PL/pgSQL resolves it
-- at call time, so this still installs cleanly on a plain local Postgres.
create or replace function slot.play(p_bet integer)
returns jsonb language plpgsql volatile security definer
set search_path = '' as $$
declare v_user uuid;
begin
  select id into v_user from slot.app_user
   where auth_user_id = auth.uid() and is_active;
  if v_user is null then
    raise exception 'not signed in' using errcode = 'insufficient_privilege';
  end if;
  return slot.spin(v_user, p_bet);
end $$;

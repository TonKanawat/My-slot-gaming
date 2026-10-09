-- ============================================================================
-- ⚠ ALREADY APPLIED — DO NOT RUN THIS FILE AGAIN.
-- Later files replaced parts of it. Running it again would silently put these
-- old versions back over the current ones:
--   slot.spin        → current version is in 0022_storage_diet.sql
--   slot.game_ready  → current version is in 0016_restore_paylines.sql
-- The old spin does not write the spin log, so spins would silently stop being
-- recorded (and the storage clean-up would have nothing to do) until 0022 is run again.
-- Kept as history only. See supabase/README.md.
-- ============================================================================

-- bluePi Slot — 0008
-- Three decisions from M: the Play Dashboard is public, the game refuses to run
-- until it has been configured, and the master account is seeded.

-- ---------------------------------------------------------------- public dashboard
-- Every signed-in user can now see every bet and every admin wallet edit.
-- Note the side effect: slot.ledger carries free_after / points_after, so this also
-- exposes each player's running balance to everyone. If that is more than intended,
-- swap this policy for a view that selects only the deltas.
drop policy if exists ledger_read on slot.ledger;
create policy ledger_read on slot.ledger for select
  using (slot.current_user_id() is not null);

-- A friendly shape for the Play Dashboard tab: who, what, how much, when.
create or replace view slot.play_dashboard as
  select l.id,
         l.created_at,
         u.email        as player_email,
         u.display_name as player_name,
         l.reason,
         l.free_delta,
         l.points_delta,
         l.free_after,
         l.points_after,
         l.is_free_spin,
         a.email        as changed_by,
         l.note
    from slot.ledger l
    join slot.app_user u on u.id = l.user_id
    left join slot.app_user a on a.id = l.actor_id;

-- ---------------------------------------------------------------- readiness gate
-- Symbols and winning groups are uploaded after launch, so the slot must refuse to
-- spin until an admin has configured it, and say plainly what is missing.
create or replace function slot.game_ready()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  n_symbols int;
  n_groups  int;
  n_scatter int;
  n_wild    int;
  missing   text[] := '{}';
begin
  select count(*) into n_symbols from slot.symbol where is_active;
  select count(*) into n_groups from slot.combination c
   where c.is_active
     and exists (select 1 from slot.combination_symbol cs where cs.combination_id = c.id);
  select count(*) into n_wild    from slot.symbol where is_active and is_wild;
  select count(*) into n_scatter from slot.symbol where is_active and is_scatter;

  -- A 5+ symbol group needs five distinct symbols on a line, so five is the floor
  -- at which the board can produce a win at all.
  if n_symbols < 5 then
    missing := array_append(missing, format('at least 5 reel symbols (currently %s)', n_symbols));
  end if;
  if n_groups < 1 then
    missing := array_append(missing, 'at least one winning combination with symbols in it');
  end if;

  return jsonb_build_object(
    'ready',       cardinality(missing) = 0,
    'missing',     to_jsonb(missing),
    'symbols',     n_symbols,
    'groups',      n_groups,
    'wilds',       n_wild,      -- optional: the game runs fine without them
    'scatters',    n_scatter
  );
end $$;

-- Gate the spin itself, so no client can play an unconfigured game whatever the UI does.
create or replace function slot.spin(p_user_id uuid, p_bet integer)
returns jsonb language plpgsql volatile as $$
declare
  st      slot.free_spin_state%rowtype;
  is_free boolean := false;
  stake   integer := p_bet;
  result  jsonb;
  ready   jsonb;
begin
  ready := slot.game_ready();
  if not (ready->>'ready')::boolean then
    raise exception 'the slot is not configured yet: %',
      array_to_string(array(select jsonb_array_elements_text(ready->'missing')), '; ')
      using errcode = 'object_not_in_prerequisite_state';
  end if;

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

-- ---------------------------------------------------------------- master account
-- Creates the master row if the system has no master yet. It does NOT set a password:
-- the Supabase auth user is created separately in the dashboard, and the password is
-- hashed by GoTrue and never stored here or in the repository.
do $$
declare v_email text := 'kanawat.c@bluepi.co.th';
begin
  if exists (select 1 from slot.app_user where role = 'system_admin') then
    raise notice 'a master admin already exists — leaving it alone';
  else
    insert into slot.app_user (email, display_name, role)
    values (v_email, 'System Admin', 'system_admin')
    on conflict (email) do update set role = 'system_admin';

    insert into slot.wallet (user_id)
    select id from slot.app_user where email = v_email
    on conflict (user_id) do nothing;

    raise notice 'master admin registered as %', v_email;
  end if;
end $$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on slot.play_dashboard to authenticated;
    grant execute on function slot.game_ready() to authenticated;
  end if;
end $$;

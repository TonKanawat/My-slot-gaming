-- ============================================================================
-- ⚠ ALREADY APPLIED — DO NOT RUN THIS FILE AGAIN.
-- Later files replaced parts of it. Running it again would silently put these
-- old versions back over the current ones:
--   slot.spin  → current version is in 0022_storage_diet.sql
-- The old spin does not write the spin log, so spins would silently stop being
-- recorded (and the storage clean-up would have nothing to do) until 0022 is run again.
-- Kept as history only. See supabase/README.md.
-- ============================================================================

-- bluePi Slot — 0014 make the board playable for real
--
-- Three things the front end needed and could not get:
--   1. slot.spin drew a grid, evaluated it, and threw it away. The browser had no
--      way to show what actually landed, which is why the board was still running
--      on placeholder tiles.
--   2. No way to list players and their balances.
--   3. No way for an admin to edit a wallet from the site.

-- ---------------------------------------------------------------- return the grid
create or replace function slot.spin(p_user_id uuid, p_bet integer)
returns jsonb language plpgsql volatile as $$
declare
  st      slot.free_spin_state%rowtype;
  is_free boolean := false;
  stake   integer := p_bet;
  grid    uuid[];
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

  grid   := slot.draw_grid();
  result := slot.evaluate_grid(grid) || jsonb_build_object('grid', to_jsonb(grid));
  return slot.apply_spin(p_user_id, stake, result, is_free);
end $$;

-- ---------------------------------------------------------------- players
-- security_invoker keeps the row-level policies in force: an admin sees everyone,
-- a player sees only themselves.
create or replace view public.players
  with (security_invoker = true) as
  select u.id,
         u.email,
         u.display_name,
         u.role::text          as role,
         u.is_active,
         u.first_login_at,
         coalesce(w.free_points, 0) as free_points,
         coalesce(w.points, 0)      as points
    from slot.app_user u
    left join slot.wallet w on w.user_id = u.id;

create or replace function public.adjust_points(
  p_target uuid, p_free_delta bigint, p_points_delta bigint, p_note text default null
) returns jsonb language sql volatile as $$
  select slot.admin_adjust_points(p_target, p_free_delta, p_points_delta, p_note);
$$;

create or replace function public.register_player(p_email text, p_display_name text default null)
returns uuid language sql volatile as $$
  select slot.register_email(p_email, p_display_name);
$$;

create or replace function public.set_role(p_target uuid, p_role text)
returns void language sql volatile as $$
  select slot.set_user_role(p_target, p_role::slot.user_role);
$$;

-- The recent history, for the Play Dashboard tab.
create or replace view public.play_log
  with (security_invoker = true) as
  select l.id, l.created_at, u.email as player_email, l.reason::text as reason,
         l.free_delta, l.points_delta, l.free_after, l.points_after,
         l.is_free_spin, a.email as changed_by, l.note
    from slot.ledger l
    join slot.app_user u on u.id = l.user_id
    left join slot.app_user a on a.id = l.actor_id;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on public.players, public.play_log to authenticated;
    grant execute on function
      public.adjust_points(uuid,bigint,bigint,text),
      public.register_player(text,text),
      public.set_role(uuid,text)
    to authenticated;
  end if;
end $$;

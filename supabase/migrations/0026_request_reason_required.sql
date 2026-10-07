-- bluePi Slot — 0026 a line manager's request must say why
--
-- The amount was already required. Now the comment is too: a request without a
-- description of at least 5 characters (spaces at either end don't count) is
-- refused, so the admin always knows what the points are for. 300 characters at
-- most, as before. Requests sent before this keep whatever they had.
--
-- Same function as 0023 otherwise. Safe to run twice.

create or replace function slot.request_points(p_target uuid, p_amount integer, p_note text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  me     uuid := slot.current_user_id();
  t      slot.app_user%rowtype;
  rid    bigint;
  v_note text := btrim(regexp_replace(coalesce(p_note, ''), '\s+', ' ', 'g'));
  v_exp  timestamptz := now() + make_interval(hours => slot.setting_int('point_request_hours')::int);
begin
  if not exists (select 1 from slot.app_user where id = me and role = 'line_manager' and is_active) then
    raise exception 'only line managers can request free points'
      using errcode = 'insufficient_privilege';
  end if;

  select * into t from slot.app_user where id = p_target and is_active;
  if not found then
    raise exception 'no such person' using errcode = 'no_data_found';
  end if;
  if t.id <> me and t.role <> 'player' then
    raise exception 'a line manager can ask for players or for themselves only'
      using errcode = 'insufficient_privilege';
  end if;
  -- No upper limit by design: the admin's approval is the control.
  if p_amount is null or p_amount < 1 then
    raise exception 'ask for at least 1 point' using errcode = 'check_violation';
  end if;
  if char_length(v_note) < 5 then
    raise exception 'please describe what the points are for (at least 5 characters)'
      using errcode = 'check_violation';
  end if;
  if char_length(v_note) > 300 then
    raise exception 'the description can be at most 300 characters'
      using errcode = 'check_violation';
  end if;

  insert into slot.point_request (requested_by, target_id, amount, note, expires_at)
  values (me, t.id, p_amount, v_note, v_exp)
  returning id into rid;

  return jsonb_build_object('request_id', rid, 'expires_at', v_exp);
end $$;

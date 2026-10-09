-- ============================================================================
-- ⚠ ALREADY APPLIED — DO NOT RUN THIS FILE AGAIN.
-- Later files replaced parts of it. Running it again would silently put these
-- old versions back over the current ones:
--   slot.claim_account      → current version is in 0023_update_1.sql
--   slot.grant_free_points  → current version is in 0023_update_1.sql
--   slot.register_email     → current version is in 0024_name_duplicates.sql
-- It would also switch the daily free-point job back to Mon/Wed/Fri only, and
-- that job would then FAIL ("grant_free_points() is not unique"), so nobody
-- would receive automatic free points until 0023 is run again.
-- Kept as history only. See supabase/README.md.
-- ============================================================================

-- bluePi Slot — 0007 accounts, admin powers, scheduled free points

-- ---------------------------------------------------------------- first login
-- Registration is invite-only: an admin adds the address, and the person's first
-- successful sign-in binds their Supabase auth user to that row. An address that was
-- never registered simply finds nothing — the caller is told "registration failed"
-- and never that the domain is the reason, as specified.
create or replace function slot.claim_account()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_auth  uuid := auth.uid();
  v_email text := lower(auth.email());
  u       slot.app_user%rowtype;
  v_grant int  := slot.setting_int('first_login_grant');
begin
  if v_auth is null then
    raise exception 'not signed in' using errcode = 'insufficient_privilege';
  end if;

  select * into u from slot.app_user where email = v_email and is_active;
  if not found then
    raise exception 'registration failed' using errcode = 'insufficient_privilege';
  end if;

  if u.auth_user_id is not null and u.auth_user_id <> v_auth then
    raise exception 'registration failed' using errcode = 'insufficient_privilege';
  end if;

  update slot.app_user
     set auth_user_id = v_auth,
         first_login_at = coalesce(first_login_at, now())
   where id = u.id
   returning * into u;

  insert into slot.wallet (user_id) values (u.id) on conflict (user_id) do nothing;

  -- The 500-point welcome grant, exactly once, evidenced by the ledger rather than
  -- by a flag that could drift.
  if not exists (select 1 from slot.ledger
                  where user_id = u.id and reason = 'first_login_grant') then
    update slot.wallet set free_points = free_points + v_grant, updated_at = now()
     where user_id = u.id;
    insert into slot.ledger (user_id, reason, free_delta, points_delta,
                             free_after, points_after, note)
    select u.id, 'first_login_grant', v_grant, 0, w.free_points, w.points, 'welcome grant'
      from slot.wallet w where w.user_id = u.id;
  end if;

  return jsonb_build_object('user_id', u.id, 'email', u.email, 'role', u.role);
end $$;

-- ---------------------------------------------------------------- scheduled grant
-- Mon/Wed/Fri at 12:00 Asia/Bangkok, the free wallet is topped UP TO the ceiling,
-- not increased by a flat amount: 837 becomes 1,000, and 1,050 is left alone.
create or replace function slot.grant_free_points()
returns integer language plpgsql volatile security definer set search_path = '' as $$
declare
  v_ceiling int := slot.setting_int('free_point_ceiling');
  v_grant   int := slot.setting_int('free_point_grant');
  n         int := 0;
  r         record;
  top_up    bigint;
begin
  for r in
    select u.id, w.free_points, w.points
      from slot.app_user u join slot.wallet w on w.user_id = u.id
     where u.is_active
     order by u.id
     for update of w
  loop
    top_up := least(v_grant, v_ceiling - r.free_points);
    if top_up > 0 then
      update slot.wallet
         set free_points = free_points + top_up, updated_at = now()
       where user_id = r.id;

      insert into slot.ledger (user_id, reason, free_delta, points_delta,
                               free_after, points_after, note)
      values (r.id, 'scheduled_grant', top_up, 0,
              r.free_points + top_up, r.points, 'Mon/Wed/Fri grant');
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('bluepi-slot-free-points')
      where exists (select 1 from cron.job where jobname = 'bluepi-slot-free-points');
    -- 05:00 UTC = 12:00 Asia/Bangkok (UTC+7, no daylight saving).
    perform cron.schedule('bluepi-slot-free-points', '0 5 * * 1,3,5',
                          'select slot.grant_free_points()');
    raise notice 'scheduled the Mon/Wed/Fri free-point grant';
  else
    raise notice 'pg_cron is not installed — enable it in the Supabase dashboard, then re-run this file';
  end if;
end $$;

-- ---------------------------------------------------------------- admin: wallets
create or replace function slot.admin_adjust_points(
  p_target uuid, p_free_delta bigint, p_points_delta bigint, p_note text default null
) returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare w slot.wallet%rowtype; me uuid := slot.current_user_id();
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;

  select * into w from slot.wallet where user_id = p_target for update;
  if not found then
    raise exception 'no wallet for user %', p_target using errcode = 'no_data_found';
  end if;
  if w.free_points + p_free_delta < 0 or w.points + p_points_delta < 0 then
    raise exception 'that would push a balance below zero' using errcode = 'check_violation';
  end if;

  update slot.wallet
     set free_points = free_points + p_free_delta,
         points      = points + p_points_delta,
         updated_at  = now()
   where user_id = p_target
   returning * into w;

  -- Admin edits land in the same ledger the Play Dashboard reads, so they are as
  -- visible as any bet.
  insert into slot.ledger (user_id, reason, free_delta, points_delta,
                           free_after, points_after, actor_id, note)
  values (p_target, 'admin_edit', p_free_delta, p_points_delta,
          w.free_points, w.points, me, p_note);

  return jsonb_build_object('free_points', w.free_points, 'points', w.points);
end $$;

-- ---------------------------------------------------------------- admin: people
create or replace function slot.register_email(p_email text, p_display_name text default null)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;
  insert into slot.app_user (email, display_name)
  values (lower(p_email), p_display_name)
  returning id into v_id;
  insert into slot.wallet (user_id) values (v_id) on conflict do nothing;
  return v_id;
end $$;

create or replace function slot.set_user_role(p_target uuid, p_role slot.user_role)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare me uuid := slot.current_user_id(); target slot.app_user%rowtype;
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;
  select * into target from slot.app_user where id = p_target;
  if not found then
    raise exception 'no such user' using errcode = 'no_data_found';
  end if;

  -- The master is the one account an ordinary admin cannot touch, and nobody can
  -- hand out the master role through this function — that is transfer_master's job.
  if target.role = 'system_admin' then
    raise exception 'the master role can only be moved with slot.transfer_master()'
      using errcode = 'insufficient_privilege';
  end if;
  if p_role = 'system_admin' then
    raise exception 'use slot.transfer_master() to move the master role'
      using errcode = 'insufficient_privilege';
  end if;

  update slot.app_user set role = p_role where id = p_target;
end $$;

create or replace function slot.transfer_master(p_target uuid)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare me uuid := slot.current_user_id();
begin
  if not slot.is_master() then
    raise exception 'only the master admin can transfer the master role'
      using errcode = 'insufficient_privilege';
  end if;
  if p_target = me then
    return;
  end if;
  if not exists (select 1 from slot.app_user where id = p_target and is_active) then
    raise exception 'no such user' using errcode = 'no_data_found';
  end if;

  -- Two statements, not one: the partial unique index allows exactly one master and
  -- is checked per row, so the outgoing master must step down first.
  update slot.app_user set role = 'deputy_admin' where id = me;
  update slot.app_user set role = 'system_admin' where id = p_target;
end $$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function slot.claim_account(), slot.admin_adjust_points(uuid,bigint,bigint,text),
                              slot.register_email(text,text), slot.set_user_role(uuid,slot.user_role),
                              slot.transfer_master(uuid)
      to authenticated;
    revoke execute on function slot.grant_free_points() from authenticated, anon;
  end if;
end $$;

-- ============================================================================
-- ⚠ ALREADY APPLIED — DO NOT RUN THIS FILE AGAIN.
-- Later files replaced parts of it. Running it again would silently put these
-- old versions back over the current ones:
--   slot.set_display_name  → current version is in 0024_name_duplicates.sql
--   slot.request_points    → current version is in 0026_request_reason_required.sql
-- Kept as history only. See supabase/README.md.
-- ============================================================================

-- bluePi Slot — 0023 "Update 1"
--
--   * Everyone can set their own display name.
--   * A ranking of everyone by the points in their Wallet.
--   * The automatic free-point grant is now set by the admins: which weekdays it
--     runs, how much each of those days gives, and whether the top-up ceiling
--     applies at all. Still at 12:00 Bangkok time.
--   * Line managers can ask for free points for a player or for themselves. No
--     amount limit and no ceiling, but an admin must approve. A request that is
--     not decided within 72 hours expires. The back office warns at 48, 24 and 12
--     hours left.
--
-- Safe to run twice.

-- ---------------------------------------------------------------- settings
insert into slot.setting (key, value) values
  -- Monday first, Sunday last. 0 means "no grant that day".
  ('free_point_schedule',
     jsonb_build_array(
       coalesce((select value from slot.setting where key = 'free_point_grant'), '200'::jsonb),
       0,
       coalesce((select value from slot.setting where key = 'free_point_grant'), '200'::jsonb),
       0,
       coalesce((select value from slot.setting where key = 'free_point_grant'), '200'::jsonb),
       0, 0)),
  ('free_point_ceiling_on', 'true'::jsonb),
  ('point_request_hours',   '72'::jsonb)
on conflict (key) do nothing;

-- ================================================================ display names
-- Collapse runs of spaces, trim, 2 to 30 characters, and no two people with the
-- same name ignoring case — the ranking would be unreadable otherwise. Checked here
-- rather than by a unique index so existing duplicate names can't break the migration.
create or replace function slot.set_display_name(p_name text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  me uuid := slot.current_user_id();
  v  text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
begin
  if me is null then
    raise exception 'sign in first' using errcode = 'insufficient_privilege';
  end if;
  if char_length(v) < 2 or char_length(v) > 30 then
    raise exception 'a display name must be 2 to 30 characters' using errcode = 'check_violation';
  end if;
  if exists (select 1 from slot.app_user
              where id <> me and is_active and lower(display_name) = lower(v)) then
    raise exception 'someone is already called "%"', v using errcode = 'unique_violation';
  end if;

  update slot.app_user set display_name = v where id = me;
  return jsonb_build_object('display_name', v);
end $$;

-- The same as 0007's, plus the display name so the top bar can show it.
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

  if not exists (select 1 from slot.ledger
                  where user_id = u.id and reason = 'first_login_grant') then
    update slot.wallet set free_points = free_points + v_grant, updated_at = now()
     where user_id = u.id;
    insert into slot.ledger (user_id, reason, free_delta, points_delta,
                             free_after, points_after, note)
    select u.id, 'first_login_grant', v_grant, 0, w.free_points, w.points, 'welcome grant'
      from slot.wallet w where w.user_id = u.id;
  end if;

  return jsonb_build_object('user_id', u.id, 'email', u.email, 'role', u.role,
                            'display_name', u.display_name);
end $$;

-- What other people see: the display name, or the part of the address before the @.
create or replace function slot.public_name(p_display text, p_email text)
returns text language sql immutable as $$
  select coalesce(nullif(btrim(p_display), ''), split_part(p_email, '@', 1));
$$;

-- ================================================================ ranking
-- Wallet points only (winnings), not free points. Everyone who has signed in at
-- least once, including admins and line managers. Equal points share a rank, so
-- 1, 2, 2, 4.
create or replace function slot.ranking()
returns table (rank integer, user_id uuid, name text, points bigint, is_me boolean)
language plpgsql stable security definer set search_path = '' as $$
declare me uuid := slot.current_user_id();
begin
  if me is null then
    raise exception 'sign in first' using errcode = 'insufficient_privilege';
  end if;
  return query
    select (rank() over (order by coalesce(w.points, 0) desc))::integer,
           u.id,
           slot.public_name(u.display_name, u.email),
           coalesce(w.points, 0),
           u.id = me
      from slot.app_user u
      left join slot.wallet w on w.user_id = u.id
     where u.is_active and u.first_login_at is not null
     order by 1, 3;
end $$;

-- ================================================================ free-point schedule
create or replace function slot.grant_schedule()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_days jsonb   := (select value from slot.setting where key = 'free_point_schedule');
  v_on   boolean := slot.setting_bool('free_point_ceiling_on');
  v_ceil int     := slot.setting_int('free_point_ceiling');
  v_now  timestamp := now() at time zone 'Asia/Bangkok';
  d      date;
  amt    int;
  i      int;
  nxt    jsonb := null;
begin
  if slot.current_user_id() is null then
    raise exception 'sign in first' using errcode = 'insufficient_privilege';
  end if;
  -- The next grant: today if it is still before noon, otherwise the next day
  -- with an amount.
  for i in 0..7 loop
    d   := v_now::date + i;
    amt := coalesce((v_days ->> (extract(isodow from d)::int - 1))::int, 0);
    if amt > 0 and (i > 0 or v_now::time < time '12:00') then
      nxt := jsonb_build_object('date', d, 'amount', amt);
      exit;
    end if;
  end loop;

  return jsonb_build_object(
    'days', v_days, 'ceiling_on', v_on, 'ceiling', v_ceil,
    'time', '12:00', 'timezone', 'Asia/Bangkok', 'next', nxt,
    'last_run', (select value from slot.setting where key = 'last_free_grant'));
end $$;

create or replace function slot.save_grant_schedule(
  p_days integer[], p_ceiling_on boolean, p_ceiling integer
) returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare x int;
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;
  if p_days is null or cardinality(p_days) <> 7 then
    raise exception 'give an amount for each of the 7 days, Monday first'
      using errcode = 'check_violation';
  end if;
  foreach x in array p_days loop
    if x is null or x < 0 or x > 100000 then
      raise exception 'each day''s amount must be between 0 and 100,000'
        using errcode = 'check_violation';
    end if;
  end loop;
  if p_ceiling is null or p_ceiling < 1 or p_ceiling > 10000000 then
    raise exception 'the ceiling must be between 1 and 10,000,000'
      using errcode = 'check_violation';
  end if;

  insert into slot.setting (key, value) values
    ('free_point_schedule',   to_jsonb(p_days)),
    ('free_point_ceiling_on', to_jsonb(coalesce(p_ceiling_on, true))),
    ('free_point_ceiling',    to_jsonb(p_ceiling))
  on conflict (key) do update set value = excluded.value;

  return slot.grant_schedule();
end $$;

-- The grant itself. The cron job now runs every day at noon and this decides
-- whether today is a grant day. p_day exists for the tests; the cron job leaves it
-- out. A day that has already been paid is never paid twice, so a retried or
-- duplicated job is harmless.
drop function if exists slot.grant_free_points();
create or replace function slot.grant_free_points(p_day date default null)
returns integer language plpgsql volatile security definer set search_path = '' as $$
declare
  v_day     date    := coalesce(p_day, (now() at time zone 'Asia/Bangkok')::date);
  v_amount  int     := coalesce(((select value from slot.setting where key = 'free_point_schedule')
                                 ->> (extract(isodow from v_day)::int - 1))::int, 0);
  v_on      boolean := slot.setting_bool('free_point_ceiling_on');
  v_ceiling int     := slot.setting_int('free_point_ceiling');
  v_label   text    := trim(to_char(v_day, 'Day'));
  n         int     := 0;
  r         record;
  top_up    bigint;
begin
  if v_amount <= 0 then
    return 0;
  end if;
  if (select value ->> 'day' from slot.setting where key = 'last_free_grant') = v_day::text then
    return 0;
  end if;

  for r in
    select u.id, w.free_points, w.points
      from slot.app_user u join slot.wallet w on w.user_id = u.id
     where u.is_active
     order by u.id
     for update of w
  loop
    -- Ceiling on: top up TO the ceiling (837 → 1,000; 1,050 is left alone).
    -- Ceiling off: the full amount, whatever the balance.
    top_up := case when v_on then least(v_amount, v_ceiling - r.free_points)
                   else v_amount end;
    if top_up > 0 then
      update slot.wallet
         set free_points = free_points + top_up, updated_at = now()
       where user_id = r.id;

      insert into slot.ledger (user_id, reason, free_delta, points_delta,
                               free_after, points_after, note)
      values (r.id, 'scheduled_grant', top_up, 0,
              r.free_points + top_up, r.points, v_label || ' grant');
      n := n + 1;
    end if;
  end loop;

  insert into slot.setting (key, value)
  values ('last_free_grant', jsonb_build_object('day', v_day, 'at', now(),
                                                'amount', v_amount, 'people', n))
  on conflict (key) do update set value = excluded.value;
  return n;
end $$;

-- ================================================================ point requests
do $$ begin
  create type slot.request_status as enum ('pending','approved','rejected','cancelled','expired');
exception when duplicate_object then null; end $$;

create table if not exists slot.point_request (
  id            bigserial primary key,
  requested_by  uuid not null references slot.app_user(id) on delete cascade,
  target_id     uuid not null references slot.app_user(id) on delete cascade,
  amount        integer not null check (amount > 0),
  note          text check (char_length(note) <= 300),
  status        slot.request_status not null default 'pending',
  created_at    timestamptz not null default now(),
  expires_at    timestamptz not null,
  decided_by    uuid references slot.app_user(id) on delete set null,
  decided_at    timestamptz,
  decision_note text
);
create index if not exists point_request_pending
  on slot.point_request (expires_at) where status = 'pending';
create index if not exists point_request_requester
  on slot.point_request (requested_by, created_at desc);
create index if not exists point_request_target
  on slot.point_request (target_id, created_at desc);

-- Who a line manager may ask for: any active player, and themselves.
create or replace function slot.request_targets()
returns table (id uuid, email text, name text, is_self boolean)
language plpgsql stable security definer set search_path = '' as $$
declare me uuid := slot.current_user_id();
begin
  if not exists (select 1 from slot.app_user where app_user.id = me and role = 'line_manager') then
    raise exception 'only line managers can request free points'
      using errcode = 'insufficient_privilege';
  end if;
  return query
    select u.id, u.email, slot.public_name(u.display_name, u.email), u.id = me
      from slot.app_user u
     where u.is_active and (u.id = me or u.role = 'player')
     order by (u.id = me) desc, 3;
end $$;

create or replace function slot.request_points(p_target uuid, p_amount integer, p_note text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  me  uuid := slot.current_user_id();
  t   slot.app_user%rowtype;
  rid bigint;
  v_exp timestamptz := now() + make_interval(hours => slot.setting_int('point_request_hours')::int);
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

  insert into slot.point_request (requested_by, target_id, amount, note, expires_at)
  values (me, t.id, p_amount, nullif(btrim(p_note), ''), v_exp)
  returning id into rid;

  return jsonb_build_object('request_id', rid, 'expires_at', v_exp);
end $$;

create or replace function slot.cancel_point_request(p_id bigint)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare me uuid := slot.current_user_id(); r slot.point_request%rowtype;
begin
  select * into r from slot.point_request where id = p_id for update;
  if not found then
    raise exception 'no such request' using errcode = 'no_data_found';
  end if;
  if r.requested_by <> me then
    raise exception 'that request is not yours' using errcode = 'insufficient_privilege';
  end if;
  if r.status <> 'pending' or r.expires_at <= now() then
    raise exception 'that request is no longer waiting and cannot be cancelled'
      using errcode = 'check_violation';
  end if;
  update slot.point_request
     set status = 'cancelled', decided_by = me, decided_at = now()
   where id = r.id;
  return jsonb_build_object('request_id', r.id, 'status', 'cancelled');
end $$;

-- Approval pays the free points straight into the free wallet. The ceiling does not
-- apply: that limit belongs to the automatic grant only.
create or replace function slot.decide_point_request(
  p_id bigint, p_approve boolean, p_note text default null
) returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  me  uuid := slot.current_user_id();
  r   slot.point_request%rowtype;
  w   slot.wallet%rowtype;
  who text;
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;
  select * into r from slot.point_request where id = p_id for update;
  if not found then
    raise exception 'no such request' using errcode = 'no_data_found';
  end if;
  if r.status <> 'pending' then
    raise exception 'that request was already %', r.status using errcode = 'check_violation';
  end if;
  if r.expires_at <= now() then
    raise exception 'that request expired on %',
      to_char(r.expires_at at time zone 'Asia/Bangkok', 'DD Mon HH24:MI')
      using errcode = 'check_violation';
  end if;

  update slot.point_request
     set status = case when p_approve then 'approved' else 'rejected' end::slot.request_status,
         decided_by = me, decided_at = now(), decision_note = nullif(btrim(p_note), '')
   where id = r.id;

  if p_approve then
    insert into slot.wallet (user_id) values (r.target_id) on conflict (user_id) do nothing;
    update slot.wallet
       set free_points = free_points + r.amount, updated_at = now()
     where user_id = r.target_id
     returning * into w;

    select email into who from slot.app_user where id = r.requested_by;
    insert into slot.ledger (user_id, reason, free_delta, points_delta,
                             free_after, points_after, actor_id, note)
    values (r.target_id, 'request_grant', r.amount, 0, w.free_points, w.points, me,
            format('request #%s from %s', r.id, who));
  end if;

  return jsonb_build_object('request_id', r.id,
    'status', case when p_approve then 'approved' else 'rejected' end);
end $$;

-- Hourly, so a lapsed request is marked expired even if nobody opens the page.
create or replace function slot.expire_point_requests()
returns integer language plpgsql volatile security definer set search_path = '' as $$
declare n int;
begin
  update slot.point_request
     set status = 'expired', decided_at = expires_at
   where status = 'pending' and expires_at <= now();
  get diagnostics n = row_count;
  return n;
end $$;

-- Everything one person may see: their own requests, requests made for them, and
-- for admins every request. A function rather than a view, because the names come
-- from slot.app_user, which a line manager may not read for other people.
create or replace function slot.point_requests()
returns table (
  id bigint, requested_by uuid, requester text, requester_email text,
  target_id uuid, target text, target_email text, is_self boolean,
  amount integer, note text, status text,
  created_at timestamptz, expires_at timestamptz, hours_left numeric,
  reminder text, decided_at timestamptz, decided_by text, decision_note text
) language plpgsql stable security definer set search_path = '' as $$
declare me uuid := slot.current_user_id(); adm boolean := slot.is_admin();
begin
  if me is null then
    raise exception 'sign in first' using errcode = 'insufficient_privilege';
  end if;
  return query
    with x as (
      select r.*,
             case when r.status = 'pending' and r.expires_at <= now() then 'expired'
                  else r.status::text end as eff,
             round(extract(epoch from (r.expires_at - now())) / 3600.0, 1) as left_h
        from slot.point_request r
       where adm or r.requested_by = me or r.target_id = me
    )
    select x.id, x.requested_by,
           slot.public_name(q.display_name, q.email), q.email,
           x.target_id,
           slot.public_name(t.display_name, t.email), t.email,
           x.target_id = x.requested_by,
           x.amount, x.note, x.eff,
           x.created_at, x.expires_at,
           case when x.eff = 'pending' then greatest(x.left_h, 0) end,
           -- The website stand-in for the doc's 48 / 24 / 12-hour reminder emails.
           case when x.eff <> 'pending' then null
                when x.left_h <= 12 then '12h'
                when x.left_h <= 24 then '24h'
                when x.left_h <= 48 then '48h' end,
           x.decided_at, a.email, x.decision_note
      from x
      join slot.app_user q on q.id = x.requested_by
      join slot.app_user t on t.id = x.target_id
      left join slot.app_user a on a.id = x.decided_by
     order by (x.eff = 'pending') desc, x.expires_at asc, x.created_at desc;
end $$;

-- ---------------------------------------------------------------- row-level security
alter table slot.point_request enable row level security;
drop policy if exists point_request_read on slot.point_request;
create policy point_request_read on slot.point_request for select
  using (requested_by = slot.current_user_id()
         or target_id = slot.current_user_id()
         or slot.is_admin());
-- No write policy: requests move only through the functions above.

-- ---------------------------------------------------------------- scheduling
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('bluepi-slot-free-points')
      where exists (select 1 from cron.job where jobname = 'bluepi-slot-free-points');
    -- Every day at 05:00 UTC = 12:00 Bangkok; the function skips days with no amount.
    perform cron.schedule('bluepi-slot-free-points', '0 5 * * *',
                          'select slot.grant_free_points()');

    perform cron.unschedule('bluepi-slot-expire-requests')
      where exists (select 1 from cron.job where jobname = 'bluepi-slot-expire-requests');
    perform cron.schedule('bluepi-slot-expire-requests', '7 * * * *',
                          'select slot.expire_point_requests()');
    raise notice 'free points now checked daily at 12:00 BKK; requests expire hourly';
  else
    raise notice 'pg_cron is not installed — the grant and the expiry are not scheduled';
  end if;
end $$;

-- ================================================================ public API
create or replace function public.set_display_name(p_name text)
returns jsonb language sql volatile as $$ select slot.set_display_name(p_name); $$;

create or replace function public.ranking()
returns table (rank integer, user_id uuid, name text, points bigint, is_me boolean)
language sql stable as $$ select * from slot.ranking(); $$;

create or replace function public.grant_schedule()
returns jsonb language sql stable as $$ select slot.grant_schedule(); $$;

create or replace function public.save_grant_schedule(
  p_days integer[], p_ceiling_on boolean, p_ceiling integer
) returns jsonb language sql volatile as $$
  select slot.save_grant_schedule(p_days, p_ceiling_on, p_ceiling);
$$;

create or replace function public.request_targets()
returns table (id uuid, email text, name text, is_self boolean)
language sql stable as $$ select * from slot.request_targets(); $$;

create or replace function public.request_points(p_target uuid, p_amount integer, p_note text default null)
returns jsonb language sql volatile as $$ select slot.request_points(p_target, p_amount, p_note); $$;

create or replace function public.cancel_point_request(p_id bigint)
returns jsonb language sql volatile as $$ select slot.cancel_point_request(p_id); $$;

create or replace function public.decide_point_request(p_id bigint, p_approve boolean, p_note text default null)
returns jsonb language sql volatile as $$ select slot.decide_point_request(p_id, p_approve, p_note); $$;

create or replace function public.point_requests()
returns table (
  id bigint, requested_by uuid, requester text, requester_email text,
  target_id uuid, target text, target_email text, is_self boolean,
  amount integer, note text, status text,
  created_at timestamptz, expires_at timestamptz, hours_left numeric,
  reminder text, decided_at timestamptz, decided_by text, decision_note text
) language sql stable as $$ select * from slot.point_requests(); $$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on slot.point_request to authenticated;
    grant execute on function
      slot.public_name(text, text),
      public.set_display_name(text),
      public.ranking(),
      public.grant_schedule(),
      public.save_grant_schedule(integer[], boolean, integer),
      public.request_targets(),
      public.request_points(uuid, integer, text),
      public.cancel_point_request(bigint),
      public.decide_point_request(bigint, boolean, text),
      public.point_requests()
    to authenticated;
    revoke execute on function
      public.set_display_name(text),
      public.ranking(),
      public.grant_schedule(),
      public.save_grant_schedule(integer[], boolean, integer),
      public.request_targets(),
      public.request_points(uuid, integer, text),
      public.cancel_point_request(bigint),
      public.decide_point_request(bigint, boolean, text),
      public.point_requests()
    from anon;
    revoke execute on function
      slot.grant_free_points(date), slot.expire_point_requests()
    from authenticated, anon;
  end if;
end $$;

-- Supabase grants EXECUTE to PUBLIC on new functions; these two are cron-only.
revoke execute on function slot.grant_free_points(date), slot.expire_point_requests() from public;

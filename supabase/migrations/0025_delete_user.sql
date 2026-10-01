-- bluePi Slot — 0025 deleting a person
--
-- An admin can delete someone's profile from the back office. The page asks twice
-- (Delete, then a confirmation that needs the person's email typed in), and the
-- database insists on that email too, so a stray click or a hand-made API call
-- can't delete anyone.
--
-- Who can delete whom:
--   * nobody can delete the master admin (move the master role first);
--   * nobody can delete themselves;
--   * only the master can delete a deputy admin;
--   * any admin can delete players and line managers.
--
-- What goes with the person: their profile, both wallets, their ledger and spin
-- history, free-spin state, reward claims (including any still pending, whose held
-- points are simply gone with the wallet), and free-point requests made by them or
-- for them. Where they acted on someone ELSE's records (an admin's wallet edit, a
-- claim they approved), those records stay and just lose the link to them.
--
-- A one-line record of every deletion is kept in slot.deleted_user: who it was,
-- their balances at the time, who deleted them and when.
--
-- Their Supabase Auth login is not touched (that needs the service key). It can no
-- longer get into the game, because the game account is gone. Registering the same
-- email again later creates a fresh account, welcome grant included.
--
-- Safe to run twice.

-- ---------------------------------------------------------------- foreign keys
-- These two pointed at the person without saying what to do on delete, which would
-- block deleting anyone who had ever approved a claim or edited a wallet.
alter table slot.ledger drop constraint if exists ledger_actor_id_fkey;
alter table slot.ledger add constraint ledger_actor_id_fkey
  foreign key (actor_id) references slot.app_user(id) on delete set null;

alter table slot.reward_claim drop constraint if exists reward_claim_decided_by_fkey;
alter table slot.reward_claim add constraint reward_claim_decided_by_fkey
  foreign key (decided_by) references slot.app_user(id) on delete set null;

-- ---------------------------------------------------------------- deletion record
create table if not exists slot.deleted_user (
  id             bigserial primary key,
  user_id        uuid not null,
  email          text not null,
  display_name   text,
  role           text not null,
  free_points    bigint not null default 0,
  points         bigint not null default 0,
  spins          bigint not null default 0,
  reason         text check (char_length(reason) <= 300),
  deleted_by     text not null,          -- the admin's email, kept as text on purpose
  deleted_at     timestamptz not null default now()
);
create index if not exists deleted_user_time on slot.deleted_user (deleted_at desc);

alter table slot.deleted_user enable row level security;
drop policy if exists deleted_user_read on slot.deleted_user;
create policy deleted_user_read on slot.deleted_user for select using (slot.is_admin());

-- ---------------------------------------------------------------- the rules
-- Null when allowed, otherwise the reason it isn't. One place for the rules, so the
-- preview and the delete can't disagree.
create or replace function slot.delete_blocked(p_target slot.app_user)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when not slot.is_admin()                  then 'admins only'
    when p_target.id is null                  then 'no such person'
    when p_target.id = slot.current_user_id() then 'you cannot delete your own account'
    when p_target.role = 'system_admin'       then 'the master admin cannot be deleted — transfer the master role first'
    when p_target.role = 'deputy_admin' and not slot.is_master()
                                              then 'only the master admin can delete a deputy admin'
  end;
$$;

-- ---------------------------------------------------------------- preview
-- What the confirmation dialog shows: exactly what will be lost.
create or replace function slot.delete_preview(p_target uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  u   slot.app_user;
  w   slot.wallet;
  why text;
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;
  select * into u from slot.app_user where id = p_target;
  if u.id is null then
    raise exception 'no such person' using errcode = 'no_data_found';
  end if;
  select * into w from slot.wallet where user_id = u.id;
  why := slot.delete_blocked(u);

  return jsonb_build_object(
    'id', u.id,
    'email', u.email,
    'name', slot.public_name(u.display_name, u.email),
    'role', u.role,
    'first_login_at', u.first_login_at,
    'free_points', coalesce(w.free_points, 0),
    'points', coalesce(w.points, 0),
    'spins', (select count(*) from slot.spin_log where user_id = u.id),
    'ledger_rows', (select count(*) from slot.ledger where user_id = u.id),
    'pending_claims', (select count(*) from slot.reward_claim where user_id = u.id and status = 'pending'),
    'held_points', (select coalesce(sum(price), 0) from slot.reward_claim where user_id = u.id and status = 'pending'),
    'approved_claims', (select count(*) from slot.reward_claim where user_id = u.id and status = 'approved'),
    'pending_requests', (select count(*) from slot.point_request
                          where (requested_by = u.id or target_id = u.id) and status = 'pending'
                            and expires_at > now()),
    'allowed', why is null,
    'blocked_reason', why);
end $$;

-- ---------------------------------------------------------------- delete
create or replace function slot.delete_user(p_target uuid, p_confirm_email text, p_reason text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  me  slot.app_user;
  u   slot.app_user;
  w   slot.wallet;
  why text;
  n   bigint;
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;
  select * into me from slot.app_user where id = slot.current_user_id();
  select * into u from slot.app_user where id = p_target for update;
  if u.id is null then
    raise exception 'no such person' using errcode = 'no_data_found';
  end if;

  why := slot.delete_blocked(u);
  if why is not null then
    raise exception '%', why using errcode = 'insufficient_privilege';
  end if;

  -- The second confirmation, enforced here as well as on the page.
  if lower(btrim(coalesce(p_confirm_email, ''))) <> u.email then
    raise exception 'the email typed does not match %; nothing was deleted', u.email
      using errcode = 'check_violation';
  end if;

  select * into w from slot.wallet where user_id = u.id;
  select count(*) into n from slot.spin_log where user_id = u.id;

  insert into slot.deleted_user (user_id, email, display_name, role, free_points, points,
                                 spins, reason, deleted_by)
  values (u.id, u.email, u.display_name, u.role::text, coalesce(w.free_points, 0),
          coalesce(w.points, 0), n, nullif(btrim(p_reason), ''), me.email);

  delete from slot.app_user where id = u.id;   -- everything of theirs cascades

  return jsonb_build_object('deleted', u.email, 'name', slot.public_name(u.display_name, u.email));
end $$;

create or replace function slot.deleted_users(p_limit integer default 50)
returns table (email text, name text, role text, free_points bigint, points bigint,
               spins bigint, reason text, deleted_by text, deleted_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;
  return query
    select d.email, slot.public_name(d.display_name, d.email), d.role, d.free_points, d.points,
           d.spins, d.reason, d.deleted_by, d.deleted_at
      from slot.deleted_user d
     order by d.deleted_at desc
     limit greatest(1, least(coalesce(p_limit, 50), 500));
end $$;

-- ---------------------------------------------------------------- public API
create or replace function public.delete_preview(p_target uuid)
returns jsonb language sql stable as $$ select slot.delete_preview(p_target); $$;

create or replace function public.delete_user(p_target uuid, p_confirm_email text, p_reason text default null)
returns jsonb language sql volatile as $$ select slot.delete_user(p_target, p_confirm_email, p_reason); $$;

create or replace function public.deleted_users(p_limit integer default 50)
returns table (email text, name text, role text, free_points bigint, points bigint,
               spins bigint, reason text, deleted_by text, deleted_at timestamptz)
language sql stable as $$ select * from slot.deleted_users(p_limit); $$;

revoke execute on function slot.delete_blocked(slot.app_user) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on slot.deleted_user to authenticated;
    grant execute on function
      public.delete_preview(uuid),
      public.delete_user(uuid, text, text),
      public.deleted_users(integer)
    to authenticated;
    revoke execute on function
      public.delete_preview(uuid),
      public.delete_user(uuid, text, text),
      public.deleted_users(integer)
    from anon;
    revoke execute on function slot.delete_blocked(slot.app_user) from authenticated, anon;
  end if;
end $$;

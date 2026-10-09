-- ============================================================================
-- ⚠ ALREADY APPLIED — DO NOT RUN THIS FILE AGAIN.
-- Later files replaced parts of it. Running it again would silently put these
-- old versions back over the current ones:
--   slot.register_email  → current version is in 0024_name_duplicates.sql
-- Kept as history only. See supabase/README.md.
-- ============================================================================

-- bluePi Slot — 0020 the admin can register any address
--
-- The original rule limited accounts to @bluepi.co.th, enforced by a check
-- constraint on slot.app_user. M has changed that rule: the system admin decides
-- who plays, and the address can be from any domain.
--
-- The domain test goes; the two guarantees that other code actually relies on stay:
--
--   * lower case, because slot.claim_account() matches auth.email() against this
--     column exactly. Mixed case here would lock a real person out of their account.
--   * a shape that is recognisably an address, so a typo like "bob" or "bob@" is
--     refused at the door rather than becoming an account nobody can ever sign in to.
--
-- Registration stays invite-only: only an admin can call slot.register_email(), and
-- signing in with an unregistered address is still refused without saying why.

do $$
declare c text;
begin
  for c in
    select conname from pg_constraint
     where conrelid = 'slot.app_user'::regclass
       and contype = 'c'
       and pg_get_constraintdef(oid) like '%bluepi.co.th%'
  loop
    execute format('alter table slot.app_user drop constraint %I', c);
    raise notice 'dropped the domain restriction: %', c;
  end loop;
end $$;

alter table slot.app_user drop constraint if exists app_user_email_shape;
alter table slot.app_user add constraint app_user_email_shape
  check (
    email = lower(email)
    and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
  );

-- register_email already lower-cases what it is given, so an admin typing
-- "Someone@Example.com" gets a working account rather than a constraint error.
-- Restated here so the intent survives a future edit of 0007.
create or replace function slot.register_email(p_email text, p_display_name text default null)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;

  if exists (select 1 from slot.app_user u where u.email = lower(trim(p_email))) then
    raise exception 'that address is already registered' using errcode = 'unique_violation';
  end if;

  insert into slot.app_user (email, display_name)
  values (lower(trim(p_email)), nullif(trim(coalesce(p_display_name, '')), ''))
  returning id into v_id;

  insert into slot.wallet (user_id) values (v_id) on conflict do nothing;
  return v_id;
end $$;

do $$
begin
  raise notice 'accounts now accept any domain; % registered',
    (select count(*) from slot.app_user);
end $$;

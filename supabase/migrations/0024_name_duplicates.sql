-- bluePi Slot — 0024 display-name duplicate warnings
--
-- 0023 already refused a duplicate name when you pressed Save. This adds:
--   * check_display_name(), so the page can warn while the name is being typed
--     and say who already has it;
--   * one definition of "the same name", used everywhere: case, extra spaces and
--     leading/trailing spaces are ignored ("min  KANYA " = "Min Kanya");
--   * the comparison is against the name other people actually SEE, so someone
--     with no display name, shown as the part of their email before the @, is
--     protected too;
--   * the same rule when an admin registers someone with a display name;
--   * duplicates_report() for the back office, listing names already shared
--     (possible from before 0023, when nothing checked).
--
-- Safe to run twice.

create or replace function slot.name_key(p text)
returns text language sql immutable as $$
  select lower(btrim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g')));
$$;

-- Who, other than p_except, is already shown under this name. Null if nobody.
create or replace function slot.name_holder(p_name text, p_except uuid)
returns slot.app_user language sql stable security definer set search_path = '' as $$
  select u.* from slot.app_user u
   where u.is_active
     and u.id is distinct from p_except
     and slot.name_key(slot.public_name(u.display_name, u.email)) = slot.name_key(p_name)
   order by u.created_at
   limit 1;
$$;

-- For the live warning. Players learn only the name that is taken (it is already
-- public in the ranking); admins also get the holder's email so they can tell
-- people apart. Normally checks a name for yourself, so your own current name
-- doesn't count as taken; p_new = true is an admin checking a name for someone
-- not registered yet, where every existing name counts.
create or replace function slot.check_display_name(p_name text, p_new boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  me  uuid := slot.current_user_id();
  v   text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  h   slot.app_user;
begin
  if me is null then
    raise exception 'sign in first' using errcode = 'insufficient_privilege';
  end if;
  if p_new and not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;

  if char_length(v) < 2 or char_length(v) > 30 then
    return jsonb_build_object('ok', false, 'name', v, 'reason', 'length',
      'message', 'A display name must be 2 to 30 characters.');
  end if;

  h := slot.name_holder(v, case when p_new then null else me end);
  if h.id is not null then
    return jsonb_build_object('ok', false, 'name', v, 'reason', 'taken',
      'taken_by', slot.public_name(h.display_name, h.email),
      'taken_by_email', case when slot.is_admin() then h.email end,
      'message', format('“%s” is already used by someone else. Please choose another name.',
                        slot.public_name(h.display_name, h.email)));
  end if;

  return jsonb_build_object('ok', true, 'name', v);
end $$;

-- Same as 0023, with the shared comparison.
create or replace function slot.set_display_name(p_name text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  me uuid := slot.current_user_id();
  v  text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  h  slot.app_user;
begin
  if me is null then
    raise exception 'sign in first' using errcode = 'insufficient_privilege';
  end if;
  if char_length(v) < 2 or char_length(v) > 30 then
    raise exception 'a display name must be 2 to 30 characters' using errcode = 'check_violation';
  end if;
  -- Serialise two people choosing the same new name at the same moment.
  perform pg_advisory_xact_lock(hashtext('slot.display_name:' || slot.name_key(v)));
  h := slot.name_holder(v, me);
  if h.id is not null then
    raise exception '“%” is already used by someone else. Please choose another name.',
      slot.public_name(h.display_name, h.email) using errcode = 'unique_violation';
  end if;

  update slot.app_user set display_name = v where id = me;
  return jsonb_build_object('display_name', v);
end $$;

-- Same as 0020, plus the name rule when a display name is given.
create or replace function slot.register_email(p_email text, p_display_name text default null)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare
  v_id   uuid;
  v_name text := nullif(btrim(regexp_replace(coalesce(p_display_name, ''), '\s+', ' ', 'g')), '');
  h      slot.app_user;
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;

  if exists (select 1 from slot.app_user u where u.email = lower(trim(p_email))) then
    raise exception 'that address is already registered' using errcode = 'unique_violation';
  end if;

  if v_name is not null then
    if char_length(v_name) < 2 or char_length(v_name) > 30 then
      raise exception 'a display name must be 2 to 30 characters' using errcode = 'check_violation';
    end if;
    perform pg_advisory_xact_lock(hashtext('slot.display_name:' || slot.name_key(v_name)));
    h := slot.name_holder(v_name, null);
    if h.id is not null then
      raise exception '“%” is already used by % — choose another display name',
        slot.public_name(h.display_name, h.email), h.email using errcode = 'unique_violation';
    end if;
  end if;

  insert into slot.app_user (email, display_name)
  values (lower(trim(p_email)), v_name)
  returning id into v_id;

  insert into slot.wallet (user_id) values (v_id) on conflict do nothing;
  return v_id;
end $$;

-- Names already shared by more than one active person, for the back office.
create or replace function slot.duplicate_names()
returns table (name text, people integer, emails text[])
language plpgsql stable security definer set search_path = '' as $$
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;
  return query
    select min(slot.public_name(u.display_name, u.email)),
           count(*)::integer,
           array_agg(u.email order by u.created_at, u.email)
      from slot.app_user u
     where u.is_active
     group by slot.name_key(slot.public_name(u.display_name, u.email))
    having count(*) > 1
     order by 1;
end $$;

-- ---------------------------------------------------------------- public API
create or replace function public.check_display_name(p_name text, p_new boolean default false)
returns jsonb language sql stable as $$ select slot.check_display_name(p_name, p_new); $$;

create or replace function public.duplicate_names()
returns table (name text, people integer, emails text[])
language sql stable as $$ select * from slot.duplicate_names(); $$;

revoke execute on function slot.name_holder(text, uuid) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function
      public.check_display_name(text, boolean),
      public.duplicate_names()
    to authenticated;
    revoke execute on function
      public.check_display_name(text, boolean),
      public.duplicate_names()
    from anon;
    revoke execute on function slot.name_holder(text, uuid) from authenticated, anon;
  end if;
end $$;

do $$
declare n int;
begin
  select count(*) into n from (
    select 1 from slot.app_user u where u.is_active
     group by slot.name_key(slot.public_name(u.display_name, u.email))
    having count(*) > 1) d;
  raise notice '% display name(s) are currently shared by more than one person', n;
end $$;

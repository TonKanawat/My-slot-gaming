-- ============================================================================
-- ⚠ ALREADY APPLIED — DO NOT RUN THIS FILE AGAIN.
-- Since 0029 these rules live in slot.tidy_permissions(), which knows about the
-- newer internal functions. To re-apply permissions, run instead:
--     select slot.tidy_permissions();
-- Kept as history only. See supabase/README.md.
-- ============================================================================

-- bluePi Slot — 0028 permissions and search-path tidy-up
--
-- No change to how the game plays. Two things the review found:
--
-- 1. The "revoke ... from anon" lines in earlier files did nothing. Postgres gives
--    EXECUTE on every new function to PUBLIC (everyone), so revoking it from one
--    role leaves it in place through PUBLIC. Nothing was exploitable: Supabase's API
--    only exposes the `public` schema, and every function checks who is calling.
--    But the intended lock-down wasn't real. From here:
--      * nobody signed out (anon) can call any of the game's functions;
--      * signed-in users can call the website's functions, which still check roles
--        themselves (admins only, line managers only, ...);
--      * the engine's internal parts (apply_spin, spin, evaluate_grid, draw_grid,
--        the grid encoders, ...) can only be called from inside the game's own
--        functions, never directly by any user. (The setting readers stay open to
--        signed-in users: public.my_free_spins uses one, and settings are readable
--        by signed-in users anyway.)
--      * the three helpers the row-level-security rules call (current_user_id,
--        is_admin, is_master) stay callable by everyone, because a policy runs them
--        as whoever is reading — without that, even a signed-out page load errors.
--
-- 2. Functions without a fixed search_path. Supabase's Security Advisor flags these
--    ("Function search path mutable"). They all use fully-qualified names already,
--    so pinning search_path = '' changes nothing except silencing the warning and
--    closing the theoretical hole.
--
-- A later "create or replace function" resets these settings for that function, so
-- every future function should carry `set search_path = ''` itself (see README).
--
-- Safe to run twice.

do $$
declare
  f        record;
  internal text[] := array[
    'apply_spin', 'spin', 'draw_grid', 'evaluate_grid', 'line_symbols',
    'grid_to_bytes', 'grid_from_bytes', 'public_name', 'name_key', 'name_holder', 'delete_blocked',
    'grant_free_points', 'expire_point_requests', 'prune_history'];
  rls_helpers text[] := array['current_user_id', 'is_admin', 'is_master'];
  has_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  has_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  n_internal int := 0; n_site int := 0; n_pinned int := 0;
begin
  -- ---- the game's own schema
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

  -- ---- the website's entry points in `public` — only ours (they all call slot.*),
  -- never anything Supabase itself keeps in this schema.
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

  raise notice 'locked % internal engine functions; % website functions are now signed-in only; pinned search_path on %',
    n_internal, n_site, n_pinned;
end $$;

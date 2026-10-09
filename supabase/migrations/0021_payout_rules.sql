-- ============================================================================
-- ⚠ ALREADY APPLIED — DO NOT RUN THIS FILE AGAIN.
-- Later files replaced parts of it. Running it again would silently put these
-- old versions back over the current ones:
--   slot.evaluate_grid  → current version is in 0027_scatter_on_winning_line.sql
-- It would also bring back the old scatter rule (scatters paying anywhere).
-- Kept as history only. See supabase/README.md.
-- ============================================================================

-- bluePi Slot — 0021 the payout rules become editable, with evidence to edit them by
--
-- Three things an admin could not change without a migration: the multiplier on each
-- rung of the ladder, how many winning paylines the ladder counts before it stops
-- climbing, and the ceiling on the finished multiplier.
--
-- Confirmed by M: the maximum caps the LADDER only. Every winning line is still found
-- and every special-combination bonus still adds on top; the base multiplier simply
-- stops climbing past the maximum. That is what the engine already did with a
-- hard-coded 20, so this migration turns the 20 into a setting rather than changing
-- any behaviour on the way through.
--
-- The last piece is slot.simulate_lines(), which answers the question that makes the
-- maximum choosable at all: given the symbols, weights and groups configured right
-- now, how many lines does a spin actually win? It runs real spins through the real
-- engine rather than estimating, so the answer cannot drift from the game.

-- ---------------------------------------------------------------- room to grow
-- There are 29 paylines, so a maximum above 29 is meaningless; the old check stopped
-- at 20, which is the number this migration is making editable.
alter table slot.payout_ladder drop constraint if exists payout_ladder_lines_check;
alter table slot.payout_ladder add constraint payout_ladder_lines_check
  check (lines between 1 and 29);

insert into slot.setting (key, value) values ('max_paylines_per_round', '20'::jsonb)
on conflict (key) do nothing;

-- ---------------------------------------------------------------- the engine
-- Same rules as 0004, with two changes: the rung cap comes from the setting, and the
-- per-payline lookups are hoisted out of the loop. The old version re-ran a grouped
-- query over every combination for each of the 29 paylines, and joined slot.symbol
-- twice more per payline — 29x the work it needed, on every single spin. Gathering
-- the wild set and the groups once per grid makes a 500-spin simulation practical and
-- makes every real spin cheaper too.
create or replace function slot.evaluate_grid(p_grid uuid[])
returns jsonb language plpgsql stable as $$
declare
  v_max_wild  int     := slot.setting_int('max_wilds_per_line');
  v_cap_final boolean := slot.setting_bool('cap_final_multiplier');
  v_max_mult  numeric := slot.setting_int('max_multiplier');
  v_free_cap  int     := slot.setting_int('free_spins_per_round');
  v_max_lines int     := slot.setting_int('max_paylines_per_round');

  wild_ids     jsonb;    -- {"<uuid>": true, ...} for a cheap containment test
  combs        jsonb;    -- [{id, bonus, size, members}]
  comb         jsonb;
  pl           record;
  syms         uuid[];
  nonwild      uuid[];
  wilds        int;
  wild_allowed int;
  ok           boolean;
  sid          uuid;
  i            int;
  j            int;
  n_real       int;
  all_distinct boolean;
  best_bonus   numeric;
  best_comb    uuid;

  won          jsonb   := '[]'::jsonb;
  normal_lines int     := 0;
  bonus_sum    numeric := 0;
  base_mult    numeric := 0;
  final_mult   numeric := 0;
  free_raw     int     := 0;
  free_spins   int     := 0;
begin
  select coalesce(jsonb_object_agg(y.id::text, true), '{}'::jsonb)
    into wild_ids
    from slot.symbol y where y.is_wild;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'bonus', c.bonus, 'size', t.size, 'members', t.members)), '[]'::jsonb)
    into combs
    from slot.combination c
    join lateral (
      select count(*) as size, jsonb_object_agg(cs.symbol_id::text, true) as members
        from slot.combination_symbol cs where cs.combination_id = c.id
    ) t on true
   where c.is_active and t.size > 0;

  for pl in select id, family, cells from slot.payline order by id loop
    syms := slot.line_symbols(p_grid, pl.cells);

    -- Split the line by hand rather than with two more queries. A payline holds at
    -- most five cells, so a plpgsql loop over them costs far less than the query
    -- planner does, and this runs 29 times per spin.
    wilds := 0;
    nonwild := '{}';
    foreach sid in array syms loop
      if sid is null then
        nonwild := nonwild || sid;
      elsif wild_ids ? sid::text then
        wilds := wilds + 1;
      else
        nonwild := nonwild || sid;
      end if;
    end loop;

    wild_allowed := case when pl.family = 'corner' then 1 else v_max_wild end;
    if wilds > wild_allowed then
      continue;
    end if;

    -- Whether the line repeats a symbol depends only on the line, not on the group
    -- being tested, so it is settled once here instead of inside the inner loop.
    n_real := coalesce(array_length(nonwild, 1), 0);
    all_distinct := true;
    for i in 1 .. n_real loop
      for j in i + 1 .. n_real loop
        if nonwild[i] is not distinct from nonwild[j] then
          all_distinct := false;
        end if;
      end loop;
    end loop;

    best_bonus := null;
    best_comb  := null;

    for comb in select value from jsonb_array_elements(combs) loop
      -- Every non-wild cell must belong to the group. A null cell never matches: an
      -- unconfigured symbol must fail closed rather than satisfy every group.
      ok := true;
      foreach sid in array nonwild loop
        if sid is null or not ((comb->'members') ? sid::text) then
          ok := false;
          exit;
        end if;
      end loop;

      -- Groups of five or more additionally forbid a repeat on the line.
      if ok and (comb->>'size')::int >= 5 and not all_distinct then
        ok := false;
      end if;

      if ok and (best_bonus is null or (comb->>'bonus')::numeric > best_bonus) then
        best_bonus := (comb->>'bonus')::numeric;
        best_comb  := (comb->>'id')::uuid;
      end if;
    end loop;

    if best_comb is not null then
      won := won || jsonb_build_object(
        'payline', pl.id, 'family', pl.family,
        'combination', best_comb, 'bonus', best_bonus
      );
      if best_bonus > 0 then
        bonus_sum := bonus_sum + best_bonus;
      else
        normal_lines := normal_lines + 1;
      end if;
    end if;
  end loop;

  -- The rung comes from the NORMAL line count, capped at the configured maximum.
  -- Lines beyond it still count as wins and their bonuses still apply; the ladder
  -- just stops climbing.
  if jsonb_array_length(won) > 0 then
    select multiplier into base_mult
      from slot.payout_ladder
     where lines = greatest(1, least(v_max_lines, normal_lines));

    -- A maximum pointing at a rung that does not exist would silently pay nothing,
    -- so fall back to the highest rung that does.
    if base_mult is null then
      select multiplier into base_mult from slot.payout_ladder
       where lines <= greatest(1, least(v_max_lines, normal_lines))
       order by lines desc limit 1;
    end if;

    final_mult := coalesce(base_mult, 0) + bonus_sum;
    if v_cap_final then
      final_mult := least(final_mult, v_max_mult);
    end if;
  end if;

  select coalesce(sum(y.scatter_free_spins), 0) into free_raw
    from unnest(p_grid) s
    join slot.symbol y on y.id = s and y.is_scatter;
  free_spins := least(free_raw, v_free_cap);

  return jsonb_build_object(
    'lines',          won,
    'line_count',     jsonb_array_length(won),
    'normal_lines',   normal_lines,
    'bonus_sum',      bonus_sum,
    'base',           base_mult,
    'multiplier',     final_mult,
    'free_spins',     free_spins,
    'free_spins_raw', free_raw
  );
end $$;

-- ---------------------------------------------------------------- editing the rules
create or replace function slot.save_ladder_rung(p_lines integer, p_multiplier numeric)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;
  if p_lines < 1 or p_lines > 29 then
    raise exception 'a rung must be between 1 and 29 lines' using errcode = 'check_violation';
  end if;
  if p_multiplier < 0 or p_multiplier > 99 then
    raise exception 'a multiplier must be between 0 and 99' using errcode = 'check_violation';
  end if;

  insert into slot.payout_ladder (lines, multiplier) values (p_lines, round(p_multiplier, 2))
  on conflict (lines) do update set multiplier = excluded.multiplier;
end $$;

create or replace function slot.save_rules(
  p_max_paylines  integer,
  p_max_multiplier numeric,
  p_cap_final     boolean
) returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;
  if p_max_paylines < 1 or p_max_paylines > 29 then
    raise exception 'the maximum must be between 1 and 29 — there are only 29 paylines'
      using errcode = 'check_violation';
  end if;
  if p_max_multiplier < 1 or p_max_multiplier > 99 then
    raise exception 'the ceiling must be between 1 and 99' using errcode = 'check_violation';
  end if;

  update slot.setting set value = to_jsonb(p_max_paylines) where key = 'max_paylines_per_round';
  update slot.setting set value = to_jsonb(p_max_multiplier) where key = 'max_multiplier';
  update slot.setting set value = to_jsonb(p_cap_final) where key = 'cap_final_multiplier';

  return slot.game_rules();
end $$;

create or replace function slot.game_rules()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'max_paylines',   slot.setting_int('max_paylines_per_round'),
    'max_multiplier', slot.setting_int('max_multiplier'),
    'cap_final',      slot.setting_bool('cap_final_multiplier'),
    'max_wilds',      slot.setting_int('max_wilds_per_line'),
    'rungs',          (select count(*) from slot.payout_ladder),
    'top_rung',       (select max(lines) from slot.payout_ladder)
  );
$$;

-- ---------------------------------------------------------------- how many lines win?
-- Real spins through the real engine. Nothing is written and no wallet is touched:
-- this calls draw_grid and evaluate_grid directly rather than slot.spin.
create or replace function slot.simulate_lines(p_spins integer default 500)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  n        int := least(greatest(coalesce(p_spins, 500), 50), 3000);
  i        int;
  r        jsonb;
  counts   int[] := array_fill(0, array[30]);   -- index 1 = 0 lines, 30 = 29 lines
  mult_sum numeric := 0;
  free_sum numeric := 0;
  lines    int;
  total    int := 0;
  v_max    int := slot.setting_int('max_paylines_per_round');
  at_cap   int := 0;
  dist     jsonb := '[]'::jsonb;
  mode_l   int := 0;
  mode_n   int := -1;
  running  int := 0;
  p50      int := null;
  p95      int := null;
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;
  if not (slot.game_ready()->>'ready')::boolean then
    raise exception 'the slot is not configured yet'
      using errcode = 'object_not_in_prerequisite_state';
  end if;

  for i in 1..n loop
    r := slot.evaluate_grid(slot.draw_grid());
    lines := (r->>'line_count')::int;
    counts[lines + 1] := counts[lines + 1] + 1;
    total := total + lines;
    mult_sum := mult_sum + (r->>'multiplier')::numeric;
    free_sum := free_sum + (r->>'free_spins')::numeric;
    if (r->>'normal_lines')::int >= v_max then
      at_cap := at_cap + 1;
    end if;
  end loop;

  for i in 0..29 loop
    if counts[i + 1] > 0 then
      dist := dist || jsonb_build_object(
        'lines', i,
        'spins', counts[i + 1],
        'pct',   round(counts[i + 1] * 100.0 / n, 1));
      if counts[i + 1] > mode_n then
        mode_n := counts[i + 1];
        mode_l := i;
      end if;
    end if;
    running := running + counts[i + 1];
    if p50 is null and running >= n * 0.50 then p50 := i; end if;
    if p95 is null and running >= n * 0.95 then p95 := i; end if;
  end loop;

  return jsonb_build_object(
    'spins',            n,
    'max_paylines',     v_max,
    'distribution',     dist,
    'most_likely',      mode_l,
    'most_likely_pct',  round(mode_n * 100.0 / n, 1),
    'mean_lines',       round(total::numeric / n, 2),
    'median_lines',     p50,
    'p95_lines',        p95,
    -- How often the ladder is already pinned at the maximum. High means the maximum
    -- is doing the work; near zero means it is set higher than the game ever reaches.
    'at_cap_pct',       round(at_cap * 100.0 / n, 1),
    'mean_multiplier',  round(mult_sum / n, 3),
    -- Points returned per point staked, ignoring free spins, as a percentage.
    'return_pct',       round(mult_sum * 100.0 / n, 1),
    'mean_free_spins',  round(free_sum / n, 3)
  );
end $$;

-- ---------------------------------------------------------------- public API
create or replace function public.game_rules()
returns jsonb language sql stable as $$ select slot.game_rules(); $$;

create or replace function public.save_ladder_rung(p_lines integer, p_multiplier numeric)
returns void language sql volatile as $$
  select slot.save_ladder_rung(p_lines, p_multiplier);
$$;

create or replace function public.save_rules(
  p_max_paylines integer, p_max_multiplier numeric, p_cap_final boolean
) returns jsonb language sql volatile as $$
  select slot.save_rules(p_max_paylines, p_max_multiplier, p_cap_final);
$$;

create or replace function public.simulate_lines(p_spins integer default 500)
returns jsonb language sql volatile as $$ select slot.simulate_lines(p_spins); $$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function
      public.game_rules(),
      public.save_ladder_rung(integer, numeric),
      public.save_rules(integer, numeric, boolean),
      public.simulate_lines(integer)
    to authenticated;
  end if;
end $$;

do $$
declare r jsonb;
begin
  r := slot.game_rules();
  raise notice 'max paylines: %  ceiling: x%  capped: %  rungs: % (top %)',
    r->>'max_paylines', r->>'max_multiplier', r->>'cap_final',
    r->>'rungs', r->>'top_rung';
end $$;

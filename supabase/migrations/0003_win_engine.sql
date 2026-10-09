-- ============================================================================
-- ⚠ ALREADY APPLIED — DO NOT RUN THIS FILE AGAIN.
-- Later files replaced parts of it. Running it again would silently put these
-- old versions back over the current ones:
--   slot.setting_int, slot.setting_bool  → current version is in 0011_fix_setting_lookup.sql
--   slot.evaluate_grid                   → current version is in 0027_scatter_on_winning_line.sql
-- It would also bring back the old scatter rule (scatters paying anywhere).
-- Kept as history only. See supabase/README.md.
-- ============================================================================

-- bluePi Slot — 0003 win engine
-- Pure evaluation: given a 5x5 grid of symbol ids, work out which paylines win,
-- what the multiplier is, and how many free spins the scatters award.
-- No wallet writes here — that belongs to the spin transaction (0004).

create or replace function slot.setting_int(p_key text)
returns numeric language sql stable as $$
  select (value #>> '{}')::numeric from slot.setting where key = p_key;
$$;

create or replace function slot.setting_bool(p_key text)
returns boolean language sql stable as $$
  select (value #>> '{}')::boolean from slot.setting where key = p_key;
$$;

-- Pull the symbols sitting on one payline, in line order.
-- p_grid is 1-indexed [row][col]; payline cells are stored 0-indexed.
create or replace function slot.line_symbols(p_grid uuid[], p_cells smallint[])
returns uuid[] language plpgsql immutable as $$
declare out uuid[] := '{}'; i int;
begin
  for i in 1 .. array_length(p_cells, 1) loop
    out := out || p_grid[ p_cells[i][1] + 1 ][ p_cells[i][2] + 1 ];
  end loop;
  return out;
end $$;

create or replace function slot.evaluate_grid(p_grid uuid[])
returns jsonb language plpgsql stable as $$
declare
  v_max_wild  int     := slot.setting_int('max_wilds_per_line');
  v_cap_final boolean := slot.setting_bool('cap_final_multiplier');
  v_max_mult  numeric := slot.setting_int('max_multiplier');
  v_free_cap  int     := slot.setting_int('free_spins_per_round');

  pl           record;
  comb         record;
  syms         uuid[];
  nonwild      uuid[];
  wilds        int;
  wild_allowed int;
  ok           boolean;
  best_bonus   numeric;
  best_comb    uuid;

  won          jsonb   := '[]'::jsonb;
  normal_lines int     := 0;
  bonus_sum    numeric := 0;
  base_mult    numeric := 0;
  final_mult   numeric := 0;
  free_spins   int     := 0;
begin
  for pl in select id, family, cells from slot.payline order by id loop
    syms := slot.line_symbols(p_grid, pl.cells);

    select count(*) into wilds
      from unnest(syms) s join slot.symbol y on y.id = s where y.is_wild;

    -- The doc fixes Corner at one wild. Every other line uses the configurable cap,
    -- which exists so a line of nothing but wilds can never auto-satisfy every group.
    wild_allowed := case when pl.family = 'corner' then 1 else v_max_wild end;
    if wilds > wild_allowed then
      continue;
    end if;

    select coalesce(array_agg(s), '{}') into nonwild
      from unnest(syms) s
     where not exists (select 1 from slot.symbol y where y.id = s and y.is_wild);

    best_bonus := null;
    best_comb  := null;

    for comb in
      select c.id, c.bonus,
             count(cs.symbol_id)          as size,
             array_agg(cs.symbol_id)      as members
        from slot.combination c
        join slot.combination_symbol cs on cs.combination_id = c.id
       where c.is_active
       group by c.id, c.bonus
    loop
      -- Every non-wild cell must belong to the group. A null cell never matches:
      -- an unconfigured symbol must fail closed rather than satisfy every group.
      ok := coalesce(
        (select bool_and(s is not null and s = any(comb.members)) from unnest(nonwild) s),
        true);

      -- Groups of 5+ symbols additionally forbid duplicates on the line.
      -- Wilds stand in for distinct missing members, so only the real symbols are checked.
      if ok and comb.size >= 5 then
        ok := (select count(*) = count(distinct s) from unnest(nonwild) s);
      end if;

      -- One line pays once: keep the combination that pays the player most.
      if ok and (best_bonus is null or comb.bonus > best_bonus) then
        best_bonus := comb.bonus;
        best_comb  := comb.id;
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

  -- The base multiplier is driven by the count of NORMAL winning lines; special
  -- lines do not advance the ladder, they add their bonus on top. When a player's
  -- only winning line is a special one, the ladder is entered at rung 1 (x0.5).
  if jsonb_array_length(won) > 0 then
    select multiplier into base_mult
      from slot.payout_ladder
     where lines = greatest(1, least(20, normal_lines));
    final_mult := base_mult + bonus_sum;
    if v_cap_final then
      final_mult := least(final_mult, v_max_mult);
    end if;
  end if;

  -- Scatters pay wherever they land in the grid, once per distinct scatter symbol,
  -- capped for the whole spin.
  select coalesce(sum(y.scatter_free_spins), 0) into free_spins
    from (select distinct s from unnest(p_grid) s) g
    join slot.symbol y on y.id = g.s and y.is_scatter;
  free_spins := least(free_spins, v_free_cap);

  return jsonb_build_object(
    'lines',        won,
    'line_count',   jsonb_array_length(won),
    'normal_lines', normal_lines,
    'bonus_sum',    bonus_sum,
    'base',         base_mult,
    'multiplier',   final_mult,
    'free_spins',   free_spins
  );
end $$;

-- Weighted draw of one 5x5 grid. Server-side only: the browser never picks symbols.
-- The cumulative weight table is built once per call and the random threshold is
-- drawn into a scalar. (Putting random() in a WHERE clause re-evaluates it per row,
-- which silently skews the reels — some symbols never appear at all.)
create or replace function slot.draw_grid()
returns uuid[] language plpgsql volatile as $$
declare
  ids   uuid[];
  cums  bigint[];
  total bigint;
  grid  uuid[] := array_fill(null::uuid, array[5,5]);
  r int; c int; k int; x bigint;
begin
  select array_agg(t.id order by t.cum), array_agg(t.cum order by t.cum), max(t.cum)
    into ids, cums, total
  from (
    select id,
           sum(weight) over (order by id rows between unbounded preceding and current row) as cum
      from slot.symbol where is_active
  ) t;

  if coalesce(total, 0) = 0 then
    raise exception 'no active symbols configured';
  end if;

  for r in 1..5 loop
    for c in 1..5 loop
      x := floor(random() * total)::bigint;   -- one draw per cell
      for k in 1 .. array_length(cums, 1) loop
        if cums[k] > x then
          grid[r][c] := ids[k];
          exit;
        end if;
      end loop;
    end loop;
  end loop;
  return grid;
end $$;

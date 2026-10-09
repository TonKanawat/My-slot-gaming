-- bluePi Slot — 0027 scatters pay only on a winning line
--
-- New rule from M (2026-10-09): a scatter symbol gives its free spins ONLY when it
-- sits on a winning payline. Before this, a scatter anywhere on the 5x5 board paid.
--
--   * Each scatter cell pays once, even when several winning lines cross it.
--   * The per-spin cap (free_spins_per_round, 10) and the Yellow Card are unchanged.
--   * A line only wins when every cell on it belongs to the winning group (wilds
--     aside), so a scatter can only be on a winning line if the admin has put it
--     in a winning group. A scatter that is in no group can no longer give free
--     spins at all.
--   * The result now also lists which scatters paid (row, col, name, spins) and how
--     many landed off the winning lines, so the page can explain it.
--
-- Same engine as 0021 otherwise. Safe to run twice.

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
  -- Cells covered by at least one winning line, as {"r,c": true}. A scatter pays
  -- its free spins only from one of these cells.
  won_cells    jsonb   := '{}'::jsonb;
  cell         smallint[];
  r            int;
  c            int;
  scatters     jsonb;    -- {"<uuid>": {"name": ..., "spins": n}} for every scatter
  scat         jsonb;
  scat_paid    jsonb   := '[]'::jsonb;
  scat_missed  int     := 0;
begin
  select coalesce(jsonb_object_agg(y.id::text, true), '{}'::jsonb)
    into wild_ids
    from slot.symbol y where y.is_wild;

  select coalesce(jsonb_object_agg(y.id::text,
           jsonb_build_object('name', y.name, 'spins', y.scatter_free_spins)), '{}'::jsonb)
    into scatters
    from slot.symbol y where y.is_scatter;

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
      foreach cell slice 1 in array pl.cells loop
        won_cells := won_cells || jsonb_build_object(cell[1] || ',' || cell[2], true);
      end loop;
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

  -- Scatters pay only when they sit on a winning line (0027). Each scatter CELL
  -- pays once, however many winning lines pass through it. A scatter anywhere else
  -- on the board pays nothing; it is counted so the page can say why.
  for r in 0 .. 4 loop
    for c in 0 .. 4 loop
      scat := scatters -> (p_grid[r + 1][c + 1]::text);
      if scat is not null then
        if won_cells ? (r || ',' || c) then
          free_raw := free_raw + (scat->>'spins')::int;
          scat_paid := scat_paid || jsonb_build_object(
            'row', r, 'col', c, 'symbol', p_grid[r + 1][c + 1], 'name', scat->>'name',
            'spins', (scat->>'spins')::int);
        else
          scat_missed := scat_missed + 1;
        end if;
      end if;
    end loop;
  end loop;
  free_spins := least(free_raw, v_free_cap);

  return jsonb_build_object(
    'lines',          won,
    'line_count',     jsonb_array_length(won),
    'normal_lines',   normal_lines,
    'bonus_sum',      bonus_sum,
    'base',           base_mult,
    'multiplier',     final_mult,
    'free_spins',     free_spins,
    'free_spins_raw', free_raw,
    'scatters_paid',  scat_paid,
    'scatters_missed', scat_missed
  );
end $$;

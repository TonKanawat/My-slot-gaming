-- ============================================================================
-- ⚠ ALREADY APPLIED — DO NOT RUN THIS FILE AGAIN.
-- Later files replaced parts of it. Running it again would silently put these
-- old versions back over the current ones:
--   slot.evaluate_grid  → current version is in 0027_scatter_on_winning_line.sql
-- It would also bring back the old scatter rule (scatters paying anywhere).
-- Kept as history only. See supabase/README.md.
-- ============================================================================

-- bluePi Slot — 0004 rule decisions
-- Confirmed by M, 2026-08-26. Each block notes which open question it closes.

-- Q2: the finished multiplier is capped at x6, not just the ladder. A spin with
-- ten normal lines and three +1.5 specials computes 2.75 + 4.50 = 7.25 and pays x6.
update slot.setting set value = 'true'::jsonb where key = 'cap_final_multiplier';

-- Q4: two wilds per five-cell line (Corner stays at one, fixed in the engine).
update slot.setting set value = '2'::jsonb where key = 'max_wilds_per_line';

-- Q3: the ladder stands exactly as written, including the +0.35 step from rung 2
-- to rung 3. No change — recorded here so nobody "fixes" it later.

-- Q5: the Yellow Card freeze begins only after all three free-spin rounds are used.
insert into slot.setting (key, value) values ('yellow_card_after_final_round', 'true'::jsonb)
on conflict (key) do update set value = excluded.value;

-- Q6: scatters pay PER POSITION, not per distinct symbol. Three scatters on the grid
-- award X+X+X, then the per-spin ceiling applies. This is the one behavioural change
-- to the engine, so evaluate_grid is replaced below.
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
  free_raw     int     := 0;
  free_spins   int     := 0;
begin
  for pl in select id, family, cells from slot.payline order by id loop
    syms := slot.line_symbols(p_grid, pl.cells);

    select count(*) into wilds
      from unnest(syms) s join slot.symbol y on y.id = s where y.is_wild;

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
      select c.id, c.bonus, count(cs.symbol_id) as size, array_agg(cs.symbol_id) as members
        from slot.combination c
        join slot.combination_symbol cs on cs.combination_id = c.id
       where c.is_active
       group by c.id, c.bonus
    loop
      ok := coalesce(
        (select bool_and(s is not null and s = any(comb.members)) from unnest(nonwild) s),
        true);

      if ok and comb.size >= 5 then
        ok := (select count(*) = count(distinct s) from unnest(nonwild) s);
      end if;

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

  -- Base rung comes from the NORMAL line count. greatest(1, ...) is the open
  -- question: when every winning line is special, the doc still starts at x0.5.
  if jsonb_array_length(won) > 0 then
    select multiplier into base_mult
      from slot.payout_ladder
     where lines = greatest(1, least(20, normal_lines));
    final_mult := base_mult + bonus_sum;
    if v_cap_final then
      final_mult := least(final_mult, v_max_mult);
    end if;
  end if;

  -- Q6: one award per scatter POSITION. Three scatters on the grid pay three times
  -- over, and only then does the per-spin ceiling apply.
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
    'free_spins_raw', free_raw     -- pre-cap, so the UI can say "capped at 10"
  );
end $$;

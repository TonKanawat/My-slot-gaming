-- ============================================================================
-- ⚠ ALREADY APPLIED — DO NOT RUN THIS FILE AGAIN.
-- It would reset every payout-ladder multiplier to its original value,
-- wiping anything changed since in Back office → Payout rules.
-- Kept as history only. See supabase/README.md.
-- ============================================================================

-- bluePi Slot — 0016 restore the paylines, and never lose them silently again
--
-- Symptom: every spin reported "no winning line", and slot.explain_grid returned an
-- empty array rather than 29 rows. Both scorers walk `for pl in select ... from
-- slot.payline`, so with that table empty they have nothing to score and honestly
-- report zero wins. The board looked fine, the symbols were right, the groups were
-- right — there were simply no lines to win on.
--
-- Two parts: put the 29 paylines and the ladder back, and make slot.game_ready()
-- refuse to call the game ready without them, so this can never again present as a
-- run of bad luck.

-- ---------------------------------------------------------------- the 29 paylines
insert into slot.payline (id, family, cells) values
  (1, 'straight', array[array[0,0],array[0,1],array[0,2],array[0,3],array[0,4]]::smallint[][]),
  (2, 'straight', array[array[1,0],array[1,1],array[1,2],array[1,3],array[1,4]]::smallint[][]),
  (3, 'straight', array[array[2,0],array[2,1],array[2,2],array[2,3],array[2,4]]::smallint[][]),
  (4, 'straight', array[array[3,0],array[3,1],array[3,2],array[3,3],array[3,4]]::smallint[][]),
  (5, 'straight', array[array[4,0],array[4,1],array[4,2],array[4,3],array[4,4]]::smallint[][]),
  (6, 'diagonal', array[array[0,0],array[1,1],array[2,2],array[3,3],array[4,4]]::smallint[][]),
  (7, 'diagonal', array[array[0,4],array[1,3],array[2,2],array[3,1],array[4,0]]::smallint[][]),
  (8, 'corner', array[array[0,0],array[0,4],array[4,0],array[4,4]]::smallint[][]),
  (9, 'zigzag', array[array[0,0],array[1,1],array[0,2],array[1,3],array[0,4]]::smallint[][]),
  (10, 'zigzag', array[array[1,0],array[2,1],array[1,2],array[2,3],array[1,4]]::smallint[][]),
  (11, 'zigzag', array[array[2,0],array[3,1],array[2,2],array[3,3],array[2,4]]::smallint[][]),
  (12, 'zigzag', array[array[3,0],array[4,1],array[3,2],array[4,3],array[3,4]]::smallint[][]),
  (13, 'zigzag', array[array[0,0],array[1,1],array[2,0],array[3,1],array[4,0]]::smallint[][]),
  (14, 'zigzag', array[array[0,1],array[1,2],array[2,1],array[3,2],array[4,1]]::smallint[][]),
  (15, 'zigzag', array[array[0,2],array[1,3],array[2,2],array[3,3],array[4,2]]::smallint[][]),
  (16, 'zigzag', array[array[0,3],array[1,4],array[2,3],array[3,4],array[4,3]]::smallint[][]),
  (17, 'hill', array[array[4,0],array[4,1],array[3,2],array[4,3],array[4,4]]::smallint[][]),
  (18, 'hill', array[array[3,0],array[3,1],array[2,2],array[3,3],array[3,4]]::smallint[][]),
  (19, 'hill', array[array[2,0],array[2,1],array[1,2],array[2,3],array[2,4]]::smallint[][]),
  (20, 'hill', array[array[1,0],array[1,1],array[0,2],array[1,3],array[1,4]]::smallint[][]),
  (21, 'hill', array[array[4,0],array[3,1],array[3,2],array[3,3],array[4,4]]::smallint[][]),
  (22, 'hill', array[array[3,0],array[2,1],array[2,2],array[2,3],array[3,4]]::smallint[][]),
  (23, 'hill', array[array[2,0],array[1,1],array[1,2],array[1,3],array[2,4]]::smallint[][]),
  (24, 'hill', array[array[1,0],array[0,1],array[0,2],array[0,3],array[1,4]]::smallint[][]),
  (25, 'vertical', array[array[0,0],array[1,0],array[2,0],array[3,0],array[4,0]]::smallint[][]),
  (26, 'vertical', array[array[0,1],array[1,1],array[2,1],array[3,1],array[4,1]]::smallint[][]),
  (27, 'vertical', array[array[0,2],array[1,2],array[2,2],array[3,2],array[4,2]]::smallint[][]),
  (28, 'vertical', array[array[0,3],array[1,3],array[2,3],array[3,3],array[4,3]]::smallint[][]),
  (29, 'vertical', array[array[0,4],array[1,4],array[2,4],array[3,4],array[4,4]]::smallint[][])
on conflict (id) do update set family = excluded.family, cells = excluded.cells;

-- ---------------------------------------------------------------- the payout ladder
insert into slot.payout_ladder (lines, multiplier) values
  (1, 0.5),  (2, 0.75), (3, 1.1),  (4, 1.25), (5, 1.5),
  (6, 1.75), (7, 2.0),  (8, 2.25), (9, 2.5),  (10, 2.75),
  (11, 3.0), (12, 3.25),(13, 3.5), (14, 3.75),(15, 4.0),
  (16, 4.25),(17, 4.5), (18, 4.75),(19, 5.0), (20, 6.0)
on conflict (lines) do update set multiplier = excluded.multiplier;

-- ---------------------------------------------------------------- readiness
-- The old check counted symbols and groups only. A game with neither paylines nor a
-- ladder passed it, then paid nothing for ever — indistinguishable from bad luck.
create or replace function slot.game_ready()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  n_symbols int;
  n_groups  int;
  n_scatter int;
  n_wild    int;
  n_lines   int;
  n_rungs   int;
  missing   text[] := '{}';
begin
  select count(*) into n_symbols from slot.symbol where is_active;
  select count(*) into n_groups from slot.combination c
   where c.is_active
     and exists (select 1 from slot.combination_symbol cs where cs.combination_id = c.id);
  select count(*) into n_wild    from slot.symbol where is_active and is_wild;
  select count(*) into n_scatter from slot.symbol where is_active and is_scatter;
  select count(*) into n_lines   from slot.payline;
  select count(*) into n_rungs   from slot.payout_ladder;

  -- A 5+ symbol group needs five distinct symbols on a line, so five is the floor
  -- at which the board can produce a win at all.
  if n_symbols < 5 then
    missing := array_append(missing, format('at least 5 reel symbols (currently %s)', n_symbols));
  end if;
  if n_groups < 1 then
    missing := array_append(missing, 'at least one winning combination with symbols in it');
  end if;
  -- Without these two the game runs and never pays, which is worse than refusing to run.
  if n_lines < 29 then
    missing := array_append(missing,
      format('the 29 paylines (currently %s) — re-run migration 0016', n_lines));
  end if;
  if n_rungs < 20 then
    missing := array_append(missing,
      format('the 20-rung payout ladder (currently %s) — re-run migration 0016', n_rungs));
  end if;

  return jsonb_build_object(
    'ready',    cardinality(missing) = 0,
    'missing',  to_jsonb(missing),
    'symbols',  n_symbols,
    'groups',   n_groups,
    'wilds',    n_wild,      -- optional: the game runs fine without them
    'scatters', n_scatter,
    'paylines', n_lines,
    'ladder',   n_rungs
  );
end $$;

do $$
declare r jsonb;
begin
  r := slot.game_ready();
  raise notice 'paylines: %  ladder: %  symbols: %  groups: %  ready: %',
    r->>'paylines', r->>'ladder', r->>'symbols', r->>'groups', r->>'ready';
end $$;

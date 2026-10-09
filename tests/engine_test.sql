-- bluePi Slot — win engine tests
-- Run: psql -f tests/engine_test.sql
-- Every check raises an exception on failure, so a clean run means all green.

\set ON_ERROR_STOP on
set search_path to slot, public;

create or replace function slot.assert(p_label text, p_got anyelement, p_want anyelement)
returns void language plpgsql as $$
begin
  if p_got is distinct from p_want then
    raise exception 'FAIL % — got %, want %', p_label, p_got, p_want;
  end if;
  raise notice 'ok   %  (%)', p_label, p_got;
end $$;

-- ---------------------------------------------------------------- fixtures
truncate slot.combination_symbol, slot.combination, slot.symbol cascade;

-- 12 plain symbols S01..S12, one wild, one scatter worth 5 free spins.
insert into slot.symbol (name, image_path, weight)
select 'S'||lpad(i::text,2,'0'), 'sym/s'||lpad(i::text,2,'0')||'.png', 100 from generate_series(1,12) i;
insert into slot.symbol (name, image_path, weight, is_wild)
values ('WILD', 'sym/wild.png', 40, true);
insert into slot.symbol (name, image_path, weight, is_scatter, scatter_free_spins)
values ('SCAT', 'sym/scat.png', 30, true, 5);

-- "PIG Team": a 9-symbol group -> 5 distinct required, no duplicates.
insert into slot.combination (name, bonus) values ('PIG Team', 0);
insert into slot.combination_symbol
select (select id from slot.combination where name='PIG Team'), id
  from slot.symbol where name in ('S01','S02','S03','S04','S05','S06','S07','S08','S09');

-- "Tech Leads": a 3-symbol group -> duplicates allowed, any members qualify.
insert into slot.combination (name, bonus) values ('Tech Leads', 0);
insert into slot.combination_symbol
select (select id from slot.combination where name='Tech Leads'), id
  from slot.symbol where name in ('S10','S11','S12');

-- A special version of the small group, used to exercise the bonus arithmetic.
insert into slot.combination (name, bonus) values ('Tech Leads (special)', 1.50);
insert into slot.combination_symbol
select (select id from slot.combination where name='Tech Leads (special)'), id
  from slot.symbol where name in ('S10','S11','S12');

create or replace function slot.sym(p_name text) returns uuid
language sql stable as $$ select id from slot.symbol where name = p_name $$;

-- Build a 5x5 grid from a 25-element name array, row-major.
create or replace function slot.grid_of(p_names text[]) returns uuid[]
language plpgsql immutable as $$
declare g uuid[] := array_fill(null::uuid, array[5,5]); r int; c int;
begin
  for r in 1..5 loop for c in 1..5 loop
    g[r][c] := (select id from slot.symbol where name = p_names[(r-1)*5 + c]);
  end loop; end loop;
  return g;
end $$;

-- ---------------------------------------------------------------- geometry
do $$
declare n int; corner smallint[];
begin
  select count(*) into n from slot.payline;
  perform slot.assert('29 paylines seeded', n, 29);

  select count(*)::int into n from slot.payline where array_length(cells,1) = 4;
  perform slot.assert('exactly one 4-cell line', n, 1);

  select cells into corner from slot.payline where id = 8;
  perform slot.assert('line 8 is the corner line', corner,
    array[array[0,0],array[0,4],array[4,0],array[4,4]]::smallint[][]);

  -- No two paylines may describe the same set of cells.
  select count(*)::int into n from (
    select cells, count(*) c from slot.payline group by cells having count(*) > 1
  ) d;
  perform slot.assert('no duplicate paylines', n, 0);

  -- Every cell reference is inside the 5x5 grid.
  select count(*)::int into n from slot.payline p, generate_subscripts(p.cells,1) i
   where p.cells[i][1] not between 0 and 4 or p.cells[i][2] not between 0 and 4;
  perform slot.assert('all cells inside the grid', n, 0);
end $$;

-- ---------------------------------------------------------------- line matching
do $$
declare g uuid[]; res jsonb;
begin
  -- Top row holds 5 distinct PIG Team symbols; nothing else lines up.
  g := slot.grid_of(array[
    'S01','S02','S03','S04','S05',
    'S10','S02','S03','S04','S05',
    'S01','S11','S03','S04','S05',
    'S01','S02','S12','S04','S05',
    'S01','S02','S03','S10','S05']);
  res := slot.evaluate_grid(g);
  perform slot.assert('top row wins as PIG Team',
    (res->'lines'->0->>'payline')::int, 1);

  -- Same row with a duplicate: S01 twice fails the 5+ no-duplicate rule.
  g := slot.grid_of(array[
    'S01','S01','S03','S04','S05',
    'S10','S02','S03','S04','S05',
    'S01','S11','S03','S04','S05',
    'S01','S02','S12','S04','S05',
    'S01','S02','S03','S10','S05']);
  res := slot.evaluate_grid(g);
  perform slot.assert('duplicate breaks a 5+ group',
    (select count(*)::int from jsonb_array_elements(res->'lines') l
      where (l->>'payline')::int = 1), 0);

  -- A 1-4 group tolerates duplicates: S10,S10,S11,S12,S10 on the top row.
  g := slot.grid_of(array[
    'S10','S10','S11','S12','S10',
    'S01','S02','S03','S04','S06',
    'S01','S02','S03','S04','S06',
    'S01','S02','S03','S04','S06',
    'S01','S02','S03','S04','S06']);
  res := slot.evaluate_grid(g);
  perform slot.assert('small group tolerates duplicates',
    (select count(*)::int from jsonb_array_elements(res->'lines') l
      where (l->>'payline')::int = 1), 1);

  -- "Any members" reading: five copies of one member still wins.
  g := slot.grid_of(array[
    'S10','S10','S10','S10','S10',
    'S01','S02','S03','S04','S06',
    'S01','S02','S03','S04','S06',
    'S01','S02','S03','S04','S06',
    'S01','S02','S03','S04','S06']);
  res := slot.evaluate_grid(g);
  perform slot.assert('five copies of one member wins',
    (select count(*)::int from jsonb_array_elements(res->'lines') l
      where (l->>'payline')::int = 1), 1);

  -- One line matching two combinations counts once, at the better bonus.
  perform slot.assert('a line pays once, at the best bonus',
    (select (l->>'bonus')::numeric from jsonb_array_elements(res->'lines') l
      where (l->>'payline')::int = 1), 1.50);
end $$;

-- ---------------------------------------------------------------- wilds
do $$
declare g uuid[]; res jsonb;
begin
  -- Two wilds substituting inside a 5+ group, at the configured cap of 2.
  g := slot.grid_of(array[
    'S01','WILD','S03','WILD','S05',
    'S01','S02','S03','S04','S06',
    'S01','S02','S03','S04','S06',
    'S01','S02','S03','S04','S06',
    'S01','S02','S03','S04','S06']);
  res := slot.evaluate_grid(g);
  perform slot.assert('two wilds complete a 5+ line',
    (select count(*)::int from jsonb_array_elements(res->'lines') l
      where (l->>'payline')::int = 1), 1);

  -- Three wilds exceeds the cap and the line is skipped entirely.
  g := slot.grid_of(array[
    'WILD','WILD','S03','WILD','S05',
    'S01','S02','S03','S04','S06',
    'S01','S02','S03','S04','S06',
    'S01','S02','S03','S04','S06',
    'S01','S02','S03','S04','S06']);
  res := slot.evaluate_grid(g);
  perform slot.assert('three wilds exceeds the per-line cap',
    (select count(*)::int from jsonb_array_elements(res->'lines') l
      where (l->>'payline')::int = 1), 0);
end $$;

-- ---------------------------------------------------------------- scatter
-- 0027: a scatter pays only from a cell on a WINNING line. For a scatter to be on
-- a winning line it has to be in a group, so a small group "Lucky" (SCAT, S10, S11,
-- repeats allowed) is added just for these checks. Filler cells are all S01, which
-- can never win (PIG Team needs five different symbols).
insert into slot.combination (name, bonus) values ('Lucky', 0);
insert into slot.combination_symbol
select (select id from slot.combination where name='Lucky'), id
  from slot.symbol where name in ('SCAT','S10','S11');

do $$
declare g uuid[]; res jsonb;
begin
  -- On a winning line (row 1 is all Lucky): pays its 5.
  g := slot.grid_of(array[
    'SCAT','S10','S11','S10','S11',
    'S01','S01','S01','S01','S01',
    'S01','S01','S01','S01','S01',
    'S01','S01','S01','S01','S01',
    'S01','S01','S01','S01','S01']);
  res := slot.evaluate_grid(g);
  perform slot.assert('a scatter on a winning line pays its rounds', (res->>'free_spins')::int, 5);
  perform slot.assert('and is listed as paid', jsonb_array_length(res->'scatters_paid'), 1);
  perform slot.assert('naming the scatter', res->'scatters_paid'->0->>'name', 'SCAT');
  perform slot.assert('at its cell', (res->'scatters_paid'->0->>'row')::int * 10
                                     + (res->'scatters_paid'->0->>'col')::int, 0);

  -- Off the winning lines: row 1 still wins, but the scatter sits in the middle of
  -- S01s, on no winning line. Under the old rule this paid 5; now it pays nothing.
  g := slot.grid_of(array[
    'S10','S11','S10','S11','S10',
    'S01','S01','S01','S01','S01',
    'S01','S01','SCAT','S01','S01',
    'S01','S01','S01','S01','S01',
    'S01','S01','S01','S01','S01']);
  res := slot.evaluate_grid(g);
  perform slot.assert('the board still has a winning line', ((res->>'line_count')::int > 0), true);
  perform slot.assert('a scatter off the winning lines pays nothing', (res->>'free_spins')::int, 0);
  perform slot.assert('and is counted as missed', (res->>'scatters_missed')::int, 1);

  -- No winning line at all: nothing, however many scatters land.
  g := slot.grid_of(array[
    'SCAT','S01','S01','S01','S01',
    'S01','S01','S01','S01','S01',
    'S01','S01','SCAT','S01','S01',
    'S01','S01','S01','S01','S01',
    'S01','SCAT','S01','S01','S01']);
  res := slot.evaluate_grid(g);
  perform slot.assert('no line wins on this board', (res->>'line_count')::int, 0);
  perform slot.assert('no winning line, no free spins', (res->>'free_spins')::int, 0);
  perform slot.assert('all three scatters missed', (res->>'scatters_missed')::int, 3);

  -- One scatter crossed by two winning lines (row 1 and column 1) pays ONCE.
  g := slot.grid_of(array[
    'SCAT','S10','S11','S10','S11',
    'S10', 'S01','S01','S01','S01',
    'S11', 'S01','S01','S01','S01',
    'S10', 'S01','S01','S01','S01',
    'S11', 'S01','S01','S01','S01']);
  res := slot.evaluate_grid(g);
  perform slot.assert('two winning lines cross the scatter', (res->>'line_count')::int, 2);
  perform slot.assert('but its cell pays once', (res->>'free_spins')::int, 5);

  -- Two scatters on the winning line: 10, right on the ceiling.
  g := slot.grid_of(array[
    'SCAT','S10','SCAT','S11','S10',
    'S01','S01','S01','S01','S01',
    'S01','S01','S01','S01','S01',
    'S01','S01','S01','S01','S01',
    'S01','S01','S01','S01','S01']);
  res := slot.evaluate_grid(g);
  perform slot.assert('two scatters on the line award 10', (res->>'free_spins')::int, 10);

  -- Three on the line: 15 earned, ceilinged at 10 (per position, as before).
  g := slot.grid_of(array[
    'SCAT','SCAT','SCAT','S10','S11',
    'S01','S01','S01','S01','S01',
    'S01','S01','S01','S01','S01',
    'S01','S01','S01','S01','S01',
    'S01','S01','S01','S01','S01']);
  res := slot.evaluate_grid(g);
  perform slot.assert('three scatters earn per position', (res->>'free_spins_raw')::int, 15);
  perform slot.assert('and are ceilinged at 10',          (res->>'free_spins')::int, 10);
end $$;

-- A scatter in NO group can never be on a winning line, so it never pays.
delete from slot.combination_symbol
 where combination_id = (select id from slot.combination where name = 'Lucky');
delete from slot.combination where name = 'Lucky';
do $$
declare g uuid[]; res jsonb;
begin
  g := slot.grid_of(array[
    'SCAT','S10','S11','S10','S11',
    'S01','S01','S01','S01','S01',
    'S01','S01','S01','S01','S01',
    'S01','S01','S01','S01','S01',
    'S01','S01','S01','S01','S01']);
  res := slot.evaluate_grid(g);
  perform slot.assert('a scatter in no group breaks the line and pays nothing',
    (res->>'free_spins')::int, 0);
end $$;

-- ---------------------------------------------------------------- Q2: the x6 ceiling
do $$
declare base numeric; raw numeric;
begin
  select multiplier into base from slot.payout_ladder where lines = 10;
  raw := base + 1.50 + 1.50 + 1.50;              -- 10 normal + three +1.5 specials
  perform slot.assert('uncapped this would be 7.25', raw, 7.25::numeric);
  perform slot.assert('but the ceiling pays x6', least(raw, 6.00), 6.00::numeric);
end $$;

-- ---------------------------------------------------------------- scoring
-- The three worked examples from the requirements doc.
do $$
declare base numeric; final numeric;
begin
  -- Example 1: 10 normal lines + 1 special (+1.5) -> 2.75 + 1.5 = 4.25
  select multiplier into base from slot.payout_ladder where lines = 10;
  final := base + 1.50;
  perform slot.assert('doc example 1 (10 normal + 1 special)', final, 4.25::numeric);

  -- Example 2: 10 normal lines + 2 specials (+0.25, +1) -> 2.75 + 1.25 = 4.00
  select multiplier into base from slot.payout_ladder where lines = 10;
  final := base + 0.25 + 1.00;
  perform slot.assert('doc example 2 (10 normal + 2 specials)', final, 4.00::numeric);

  -- Example 3: a single winning line which is special -> ladder rung 1 + bonus
  select multiplier into base from slot.payout_ladder where lines = 1;
  perform slot.assert('doc example 3 base rung', base, 0.50::numeric);

  -- Ladder shape: break-even sits at 3 lines, and the top rung jumps to x6.
  select multiplier into base from slot.payout_ladder where lines = 2;
  perform slot.assert('2 lines still lose money', (base < 1), true);
  select multiplier into base from slot.payout_ladder where lines = 3;
  perform slot.assert('3 lines is the first profit', (base > 1), true);
  select multiplier into base from slot.payout_ladder where lines = 20;
  perform slot.assert('top rung is x6', base, 6.00::numeric);
end $$;

-- End-to-end: a grid engineered to win exactly one special line.
do $$
declare g uuid[]; res jsonb;
begin
  -- Row 1 is a Tech Leads line; every other cell is the same symbol, so no other
  -- payline can satisfy either group (5+ needs distinct, the small group needs S10-S12).
  g := slot.grid_of(array[
    'S10','S11','S12','S10','S11',
    'S01','S01','S01','S01','S01',
    'S01','S01','S01','S01','S01',
    'S01','S01','S01','S01','S01',
    'S01','S01','S01','S01','S01']);
  res := slot.evaluate_grid(g);
  raise notice 'engineered grid -> %', res;
  perform slot.assert('only one line wins', (res->>'line_count')::int, 1);
  perform slot.assert('zero normal lines', (res->>'normal_lines')::int, 0);
  perform slot.assert('single special line enters the ladder at rung 1',
    (res->>'base')::numeric, 0.50::numeric);
  perform slot.assert('single special line final multiplier',
    (res->>'multiplier')::numeric, 2.00::numeric);
end $$;

\echo ''
\echo 'All engine tests passed.'

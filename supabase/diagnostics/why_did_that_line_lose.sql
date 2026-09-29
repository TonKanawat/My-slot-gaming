-- bluePi Slot — diagnostics: "that line definitely won and the game said no"
-- Safe to run in the Supabase SQL editor: reads only, changes nothing.
-- Run the three queries together; the first two almost always contain the answer.

-- 1. Symbols that belong to NO active winning combination.
--    A payline pays only when every cell on it is a member of one group, so any
--    line one of these lands on loses, no matter how good it looks.
select y.name as symbol_in_no_group, y.weight
  from slot.symbol y
 where y.is_active
   and not exists (
     select 1 from slot.combination_symbol cs
       join slot.combination c on c.id = cs.combination_id and c.is_active
      where cs.symbol_id = y.id)
 order by 1;

-- 2. Each active group's size against the number of symbols in play.
--    A group meant to hold "everything" should match active_symbols exactly.
select c.name as group_name,
       count(cs.symbol_id) as members,
       (select count(*) from slot.symbol where is_active) as active_symbols,
       c.bonus
  from slot.combination c
  left join slot.combination_symbol cs on cs.combination_id = c.id
 where c.is_active
 group by c.name, c.bonus
 order by 1;

-- 3. The most recent spin, all 29 paylines, with the reason each one lost.
--    Since 0022 the log stores the grid compactly; grid_from_bytes rebuilds it.
--    Change the limit/offset to look further back.
select (e->>'payline')::int as line,
       e->>'family'  as family,
       e->>'symbols' as what_landed,
       (e->>'won')::boolean as won,
       coalesce(e->>'group', e->>'reason') as verdict
  from (select slot.explain_grid(slot.grid_from_bytes(grid)) as ex
          from slot.spin_log
         order by created_at desc
         limit 1 offset 0) s,
       jsonb_array_elements(s.ex) e
 order by 1;

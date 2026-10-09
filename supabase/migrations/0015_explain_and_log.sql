-- ============================================================================
-- ⚠ ALREADY APPLIED — DO NOT RUN THIS FILE AGAIN.
-- Later files replaced parts of it. Running it again would silently put these
-- old versions back over the current ones:
--   slot.spin          → current version is in 0022_storage_diet.sql
--   slot.explain_grid  → current version is in 0018_explain_wilds.sql
-- The old spin writes to spin-log columns that no longer exist, so every spin
-- would fail until 0022 is run again.
-- Kept as history only. See supabase/README.md.
-- ============================================================================

-- bluePi Slot — 0015 explain a spin, and keep a record of it
--
-- "That line definitely won and the game said no" is unanswerable today: the grid
-- is not stored anywhere, and nothing reports WHY a line failed. Both are fixed
-- here. The rule that catches people out is that for a 1-4 symbol group, EVERY
-- cell on the line must belong to the group — three members plus two outsiders is
-- not a win.

-- ---------------------------------------------------------------- keep the spin
create table if not exists slot.spin_log (
  id         bigserial primary key,
  user_id    uuid not null references slot.app_user(id) on delete cascade,
  bet        integer not null,
  is_free    boolean not null default false,
  grid       uuid[] not null,
  result     jsonb  not null,
  created_at timestamptz not null default now()
);
create index if not exists spin_log_user_time on slot.spin_log (user_id, created_at desc);

alter table slot.spin_log enable row level security;
drop policy if exists spin_log_read on slot.spin_log;
create policy spin_log_read on slot.spin_log for select
  using (user_id = slot.current_user_id() or slot.is_admin());

-- ---------------------------------------------------------------- why did it not win?
-- For each payline: what landed, whether it won, and if not, the nearest miss.
create or replace function slot.explain_grid(p_grid uuid[])
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_max_wild int := slot.setting_int('max_wilds_per_line');
  pl       record;
  comb     record;
  syms     uuid[];
  nonwild  uuid[];
  wilds    int;
  allowed  int;
  outsiders int;
  dup      boolean;
  best_miss text;
  best_out  int;
  won_name  text;
  out      jsonb := '[]'::jsonb;
  names    text;
begin
  for pl in select id, family, cells from slot.payline order by id loop
    syms := slot.line_symbols(p_grid, pl.cells);

    select string_agg(coalesce(y.name, '?'), ', ' order by t.ord)
      into names
      from unnest(syms) with ordinality as t(s, ord)
      left join slot.symbol y on y.id = t.s;

    select count(*) into wilds
      from unnest(syms) s join slot.symbol y on y.id = s where y.is_wild;
    allowed := case when pl.family = 'corner' then 1 else v_max_wild end;

    select coalesce(array_agg(s), '{}') into nonwild
      from unnest(syms) s
     where not exists (select 1 from slot.symbol y where y.id = s and y.is_wild);

    won_name := null; best_miss := null; best_out := 999;

    if wilds > allowed then
      best_miss := format('%s wilds on the line, at most %s allowed', wilds, allowed);
    else
      for comb in
        select c.id, c.name, c.bonus, count(cs.symbol_id) as size,
               array_agg(cs.symbol_id) as members
          from slot.combination c
          join slot.combination_symbol cs on cs.combination_id = c.id
         where c.is_active
         group by c.id, c.name, c.bonus
      loop
        select count(*) into outsiders
          from unnest(nonwild) s where not (s = any(comb.members));
        dup := comb.size >= 5
               and (select count(*) <> count(distinct s) from unnest(nonwild) s);

        if outsiders = 0 and not dup then
          won_name := comb.name;
          exit;
        elsif outsiders < best_out then
          best_out := outsiders;
          best_miss := case
            when outsiders > 0 then
              format('%s of the %s symbols are not in "%s" — every cell must belong to the group',
                     outsiders, array_length(syms, 1), comb.name)
            else
              format('"%s" needs %s different symbols, and one is repeated', comb.name, array_length(syms, 1))
          end;
        end if;
      end loop;
    end if;

    out := out || jsonb_build_object(
      'payline', pl.id,
      'family',  pl.family,
      'symbols', names,
      'won',     won_name is not null,
      'group',   won_name,
      'reason',  case when won_name is not null then null else best_miss end
    );
  end loop;

  return out;
end $$;

create or replace function public.explain_grid(p_grid uuid[])
returns jsonb language sql stable as $$
  select slot.explain_grid(p_grid);
$$;

-- ---------------------------------------------------------------- record each spin
create or replace function slot.spin(p_user_id uuid, p_bet integer)
returns jsonb language plpgsql volatile as $$
declare
  st      slot.free_spin_state%rowtype;
  is_free boolean := false;
  stake   integer := p_bet;
  grid    uuid[];
  result  jsonb;
  ready   jsonb;
begin
  ready := slot.game_ready();
  if not (ready->>'ready')::boolean then
    raise exception 'the slot is not configured yet: %',
      array_to_string(array(select jsonb_array_elements_text(ready->'missing')), '; ')
      using errcode = 'object_not_in_prerequisite_state';
  end if;

  select * into st from slot.free_spin_state where user_id = p_user_id;

  if found and st.remaining > 0 then
    is_free := true;
    stake   := st.stake;
  else
    if not (to_jsonb(p_bet) <@ (select value from slot.setting where key = 'bet_options')) then
      raise exception 'bet % is not one of the allowed amounts', p_bet
        using errcode = 'check_violation';
    end if;
  end if;

  grid   := slot.draw_grid();
  result := slot.evaluate_grid(grid) || jsonb_build_object('grid', to_jsonb(grid));
  result := slot.apply_spin(p_user_id, stake, result, is_free);

  -- Kept so a disputed spin can always be re-examined, which matters when points
  -- turn into real prizes.
  insert into slot.spin_log (user_id, bet, is_free, grid, result)
  values (p_user_id, stake, is_free, grid, result);

  return result;
end $$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on slot.spin_log to authenticated;
    grant execute on function public.explain_grid(uuid[]) to authenticated;
  end if;
end $$;

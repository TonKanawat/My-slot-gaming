-- bluePi Slot — 0022 keep the database inside the Free plan
--
-- Measured on 2,000 real spins, each spin cost about 2.5 KB: 2,269 bytes in
-- slot.spin_log and ~217 in the ledger. The Free plan allows 500 MB, so heavy play
-- (60 people x 150 spins a day) would fill it in about a month, and a full database
-- goes read-only — the game stops until data is deleted.
--
-- Four changes, agreed with M:
--
--   1. The spin log goes compact. The grid was stored as 25 full uuids and then a
--      second time inside the result JSON, with every winning line spelled out. It is
--      now 50 bytes (a 2-byte code per cell) plus the numbers a dispute needs. The row
--      drops from 2,269 bytes to ~190. Tested on 2,000 spins: every grid rebuilt
--      exactly and every one re-scored to the same result, so nothing is lost.
--   2. Spin-log rows older than history_days (90) are deleted nightly.
--   3. Bet and win ledger rows older than history_days roll up into one row per
--      person per Bangkok day. Totals and after-balances are preserved exactly.
--      Grants, admin edits, prize holds and refunds are never rolled up — and nor is
--      first_login_grant, which slot.claim_account() looks for to avoid paying the
--      welcome bonus twice.
--   4. slot.storage_report() for a gauge in the back office.
--
-- Safe to run twice, and safe to run as a single transaction.

-- ---------------------------------------------------------------- settings
insert into slot.setting (key, value) values
  ('history_days', '90'::jsonb),
  ('db_limit_mb',  '500'::jsonb),
  ('db_warn_mb',   '400'::jsonb)
on conflict (key) do nothing;

-- Added here but first used only when the nightly job runs, never inside this file:
-- a new enum value cannot be used in the same transaction that adds it.
alter type slot.ledger_reason add value if not exists 'play_summary';

-- ---------------------------------------------------------------- symbol codes
-- A small permanent number per symbol, so a grid cell costs 2 bytes instead of 16.
-- Codes are never reused: an archived symbol keeps its code, because old log rows
-- still point at it.
create sequence if not exists slot.symbol_code_seq as smallint;
alter table slot.symbol add column if not exists code smallint;
update slot.symbol set code = nextval('slot.symbol_code_seq') where code is null;
alter table slot.symbol alter column code set default nextval('slot.symbol_code_seq');
alter table slot.symbol alter column code set not null;
alter sequence slot.symbol_code_seq owned by slot.symbol.code;
create unique index if not exists symbol_code_key on slot.symbol (code);

-- Row-major, 2 bytes per cell, big-endian. 25 cells = 50 bytes. An unknown cell is
-- written as 0, which no symbol ever has, so it decodes back to null.
create or replace function slot.grid_to_bytes(p_grid uuid[])
returns bytea language sql stable security definer set search_path = '' as $$
  select decode(string_agg(lpad(to_hex(coalesce(y.code, 0)::int), 4, '0'), '' order by u.o), 'hex')
    from unnest(p_grid) with ordinality as u(s, o)
    left join slot.symbol y on y.id = u.s;
$$;

create or replace function slot.grid_from_bytes(p bytea)
returns uuid[] language plpgsql stable security definer set search_path = '' as $$
declare
  g uuid[] := array_fill(null::uuid, array[5,5]);
  i int;
  c int;
begin
  if p is null or length(p) <> 50 then
    raise exception 'not a stored 5x5 grid' using errcode = 'invalid_parameter_value';
  end if;
  for i in 0..24 loop
    c := get_byte(p, 2 * i) * 256 + get_byte(p, 2 * i + 1);
    g[i / 5 + 1][i % 5 + 1] := (select y.id from slot.symbol y where y.code = c);
  end loop;
  return g;
end $$;

-- ---------------------------------------------------------------- the compact log
-- Only converts when the old wide table is still in place, so a second run of this
-- file leaves the compact table alone.
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'slot' and table_name = 'spin_log'
                and column_name = 'result') then

    create table slot.spin_log_compact (
      id          bigserial primary key,
      user_id     uuid not null references slot.app_user(id) on delete cascade,
      created_at  timestamptz not null default now(),
      bet         integer not null,
      is_free     boolean not null default false,
      line_count  smallint not null,
      multiplier  numeric(6,2) not null,
      payout      integer not null,
      free_spins  smallint not null,
      grid        bytea not null check (length(grid) = 50)
    );

    insert into slot.spin_log_compact
      (id, user_id, created_at, bet, is_free, line_count, multiplier, payout, free_spins, grid)
    select l.id, l.user_id, l.created_at, l.bet, l.is_free,
           coalesce((l.result->>'line_count')::smallint, 0),
           coalesce((l.result->>'multiplier')::numeric, 0),
           coalesce((l.result->>'payout')::int, 0),
           coalesce((l.result->>'free_spins')::smallint, 0),
           slot.grid_to_bytes(l.grid)
      from slot.spin_log l;

    perform setval(pg_get_serial_sequence('slot.spin_log_compact', 'id'),
                   greatest((select max(id) from slot.spin_log_compact), 1));

    -- Dropping the wide table, rather than deleting from it, is what hands the space
    -- back straight away.
    drop table slot.spin_log;
    alter table slot.spin_log_compact rename to spin_log;
    alter index slot.spin_log_compact_pkey rename to spin_log_pkey;
    alter sequence slot.spin_log_compact_id_seq rename to spin_log_id_seq;

    raise notice 'spin log converted to the compact format';
  end if;
end $$;

create index if not exists spin_log_user_time on slot.spin_log (user_id, created_at desc);

alter table slot.spin_log enable row level security;
drop policy if exists spin_log_read on slot.spin_log;
create policy spin_log_read on slot.spin_log for select
  using (user_id = slot.current_user_id() or slot.is_admin());

-- ---------------------------------------------------------------- the spin, writing compact rows
-- Identical to 0015 apart from the insert. What goes back to the browser is unchanged.
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

  -- Kept so a disputed spin can always be re-examined: the grid rebuilds exactly
  -- with slot.grid_from_bytes(), and what was actually paid is recorded alongside.
  insert into slot.spin_log
    (user_id, bet, is_free, line_count, multiplier, payout, free_spins, grid)
  values
    (p_user_id, stake, is_free,
     (result->>'line_count')::smallint,
     (result->>'multiplier')::numeric,
     coalesce((result->>'payout')::int, 0),
     coalesce((result->>'free_spins')::smallint, 0),
     slot.grid_to_bytes(grid));

  return result;
end $$;

-- ---------------------------------------------------------------- nightly clean-up
-- The cut-off is a Bangkok midnight, so a day is never split between a summary row
-- and a handful of stragglers.
create or replace function slot.prune_history()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_days    int := slot.setting_int('history_days');
  v_cut     timestamptz;
  n_spins   bigint := 0;
  n_rows    bigint := 0;
  n_sums    bigint := 0;
  n_cron    bigint := 0;
  report    jsonb;
begin
  v_cut := (date_trunc('day', now() at time zone 'Asia/Bangkok')
            - make_interval(days => v_days)) at time zone 'Asia/Bangkok';

  delete from slot.spin_log where created_at < v_cut;
  get diagnostics n_spins = row_count;

  -- One row per person per Bangkok day, carrying the summed movement and the
  -- balances as they stood after that day's last spin.
  insert into slot.ledger
    (user_id, reason, free_delta, points_delta, free_after, points_after,
     is_free_spin, note, created_at)
  select g.user_id, 'play_summary', g.free_delta, g.points_delta,
         g.free_after, g.points_after, false,
         format('%s bets and %s wins on %s, rolled up after %s days',
                g.bets, g.wins, g.day, v_days),
         g.last_at
    from (
      select l.user_id,
             (l.created_at at time zone 'Asia/Bangkok')::date                  as day,
             sum(l.free_delta)                                                 as free_delta,
             sum(l.points_delta)                                               as points_delta,
             count(*) filter (where l.reason = 'bet')                          as bets,
             count(*) filter (where l.reason = 'win')                          as wins,
             max(l.created_at)                                                 as last_at,
             (array_agg(l.free_after   order by l.created_at desc, l.id desc))[1] as free_after,
             (array_agg(l.points_after order by l.created_at desc, l.id desc))[1] as points_after
        from slot.ledger l
       where l.reason in ('bet', 'win') and l.created_at < v_cut
       group by 1, 2
    ) g;
  get diagnostics n_sums = row_count;

  delete from slot.ledger where reason in ('bet', 'win') and created_at < v_cut;
  get diagnostics n_rows = row_count;

  -- pg_cron keeps a row for every run it has ever made. Supabase's own guidance is
  -- to trim it; a week is plenty to see whether jobs are running.
  if to_regclass('cron.job_run_details') is not null then
    execute 'delete from cron.job_run_details where end_time < now() - interval ''7 days''';
    get diagnostics n_cron = row_count;
  end if;

  report := jsonb_build_object(
    'at', now(), 'cutoff', v_cut, 'history_days', v_days,
    'spins_deleted', n_spins, 'ledger_rows_rolled_up', n_rows,
    'summary_rows_written', n_sums, 'cron_rows_deleted', n_cron);

  insert into slot.setting (key, value) values ('last_prune', report)
  on conflict (key) do update set value = excluded.value;

  return report;
end $$;

-- Nobody but the scheduler and the admin wrapper below should reach this.
revoke execute on function slot.prune_history() from public;

-- ---------------------------------------------------------------- the gauge
create or replace function slot.storage_report()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object(
    'database_bytes', pg_database_size(current_database()),
    'limit_bytes',    (slot.setting_int('db_limit_mb') * 1024 * 1024)::bigint,
    'warn_bytes',     (slot.setting_int('db_warn_mb')  * 1024 * 1024)::bigint,
    'spin_log_bytes', pg_total_relation_size('slot.spin_log'),
    'spin_log_rows',  (select count(*) from slot.spin_log),
    'ledger_bytes',   pg_total_relation_size('slot.ledger'),
    'ledger_rows',    (select count(*) from slot.ledger),
    'oldest_spin',    (select min(created_at) from slot.spin_log),
    'history_days',   slot.setting_int('history_days'),
    'last_prune',     (select value from slot.setting where key = 'last_prune')
  );
end $$;

create or replace function slot.save_history_days(p_days integer)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;
  if p_days < 7 or p_days > 3650 then
    raise exception 'keep between 7 and 3650 days of history' using errcode = 'check_violation';
  end if;
  update slot.setting set value = to_jsonb(p_days) where key = 'history_days';
end $$;

-- ---------------------------------------------------------------- public API
create or replace function public.storage_report()
returns jsonb language sql stable as $$ select slot.storage_report(); $$;

create or replace function public.save_history_days(p_days integer)
returns void language sql volatile as $$ select slot.save_history_days(p_days); $$;

-- The one way to run the clean-up by hand. Definer rights, because the job itself is
-- revoked from everyone, and the admin check is here rather than inside the job so
-- the scheduler — which has no signed-in user — can still run it.
create or replace function public.prune_history_now()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;
  return slot.prune_history();
end $$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on slot.spin_log to authenticated;
    grant execute on function
      public.storage_report(), public.save_history_days(integer), public.prune_history_now()
    to authenticated;
    revoke execute on function public.prune_history_now() from anon;
  end if;
end $$;

-- ---------------------------------------------------------------- the schedule
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('bluepi-slot-prune-history')
      where exists (select 1 from cron.job where jobname = 'bluepi-slot-prune-history');
    -- 20:30 UTC = 03:30 Asia/Bangkok, when nobody is playing.
    perform cron.schedule('bluepi-slot-prune-history', '30 20 * * *',
                          'select slot.prune_history()');
    raise notice 'scheduled the nightly history clean-up';
  else
    raise notice 'pg_cron is not installed — the clean-up is not scheduled';
  end if;
end $$;

do $$
begin
  raise notice 'spin log: % rows, %; database: %',
    (select count(*) from slot.spin_log),
    pg_size_pretty(pg_total_relation_size('slot.spin_log')),
    pg_size_pretty(pg_database_size(current_database()));
end $$;

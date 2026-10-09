-- ============================================================================
-- ⚠ ALREADY APPLIED — DO NOT RUN THIS FILE AGAIN.
-- Later files replaced parts of it. Running it again would silently put these
-- old versions back over the current ones:
--   slot.submit_claim / public.claim_reward  → current version is in 0029_promotions.sql
--   public.reward_claims (view)              → current version is in 0029_promotions.sql
-- An old one-argument claim_reward would then sit beside the new one, and reward
-- discounts would stop being applied to claims.
-- Kept as history only. See supabase/README.md.
-- ============================================================================

-- bluePi Slot — 0019 rewards claiming
--
-- The doc's prize pool (Gold 5,000 / Silver 3,750 / Bronze 2,000), claimed with
-- Wallet points only, reviewed by an admin, with a six-month public history.
--
-- Two decisions worth stating, both confirmed by M:
--
--   * Points are HELD when the claim is submitted, not when it is approved. A
--     5,000-point balance can therefore fund exactly one Gold Coin claim, not three
--     pending ones the wallet cannot cover. Cancelling or rejecting returns the
--     points in full, and every movement is written to the ledger, so the audit
--     trail explains a balance that dropped without a bet.
--   * The claim stores the prize's name and price as they were at the moment of
--     claiming. Prices are editable, and history must not silently rewrite what
--     someone actually paid.

-- ---------------------------------------------------------------- catalogue
create table if not exists slot.reward (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  price      integer not null check (price > 0),
  sort_order integer not null default 0,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

insert into slot.reward (name, price, sort_order) values
  ('Gold Coin',   5000, 1),
  ('Silver Coin', 3750, 2),
  ('Bronze Coin', 2000, 3)
on conflict (name) do nothing;

-- ---------------------------------------------------------------- claims
do $$ begin
  create type slot.claim_status as enum ('pending','approved','rejected','cancelled');
exception when duplicate_object then null; end $$;

create table if not exists slot.reward_claim (
  id          bigserial primary key,
  user_id     uuid not null references slot.app_user(id) on delete cascade,
  reward_id   uuid not null references slot.reward(id),
  reward_name text not null,      -- snapshot at claim time
  price       integer not null,   -- snapshot at claim time
  status      slot.claim_status not null default 'pending',
  decided_by  uuid references slot.app_user(id),
  decided_at  timestamptz,
  note        text,
  created_at  timestamptz not null default now()
);
create index if not exists reward_claim_user_time on slot.reward_claim (user_id, created_at desc);
create index if not exists reward_claim_pending on slot.reward_claim (created_at) where status = 'pending';

-- ---------------------------------------------------------------- submit
create or replace function slot.submit_claim(p_reward_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  me   uuid := slot.current_user_id();
  r    slot.reward%rowtype;
  w    slot.wallet%rowtype;
  cid  bigint;
begin
  if me is null then
    raise exception 'sign in first' using errcode = 'insufficient_privilege';
  end if;

  select * into r from slot.reward where id = p_reward_id and is_active;
  if not found then
    raise exception 'that prize is not available' using errcode = 'no_data_found';
  end if;

  -- Serialise against a spin landing at the same moment.
  select * into w from slot.wallet where user_id = me for update;
  if not found then
    raise exception 'no wallet' using errcode = 'no_data_found';
  end if;

  if w.points < r.price then
    raise exception 'the Wallet holds % points, and % needs %',
      w.points, r.name, r.price using errcode = 'check_violation';
  end if;

  update slot.wallet
     set points = points - r.price, updated_at = now()
   where user_id = me
   returning * into w;

  insert into slot.reward_claim (user_id, reward_id, reward_name, price)
  values (me, r.id, r.name, r.price)
  returning id into cid;

  insert into slot.ledger (user_id, reason, free_delta, points_delta,
                           free_after, points_after, actor_id, note)
  values (me, 'reward_hold', 0, -r.price, w.free_points, w.points, me,
          format('claim #%s — %s', cid, r.name));

  return jsonb_build_object('claim_id', cid, 'reward', r.name,
                            'price', r.price, 'points', w.points);
end $$;

-- ---------------------------------------------------------------- cancel (by the claimant)
-- Allowed only while the claim is still pending, which is exactly the window before
-- an admin has decided anything.
create or replace function slot.cancel_claim(p_claim_id bigint)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  me uuid := slot.current_user_id();
  c  slot.reward_claim%rowtype;
  w  slot.wallet%rowtype;
begin
  select * into c from slot.reward_claim where id = p_claim_id for update;
  if not found then
    raise exception 'no such claim' using errcode = 'no_data_found';
  end if;
  if c.user_id <> me then
    raise exception 'that claim is not yours' using errcode = 'insufficient_privilege';
  end if;
  if c.status <> 'pending' then
    raise exception 'that claim was already %s and cannot be cancelled', c.status
      using errcode = 'check_violation';
  end if;

  update slot.reward_claim
     set status = 'cancelled', decided_by = me, decided_at = now()
   where id = c.id;

  update slot.wallet
     set points = points + c.price, updated_at = now()
   where user_id = me
   returning * into w;

  insert into slot.ledger (user_id, reason, free_delta, points_delta,
                           free_after, points_after, actor_id, note)
  values (me, 'reward_refund', 0, c.price, w.free_points, w.points, me,
          format('claim #%s cancelled — %s', c.id, c.reward_name));

  return jsonb_build_object('claim_id', c.id, 'status', 'cancelled', 'points', w.points);
end $$;

-- ---------------------------------------------------------------- approve / reject
create or replace function slot.decide_claim(
  p_claim_id bigint, p_approve boolean, p_note text default null
) returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  me uuid := slot.current_user_id();
  c  slot.reward_claim%rowtype;
  w  slot.wallet%rowtype;
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;

  select * into c from slot.reward_claim where id = p_claim_id for update;
  if not found then
    raise exception 'no such claim' using errcode = 'no_data_found';
  end if;
  if c.status <> 'pending' then
    raise exception 'that claim was already %s', c.status using errcode = 'check_violation';
  end if;

  update slot.reward_claim
     set status = case when p_approve then 'approved' else 'rejected' end::slot.claim_status,
         decided_by = me, decided_at = now(), note = p_note
   where id = c.id;

  -- Approval moves nothing: the points left the Wallet when the claim was made.
  -- Rejection puts them back.
  if not p_approve then
    update slot.wallet
       set points = points + c.price, updated_at = now()
     where user_id = c.user_id
     returning * into w;

    insert into slot.ledger (user_id, reason, free_delta, points_delta,
                             free_after, points_after, actor_id, note)
    values (c.user_id, 'reward_refund', 0, c.price, w.free_points, w.points, me,
            format('claim #%s rejected — %s', c.id, c.reward_name));
  end if;

  return jsonb_build_object('claim_id', c.id,
    'status', case when p_approve then 'approved' else 'rejected' end);
end $$;

-- ---------------------------------------------------------------- catalogue editing
create or replace function slot.save_reward(
  p_id uuid, p_name text, p_price integer, p_sort_order integer default 0
) returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;
  if p_id is null then
    insert into slot.reward (name, price, sort_order)
    values (p_name, p_price, p_sort_order) returning id into v_id;
  else
    update slot.reward set name = p_name, price = p_price, sort_order = p_sort_order
     where id = p_id returning id into v_id;
    if v_id is null then
      raise exception 'no such prize' using errcode = 'no_data_found';
    end if;
  end if;
  return v_id;
end $$;

-- Retired, never deleted: past claims point at it and history must stay readable.
create or replace function slot.archive_reward(p_id uuid)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if not slot.is_admin() then
    raise exception 'admins only' using errcode = 'insufficient_privilege';
  end if;
  update slot.reward set is_active = false where id = p_id;
end $$;

-- ---------------------------------------------------------------- row-level security
alter table slot.reward       enable row level security;
alter table slot.reward_claim enable row level security;

drop policy if exists reward_read on slot.reward;
create policy reward_read on slot.reward for select
  using (slot.current_user_id() is not null);

-- Your own claims always; every claim if you are an admin; and anybody's successful
-- claim from the last six months, which is the public history the doc asks for.
drop policy if exists reward_claim_read on slot.reward_claim;
create policy reward_claim_read on slot.reward_claim for select
  using (
    user_id = slot.current_user_id()
    or slot.is_admin()
    or (status = 'approved' and created_at > now() - interval '6 months')
  );

-- No write policy on either table: only the definer functions above move claims,
-- exactly as with the wallet and the ledger.

-- ---------------------------------------------------------------- public API
create or replace view public.rewards
  with (security_invoker = true) as
  select id, name, price, sort_order, is_active from slot.reward;

create or replace view public.reward_claims
  with (security_invoker = true) as
  select c.id, c.user_id, u.email as claimed_by, u.display_name,
         c.reward_id, c.reward_name, c.price, c.status::text as status,
         c.created_at, c.decided_at, a.email as decided_by, c.note
    from slot.reward_claim c
    join slot.app_user u on u.id = c.user_id
    left join slot.app_user a on a.id = c.decided_by;

create or replace function public.claim_reward(p_reward_id uuid)
returns jsonb language sql volatile as $$ select slot.submit_claim(p_reward_id); $$;

create or replace function public.cancel_claim(p_claim_id bigint)
returns jsonb language sql volatile as $$ select slot.cancel_claim(p_claim_id); $$;

create or replace function public.decide_claim(
  p_claim_id bigint, p_approve boolean, p_note text default null
) returns jsonb language sql volatile as $$
  select slot.decide_claim(p_claim_id, p_approve, p_note);
$$;

create or replace function public.save_reward(
  p_id uuid, p_name text, p_price integer, p_sort_order integer default 0
) returns uuid language sql volatile as $$
  select slot.save_reward(p_id, p_name, p_price, p_sort_order);
$$;

create or replace function public.archive_reward(p_id uuid)
returns void language sql volatile as $$ select slot.archive_reward(p_id); $$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on slot.reward, slot.reward_claim to authenticated;
    grant select on public.rewards, public.reward_claims to authenticated;
    grant execute on function
      public.claim_reward(uuid),
      public.cancel_claim(bigint),
      public.decide_claim(bigint, boolean, text),
      public.save_reward(uuid, text, integer, integer),
      public.archive_reward(uuid)
    to authenticated;
    revoke execute on function
      public.claim_reward(uuid),
      public.cancel_claim(bigint),
      public.decide_claim(bigint, boolean, text)
    from anon;
  end if;
end $$;

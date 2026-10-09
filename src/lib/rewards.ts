import { supabase } from './supabase';

export interface RewardRow {
  id: string;
  name: string;
  price: number;
  sort_order: number;
  is_active: boolean;
}

export type ClaimStatus = 'pending' | 'approved' | 'rejected' | 'cancelled';

export interface ClaimRow {
  id: number;
  user_id: string;
  claimed_by: string;          // email
  display_name: string | null;
  reward_id: string;
  /** Snapshotted at claim time — a later price change must not rewrite history. */
  reward_name: string;
  price: number;
  status: ClaimStatus;
  created_at: string;
  decided_at: string | null;
  decided_by: string | null;   // email of the admin
  note: string | null;
  /** The normal price when a sale price was paid (0029); null otherwise. */
  list_price?: number | null;
}

function client() {
  if (!supabase) throw new Error('The site is not connected to its database.');
  return supabase;
}

export async function fetchRewards(): Promise<RewardRow[]> {
  const { data, error } = await client()
    .from('rewards').select('*').order('sort_order').order('price');
  if (error) throw new Error(error.message);
  return (data ?? []) as RewardRow[];
}

/** Row-level security decides what comes back: your own claims, anybody's approved
 *  claim from the last six months, and everything if you are an admin. */
export async function fetchClaims(): Promise<ClaimRow[]> {
  const { data, error } = await client()
    .from('reward_claims').select('*').order('created_at', { ascending: false });
  if (error) throw new Error(error.message);
  return (data ?? []) as ClaimRow[];
}

/** expectedPrice: the price the page showed. If a sale started or ended in the
 *  meantime the claim is refused with the new price, rather than charging a
 *  different amount than the player saw. */
export async function claimReward(rewardId: string, expectedPrice?: number) {
  const { data, error } = await client().rpc('claim_reward', {
    p_reward_id: rewardId, p_expected_price: expectedPrice ?? null,
  });
  if (error) throw new Error(error.message);
  return data as { claim_id: number; reward: string; price: number; points: number };
}

export async function cancelClaim(claimId: number) {
  const { error } = await client().rpc('cancel_claim', { p_claim_id: claimId });
  if (error) throw new Error(error.message);
}

export async function decideClaim(claimId: number, approve: boolean, note?: string) {
  const { error } = await client().rpc('decide_claim', {
    p_claim_id: claimId, p_approve: approve, p_note: note ?? null,
  });
  if (error) throw new Error(error.message);
}

export async function saveReward(input: {
  id: string | null; name: string; price: number; sort_order: number;
}) {
  const { data, error } = await client().rpc('save_reward', {
    p_id: input.id, p_name: input.name, p_price: input.price,
    p_sort_order: input.sort_order,
  });
  if (error) throw new Error(error.message);
  return data as string;
}

export async function archiveReward(id: string) {
  const { error } = await client().rpc('archive_reward', { p_id: id });
  if (error) throw new Error(error.message);
}

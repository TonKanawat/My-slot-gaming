import { supabase } from './supabase';
import type { SymbolRow } from './admin';

export interface Readiness {
  ready: boolean;
  missing: string[];
  symbols: number;
  groups: number;
  wilds: number;
  scatters: number;
}

export interface WinningLine {
  payline: number;
  family: string;
  combination: string;
  bonus: number;
}

/** Exactly what public.play() hands back. The grid is authoritative: the browser
 *  renders it, it does not generate it. */
export interface SpinResult {
  grid: string[][];
  lines: WinningLine[];
  line_count: number;
  normal_lines: number;
  base: number;
  multiplier: number;
  payout: number;
  /** The payout before any promotion (0029). */
  base_payout?: number;
  /** The slot promotion that boosted this win, if one was running. */
  promo?: { id: string; name: string; extra: number; bonus: number; base_payout: number } | null;
  bet: number;
  was_free_spin: boolean;
  paid_from_free: number;
  paid_from_wallet: number;
  free_points: number;
  points: number;
  free_spins: number;
  /** Before the per-spin cap. */
  free_spins_raw?: number;
  /** Scatters that sat on a winning line and so paid (0027). */
  scatters_paid?: { row: number; col: number; symbol: string; name: string; spins: number }[];
  /** Scatters that landed off every winning line and paid nothing. */
  scatters_missed?: number;
  free_spins_left: number;
  free_spin_round: number;
  chain_ended: boolean;
  yellow_card: boolean;
  ban_bets_left: number;
}

export interface Wallet { free_points: number; points: number; }

/** What the server still owes this player. Held server-side, so it survives a
 *  refresh, a tab switch, or playing on from another device. */
export interface FreeSpins {
  remaining: number;
  round: number;
  rounds_max: number;
  stake: number | null;
  ban_bets_left: number;
}

export const NO_FREE_SPINS: FreeSpins = {
  remaining: 0, round: 0, rounds_max: 3, stake: null, ban_bets_left: 0,
};

function client() {
  if (!supabase) throw new Error('The site is not connected to its database.');
  return supabase;
}

export async function fetchReadiness(): Promise<Readiness> {
  const { data, error } = await client().rpc('game_ready');
  if (error) throw new Error(error.message);
  return data as Readiness;
}

export async function fetchWallet(): Promise<Wallet> {
  const { data, error } = await client().rpc('my_wallet');
  if (error) throw new Error(error.message);
  return (data as Wallet[])?.[0] ?? { free_points: 0, points: 0 };
}

/** The reel symbols, so the board can draw the admin's uploaded artwork. */
export async function fetchActiveSymbols(): Promise<SymbolRow[]> {
  const { data, error } = await client()
    .from('game_symbols').select('*').eq('is_active', true).order('name');
  if (error) throw new Error(error.message);
  return data as SymbolRow[];
}

/** The only way to spin. Grid, win and wallet are all decided server-side. */
export async function play(bet: number): Promise<SpinResult> {
  const { data, error } = await client().rpc('play', { p_bet: bet });
  if (error) throw new Error(error.message);
  return data as SpinResult;
}

/** Asked on load, so a refresh cannot appear to swallow a free-spin chain. */
export async function fetchFreeSpins(): Promise<FreeSpins> {
  const { data, error } = await client().rpc('my_free_spins');
  if (error) throw new Error(error.message);
  return (data as FreeSpins[])?.[0] ?? NO_FREE_SPINS;
}

export interface LineExplanation {
  payline: number;
  family: string;
  symbols: string;
  won: boolean;
  group: string | null;
  /** Wilds standing in on this line — the usual reason a win looks wrong. */
  wilds: number;
  wild_names: string | null;
  reason: string | null;
}

/** Why each payline did or did not win, for the grid just played. */
export async function explainGrid(grid: string[][]): Promise<LineExplanation[]> {
  const { data, error } = await client().rpc('explain_grid', { p_grid: grid });
  if (error) throw new Error(error.message);
  return data as LineExplanation[];
}

/** Winning-group names by id, archived groups included: a spin reports the group
 *  it matched by id, and the result panel needs to say which group that was. */
export async function fetchCombinationNames(): Promise<Map<string, string>> {
  const { data, error } = await client().from('winning_combinations').select('id, name');
  if (error) throw new Error(error.message);
  return new Map(((data ?? []) as { id: string; name: string }[]).map((c) => [c.id, c.name]));
}

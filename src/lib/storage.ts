import { supabase } from './supabase';

export interface PruneReport {
  at: string;
  cutoff: string;
  history_days: number;
  spins_deleted: number;
  ledger_rows_rolled_up: number;
  summary_rows_written: number;
  cron_rows_deleted: number;
}

export interface StorageReport {
  database_bytes: number;
  limit_bytes: number;
  warn_bytes: number;
  spin_log_bytes: number;
  spin_log_rows: number;
  ledger_bytes: number;
  ledger_rows: number;
  oldest_spin: string | null;
  history_days: number;
  last_prune: PruneReport | null;
}

function client() {
  if (!supabase) throw new Error('The site is not connected to its database.');
  return supabase;
}

export async function fetchStorage(): Promise<StorageReport> {
  const { data, error } = await client().rpc('storage_report');
  if (error) throw new Error(error.message);
  return data as StorageReport;
}

export async function saveHistoryDays(days: number) {
  const { error } = await client().rpc('save_history_days', { p_days: days });
  if (error) throw new Error(error.message);
}

export async function pruneNow(): Promise<PruneReport> {
  const { data, error } = await client().rpc('prune_history_now');
  if (error) throw new Error(error.message);
  return data as PruneReport;
}

export function mb(bytes: number) {
  return `${(bytes / 1024 / 1024).toFixed(bytes < 10 * 1024 * 1024 ? 1 : 0)} MB`;
}

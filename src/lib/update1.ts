import { supabase } from './supabase';

function client() {
  if (!supabase) throw new Error('The site is not connected to its database.');
  return supabase;
}

// ---------------------------------------------------------------- display name
export async function saveDisplayName(name: string): Promise<string> {
  const { data, error } = await client().rpc('set_display_name', { p_name: name });
  if (error) throw new Error(error.message);
  return (data as { display_name: string }).display_name;
}

// ---------------------------------------------------------------- ranking
export interface RankRow {
  rank: number;
  user_id: string;
  name: string;
  points: number;
  is_me: boolean;
}

export async function fetchRanking(): Promise<RankRow[]> {
  const { data, error } = await client().rpc('ranking');
  if (error) throw new Error(error.message);
  return (data ?? []) as RankRow[];
}

// ---------------------------------------------------------------- free-point schedule
/** Monday first, Sunday last — the same order as the database setting. */
export const WEEKDAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

export interface GrantSchedule {
  days: number[];
  ceiling_on: boolean;
  ceiling: number;
  time: string;
  timezone: string;
  next: { date: string; amount: number } | null;
  last_run: { day: string; at: string; amount: number; people: number } | null;
}

export async function fetchGrantSchedule(): Promise<GrantSchedule> {
  const { data, error } = await client().rpc('grant_schedule');
  if (error) throw new Error(error.message);
  return data as GrantSchedule;
}

export async function saveGrantSchedule(days: number[], ceilingOn: boolean, ceiling: number) {
  const { data, error } = await client().rpc('save_grant_schedule', {
    p_days: days, p_ceiling_on: ceilingOn, p_ceiling: ceiling,
  });
  if (error) throw new Error(error.message);
  return data as GrantSchedule;
}

/** "Mon 5 Oct" for a yyyy-mm-dd date, read as a calendar day (no time zone shift). */
export function shortDay(iso: string) {
  const [y, m, d] = iso.split('-').map(Number);
  return new Date(y, m - 1, d).toLocaleDateString(undefined,
    { weekday: 'short', day: 'numeric', month: 'short' });
}

/** "Fri" for a yyyy-mm-dd date. */
export function weekday(iso: string) {
  const [y, m, d] = iso.split('-').map(Number);
  return new Date(y, m - 1, d).toLocaleDateString(undefined, { weekday: 'short' });
}

// ---------------------------------------------------------------- point requests
export type RequestStatus = 'pending' | 'approved' | 'rejected' | 'cancelled' | 'expired';

export interface PointRequest {
  id: number;
  requested_by: string;
  requester: string;
  requester_email: string;
  target_id: string;
  target: string;
  target_email: string;
  is_self: boolean;
  amount: number;
  note: string | null;
  status: RequestStatus;
  created_at: string;
  expires_at: string;
  hours_left: number | null;
  /** The website version of the 48 / 24 / 12-hour reminders. */
  reminder: '48h' | '24h' | '12h' | null;
  decided_at: string | null;
  decided_by: string | null;
  decision_note: string | null;
}

export interface RequestTarget { id: string; email: string; name: string; is_self: boolean; }

export async function fetchRequestTargets(): Promise<RequestTarget[]> {
  const { data, error } = await client().rpc('request_targets');
  if (error) throw new Error(error.message);
  return (data ?? []) as RequestTarget[];
}

export async function fetchPointRequests(): Promise<PointRequest[]> {
  const { data, error } = await client().rpc('point_requests');
  if (error) throw new Error(error.message);
  return ((data ?? []) as PointRequest[]).map((r) => ({
    ...r, hours_left: r.hours_left === null ? null : Number(r.hours_left),
  }));
}

export async function requestPoints(target: string, amount: number, note: string) {
  const { data, error } = await client().rpc('request_points', {
    p_target: target, p_amount: amount, p_note: note || null,
  });
  if (error) throw new Error(error.message);
  return data as { request_id: number; expires_at: string };
}

export async function cancelPointRequest(id: number) {
  const { error } = await client().rpc('cancel_point_request', { p_id: id });
  if (error) throw new Error(error.message);
}

export async function decidePointRequest(id: number, approve: boolean, note?: string) {
  const { error } = await client().rpc('decide_point_request', {
    p_id: id, p_approve: approve, p_note: note || null,
  });
  if (error) throw new Error(error.message);
}

export function timeLeft(hours: number | null) {
  if (hours === null) return '';
  if (hours < 1) return 'under an hour left';
  if (hours < 48) return `${Math.floor(hours)} h left`;
  return `${Math.floor(hours / 24)} d ${Math.floor(hours % 24)} h left`;
}

export function when(iso: string) {
  return new Date(iso).toLocaleString(undefined,
    { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
}

export const REQUEST_STATUS: Record<RequestStatus, string> = {
  pending: 'Waiting for the admin',
  approved: 'Approved',
  rejected: 'Declined',
  cancelled: 'Cancelled',
  expired: 'Expired — not decided in time',
};

/** Page numbers with gaps: 1 … 4 5 6 … 12. */
export function pageNumbers(page: number, pages: number): (number | 'gap')[] {
  if (pages <= 7) return Array.from({ length: pages }, (_, i) => i + 1);
  const out: (number | 'gap')[] = [1];
  const from = Math.max(2, page - 1);
  const to = Math.min(pages - 1, page + 1);
  if (from > 2) out.push('gap');
  for (let n = from; n <= to; n++) out.push(n);
  if (to < pages - 1) out.push('gap');
  out.push(pages);
  return out;
}

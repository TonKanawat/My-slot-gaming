import { supabase } from './supabase';

function client() {
  if (!supabase) throw new Error('The site is not connected to its database.');
  return supabase;
}

export type PromoKind = 'slot_boost' | 'reward_discount';
export type PromoStatus = 'running' | 'between' | 'upcoming' | 'ended';

export interface Promotion {
  id: string;
  name: string;
  kind: PromoKind;
  /** running = on right now; between = inside its dates but outside its hours. */
  status: PromoStatus;
  start_date: string;
  end_date: string;
  extra: number | null;
  /** ISO weekdays, 1 = Monday. Null = every day. */
  weekdays: number[] | null;
  start_time: string | null;   // "16:00:00"
  end_time: string | null;
  reward_id: string | null;
  reward_name: string | null;
  list_price: number | null;
  sale_price: number | null;
  discount_pct: number | null;
  live_now: boolean;
  next_start: string | null;
  live_until: string | null;
  dismissed: boolean;
  is_active: boolean;
  created_at: string;
}

export async function fetchPromotions(all = false): Promise<Promotion[]> {
  const { data, error } = await client().rpc('promotions', { p_all: all });
  if (error) throw new Error(error.message);
  return ((data ?? []) as Promotion[]).map((p) => ({
    ...p, extra: p.extra === null ? null : Number(p.extra),
  }));
}

export async function dismissPromotions(ids: string[]) {
  const { error } = await client().rpc('dismiss_promotions', { p_ids: ids });
  if (error) throw new Error(error.message);
}

export interface PromoInput {
  id?: string | null;
  name: string;
  kind: PromoKind;
  start_date: string;
  end_date: string;
  extra?: number | null;
  weekdays?: number[] | null;
  start_time?: string | null;
  end_time?: string | null;
  reward_id?: string | null;
  discount_pct?: number | null;
}

export async function savePromotion(p: PromoInput): Promise<string> {
  const { data, error } = await client().rpc('save_promotion', {
    p_id: p.id ?? null,
    p_name: p.name,
    p_kind: p.kind,
    p_start_date: p.start_date,
    p_end_date: p.end_date,
    p_extra: p.kind === 'slot_boost' ? p.extra ?? null : null,
    p_weekdays: p.kind === 'slot_boost' ? p.weekdays ?? null : null,
    p_start_time: p.kind === 'slot_boost' ? p.start_time ?? null : null,
    p_end_time: p.kind === 'slot_boost' ? p.end_time ?? null : null,
    p_reward_id: p.kind === 'reward_discount' ? p.reward_id ?? null : null,
    p_discount_pct: p.kind === 'reward_discount' ? p.discount_pct ?? null : null,
  });
  if (error) throw new Error(error.message);
  return data as string;
}

export async function endPromotion(id: string) {
  const { error } = await client().rpc('end_promotion', { p_id: id });
  if (error) throw new Error(error.message);
}

export interface RewardPrice {
  reward_id: string;
  list_price: number;
  price: number;
  discount_pct: number | null;
  promotion_name: string | null;
  sale_ends: string | null;
}

export async function fetchRewardPrices(): Promise<Map<string, RewardPrice>> {
  const { data, error } = await client().rpc('reward_prices');
  if (error) throw new Error(error.message);
  return new Map(((data ?? []) as RewardPrice[]).map((r) => [r.reward_id, r]));
}

// ---------------------------------------------------------------- wording
const DAY = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const DAY_LONG = ['', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/** "16:00:00" -> "16:00" */
export const hhmm = (t: string | null) => (t ? t.slice(0, 5) : '');

/** A calendar date (yyyy-mm-dd) as "Mon 19 Oct", with no time-zone shift. */
export function day(iso: string, year = false) {
  const [y, m, d] = iso.split('-').map(Number);
  return new Date(y, m - 1, d).toLocaleDateString('en-GB',
    { weekday: 'short', day: 'numeric', month: 'short', ...(year ? { year: 'numeric' } : {}) })
    .replace(',', '');
}

/** The Bangkok calendar date (yyyy-mm-dd) of a moment. */
export const bkkDate = (iso: string) =>
  new Date(iso).toLocaleDateString('en-CA', { timeZone: 'Asia/Bangkok' });

/** A moment, shown in Bangkok time: "Mon 19 Oct, 16:00". */
export function moment(iso: string) {
  const t = new Date(iso).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Bangkok' });
  return `${day(bkkDate(iso))}, ${t}`;
}

/** Only the time if it is today in Bangkok, otherwise the day as well. */
export function untilText(iso: string) {
  const t = new Date(iso).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Bangkok' });
  const end = t === '23:59' ? 'midnight' : t;
  return bkkDate(iso) === bkkDate(new Date().toISOString()) ? `${end} today` : `${day(bkkDate(iso))}, ${end}`;
}

export function daysText(w: number[] | null) {
  if (!w || w.length === 0 || w.length === 7) return 'every day';
  if (w.length === 5 && [1, 2, 3, 4, 5].every((d) => w.includes(d))) return 'weekdays';
  if (w.length === 2 && w.includes(6) && w.includes(7)) return 'weekends';
  if (w.length === 1) return `every ${DAY_LONG[w[0]]}`;
  return w.map((d) => DAY[d]).join(', ');
}

/** "x1.5 extra on every win" */
export function boostText(extra: number) {
  return `x${Number(extra).toLocaleString(undefined, { maximumFractionDigits: 2 })} extra on every win`;
}

/** "every Monday 16:00–17:00, 19 Oct – 1 Nov" */
export function scheduleText(p: Promotion) {
  if (p.kind === 'reward_discount') {
    return p.start_date === p.end_date ? day(p.start_date) : `${day(p.start_date)} – ${day(p.end_date)}`;
  }
  const hours = p.start_time ? ` ${hhmm(p.start_time)}–${hhmm(p.end_time)}` : ', all day';
  const range = p.start_date === p.end_date ? day(p.start_date) : `${day(p.start_date)} – ${day(p.end_date)}`;
  return `${daysText(p.weekdays)}${hours} · ${range}`;
}

/** What the promotion gives, in a few words. */
export function offerText(p: Promotion) {
  if (p.kind === 'slot_boost') return boostText(p.extra ?? 0);
  return `${p.reward_name} ${p.discount_pct}% off — ${(p.sale_price ?? 0).toLocaleString()} instead of ${(p.list_price ?? 0).toLocaleString()} points`;
}

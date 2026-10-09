import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  endPromotion, fetchPromotions, hhmm, offerText, savePromotion, scheduleText,
  type PromoInput, type PromoKind, type Promotion,
} from '../../lib/promotions';
import { fetchRewards, type RewardRow } from '../../lib/rewards';

const WEEK = [
  { d: 1, label: 'Mon' }, { d: 2, label: 'Tue' }, { d: 3, label: 'Wed' }, { d: 4, label: 'Thu' },
  { d: 5, label: 'Fri' }, { d: 6, label: 'Sat' }, { d: 7, label: 'Sun' },
];

const STATUS: Record<string, string> = {
  running: 'On now', between: 'Between sessions', upcoming: 'Coming up', ended: 'Ended',
};

/** Today in Bangkok as yyyy-mm-dd, for date inputs. */
const todayBkk = () => new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Bangkok' });

interface Draft {
  id: string | null;
  kind: PromoKind;
  name: string;
  start_date: string;
  end_date: string;
  extra: string;
  weekdays: number[];          // empty = every day
  allDay: boolean;
  start_time: string;
  end_time: string;
  reward_id: string;
  discount_pct: string;
}

const blank = (kind: PromoKind = 'slot_boost'): Draft => ({
  id: null, kind, name: '', start_date: todayBkk(), end_date: todayBkk(),
  extra: '1', weekdays: [], allDay: true, start_time: '16:00', end_time: '17:00',
  reward_id: '', discount_pct: '20',
});

/** Back office: promotions. A slot boost adds an extra multiplier on top of every
 *  win in its hours; a reward discount takes a percentage off one prize for whole
 *  days. Times are Bangkok time. */
export function PromotionsTab() {
  const [list, setList] = useState<Promotion[]>([]);
  const [rewards, setRewards] = useState<RewardRow[]>([]);
  const [draft, setDraft] = useState<Draft>(blank());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const [p, r] = await Promise.all([fetchPromotions(true), fetchRewards()]);
      setList(p);
      setRewards(r.filter((x) => x.is_active));
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not load the promotions.');
    }
  }, []);
  useEffect(() => { void load(); }, [load]);

  const set = <K extends keyof Draft>(k: K, v: Draft[K]) => setDraft((d) => ({ ...d, [k]: v }));

  function edit(p: Promotion) {
    setNotice(null); setError(null);
    setDraft({
      id: p.id, kind: p.kind, name: p.name, start_date: p.start_date, end_date: p.end_date,
      extra: String(p.extra ?? 1), weekdays: p.weekdays ?? [], allDay: !p.start_time,
      start_time: hhmm(p.start_time) || '16:00', end_time: hhmm(p.end_time) || '17:00',
      reward_id: p.reward_id ?? '', discount_pct: String(p.discount_pct ?? 20),
    });
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  const extra = Number(draft.extra);
  const pct = Number(draft.discount_pct);
  const reward = rewards.find((r) => r.id === draft.reward_id);
  const problems = useMemo(() => {
    const out: string[] = [];
    if (draft.name.trim().length < 2) out.push('a name');
    if (!draft.start_date || !draft.end_date || draft.end_date < draft.start_date) out.push('an end date on or after the start');
    if (draft.kind === 'slot_boost') {
      if (!(extra > 0 && extra <= 10)) out.push('an extra multiplier between 0.01 and 10');
      if (!draft.allDay && !(draft.start_time < draft.end_time)) out.push('an end time after the start time');
    } else {
      if (!reward) out.push('a prize');
      if (!(Number.isInteger(pct) && pct >= 1 && pct <= 99)) out.push('a discount of 1–99%');
    }
    return out;
  }, [draft, extra, pct, reward]);

  async function save(e: React.FormEvent) {
    e.preventDefault();
    if (problems.length) return;
    setBusy(true); setError(null); setNotice(null);
    const input: PromoInput = {
      id: draft.id, name: draft.name.trim(), kind: draft.kind,
      start_date: draft.start_date, end_date: draft.end_date,
      extra, weekdays: draft.weekdays.length ? draft.weekdays : null,
      start_time: draft.allDay ? null : draft.start_time,
      end_time: draft.allDay ? null : draft.end_time,
      reward_id: draft.reward_id || null, discount_pct: pct,
    };
    try {
      await savePromotion(input);
      setNotice(draft.id ? `“${input.name}” updated.` : `“${input.name}” created. Players will see it on the home page.`);
      setDraft(blank(draft.kind));
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not save the promotion.');
    } finally { setBusy(false); }
  }

  async function end(p: Promotion) {
    if (!window.confirm(`End “${p.name}” now? It stops at once for everyone.`)) return;
    setBusy(true); setError(null); setNotice(null);
    try {
      await endPromotion(p.id);
      setNotice(`“${p.name}” has ended.`);
      if (draft.id === p.id) setDraft(blank(draft.kind));
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not end the promotion.');
    } finally { setBusy(false); }
  }

  const sample = 21;
  const groups = [
    { title: 'On now', rows: list.filter((p) => p.is_active && p.status === 'running') },
    { title: 'Coming up', rows: list.filter((p) => p.is_active && (p.status === 'upcoming' || p.status === 'between')) },
    { title: 'Ended', rows: list.filter((p) => !p.is_active || p.status === 'ended').slice(0, 20) },
  ];

  return (
    <div className="admin-pane stack">
      <form className="card form promo-form" onSubmit={save}>
        <h3>
          {draft.id ? 'Edit promotion' : 'New promotion'}
          {draft.id && <button type="button" className="linkish" onClick={() => setDraft(blank())}>Start a new one instead</button>}
        </h3>

        <div className="kind-switch" role="radiogroup" aria-label="Promotion type">
          <button type="button" role="radio" aria-checked={draft.kind === 'slot_boost'}
                  data-on={draft.kind === 'slot_boost' ? 'true' : undefined}
                  onClick={() => set('kind', 'slot_boost')}>
            <b>Slot boost</b><small>extra multiplier on every win</small>
          </button>
          <button type="button" role="radio" aria-checked={draft.kind === 'reward_discount'}
                  data-on={draft.kind === 'reward_discount' ? 'true' : undefined}
                  onClick={() => set('kind', 'reward_discount')}>
            <b>Reward discount</b><small>% off one prize</small>
          </button>
        </div>

        <label className="field">
          <span>Name</span>
          <input value={draft.name} maxLength={60} onChange={(e) => set('name', e.target.value)}
                 placeholder={draft.kind === 'slot_boost' ? 'e.g. Monday Happy Hour' : 'e.g. Gold Rush Week'} />
        </label>

        <div className="row2">
          <label className="field">
            <span>Start date</span>
            <input type="date" value={draft.start_date} onChange={(e) => set('start_date', e.target.value)} />
          </label>
          <label className="field">
            <span>End date (included)</span>
            <input type="date" value={draft.end_date} min={draft.start_date}
                   onChange={(e) => set('end_date', e.target.value)} />
          </label>
        </div>

        {draft.kind === 'slot_boost' ? (
          <>
            <label className="field">
              <span>Extra multiplier</span>
              <input type="number" min={0.05} max={10} step={0.05} value={draft.extra}
                     onChange={(e) => set('extra', e.target.value)} />
            </label>
            <p className="hint">
              Added on top of the normal win, after the x6 cap. A win of {sample} points at
              x{extra > 0 ? extra : '…'} pays {sample} + {extra > 0 ? Math.round(sample * extra) : '…'}
              {' '}= <b>{extra > 0 ? sample + Math.round(sample * extra) : '…'} points</b>. Free spins too.
              If two boosts overlap, only the bigger one counts.
            </p>

            <fieldset className="field daypick">
              <legend>Days</legend>
              <div className="daychips">
                {WEEK.map(({ d, label }) => {
                  const on = draft.weekdays.includes(d);
                  return (
                    <button type="button" key={d} className="daychip" aria-pressed={on}
                            data-on={on ? 'true' : undefined}
                            onClick={() => set('weekdays', on
                              ? draft.weekdays.filter((x) => x !== d)
                              : [...draft.weekdays, d].sort())}>
                      {label}
                    </button>
                  );
                })}
              </div>
              <p className="hint">
                {draft.weekdays.length === 0 || draft.weekdays.length === 7
                  ? 'No day picked = every day between the dates.' : 'Only on the picked days, between the dates.'}
              </p>
            </fieldset>

            <label className="checkline">
              <input type="checkbox" checked={draft.allDay} onChange={(e) => set('allDay', e.target.checked)} />
              <span>All day</span>
            </label>
            {!draft.allDay && (
              <div className="row2">
                <label className="field">
                  <span>From (Bangkok time)</span>
                  <input type="time" value={draft.start_time} onChange={(e) => set('start_time', e.target.value)} />
                </label>
                <label className="field">
                  <span>Until</span>
                  <input type="time" value={draft.end_time} onChange={(e) => set('end_time', e.target.value)} />
                </label>
              </div>
            )}
          </>
        ) : (
          <>
            <div className="row2">
              <label className="field">
                <span>Prize</span>
                <select value={draft.reward_id} onChange={(e) => set('reward_id', e.target.value)}>
                  <option value="">Choose a prize…</option>
                  {rewards.map((r) => (
                    <option key={r.id} value={r.id}>{r.name} — {r.price.toLocaleString()} points</option>
                  ))}
                </select>
              </label>
              <label className="field">
                <span>Discount (%)</span>
                <input type="number" min={1} max={99} step={1} value={draft.discount_pct}
                       onChange={(e) => set('discount_pct', e.target.value)} />
              </label>
            </div>
            {reward && pct >= 1 && pct <= 99 && (
              <p className="hint">
                {reward.name}: <s>{reward.price.toLocaleString()}</s> →{' '}
                <b>{Math.max(1, Math.round(reward.price * (100 - pct) / 100)).toLocaleString()} points</b>,
                whole days from the start date to the end date (Bangkok time).
              </p>
            )}
          </>
        )}

        {error && <p className="auth-error" role="alert">{error}</p>}
        {notice && <p className="auth-notice" role="status">{notice}</p>}

        <div className="form-actions">
          <button className="spin" disabled={busy || problems.length > 0}>
            {busy ? 'Saving…' : draft.id ? 'Save changes' : 'Create promotion'}
          </button>
          {problems.length > 0 && <span className="hint">Still needed: {problems.join(', ')}.</span>}
        </div>
      </form>

      {groups.map((g) => (
        <div className="card" key={g.title}>
          <h3>{g.title} <span className="count">{g.rows.length}</span></h3>
          {g.rows.length === 0 ? <p className="empty">None.</p> : (
            <ul className="claim-list">
              {g.rows.map((p) => (
                <li className="claim promo-row" key={p.id} data-live={p.live_now ? 'true' : undefined}>
                  <div>
                    <b>{p.name}</b>
                    <span className={`tag ${p.kind === 'slot_boost' ? 'bonus' : 'rule'}`}>
                      {p.kind === 'slot_boost' ? 'slot boost' : 'reward discount'}
                    </span>
                    {p.is_active && p.status !== 'ended' && <span className="status-pill" data-status={p.live_now ? 'approved' : undefined}>{STATUS[p.status]}</span>}
                    <span className="claim-meta">{offerText(p)}</span>
                    <span className="claim-meta">{scheduleText(p)}</span>
                  </div>
                  {p.is_active && p.status !== 'ended' && (
                    <div className="claim-actions">
                      <button className="linkish" disabled={busy} onClick={() => edit(p)}>Edit</button>
                      <button className="linkish danger" disabled={busy} onClick={() => end(p)}>End now</button>
                    </div>
                  )}
                </li>
              ))}
            </ul>
          )}
        </div>
      ))}
    </div>
  );
}

import { useState } from 'react';
import {
  bkkDate, day, moment, offerText, scheduleText, untilText, type Promotion,
} from '../lib/promotions';

/** One line about one promotion: "starts on …" before it runs, "will end …" while
 *  it does. */
function Sentence({ p }: { p: Promotion }) {
  if (p.live_now) {
    // A promotion with no hours and no weekdays runs straight through to its last
    // day; anything with hours or weekdays ends this session at live_until.
    const continuous = !p.start_time && !p.weekdays;
    const ends = continuous || !p.live_until ? day(p.end_date) : untilText(p.live_until);
    return (
      <>
        The promotion <b>{p.name}</b> will end <b>{ends}</b>
        <span className="promo-offer"> — {offerText(p)}</span>
      </>
    );
  }
  // With hours, say the day and time; a whole-day promotion just needs the day.
  const starts = !p.next_start ? day(p.start_date)
    : p.start_time ? moment(p.next_start) : day(bkkDate(p.next_start));
  return (
    <>
      {p.status === 'between' ? <>The promotion <b>{p.name}</b> is back on</> : <>New promotion <b>{p.name}</b> will start on</>}
      {' '}<b>{starts}</b>
      <span className="promo-offer"> — {offerText(p)}</span>
    </>
  );
}

/** The home-page label. One promotion gets one sentence; several are summed up in
 *  one label. Closing hides it until the next visit to this page; "never show
 *  again" is remembered for good, per promotion, on every device. */
export function PromoBanner({ promos, onDismiss }: {
  promos: Promotion[];
  onDismiss: (ids: string[]) => Promise<void> | void;
}) {
  const [closed, setClosed] = useState(false);
  const [busy, setBusy] = useState(false);
  const shown = promos.filter((p) => !p.dismissed && p.status !== 'ended');
  if (closed || shown.length === 0) return null;

  const hide = async (ids: string[]) => {
    setBusy(true);
    try { await onDismiss(ids); } finally { setBusy(false); }
  };
  const anyLive = shown.some((p) => p.live_now);

  return (
    <section className="promo-banner" data-live={anyLive ? 'true' : undefined} aria-label="Promotions">
      <span className="promo-icon" aria-hidden="true">{anyLive ? '🔥' : '🎉'}</span>

      <div className="promo-body">
        {shown.length === 1 ? (
          <>
            <p className="promo-line"><Sentence p={shown[0]} /></p>
            <p className="promo-when">{scheduleText(shown[0])}</p>
          </>
        ) : (
          <>
            <p className="promo-title">{shown.length} promotions for you</p>
            <ul className="promo-list">
              {shown.map((p) => (
                <li key={p.id} data-live={p.live_now ? 'true' : undefined}>
                  <span className="promo-line"><Sentence p={p} /></span>
                  <span className="promo-when">{scheduleText(p)}</span>
                  <button className="linkish promo-never" disabled={busy}
                          onClick={() => hide([p.id])}>Don't show this again</button>
                </li>
              ))}
            </ul>
          </>
        )}
        <div className="promo-actions">
          <button className="linkish promo-never" disabled={busy}
                  onClick={() => hide(shown.map((p) => p.id))}>
            {shown.length === 1 ? 'Never show this again' : 'Never show these again'}
          </button>
        </div>
      </div>

      <button className="promo-close" onClick={() => setClosed(true)} aria-label="Close for now"
              title="Close for now">×</button>
    </section>
  );
}

/** The small chip beside Spin while a boost is running. */
export function LiveBoostChip({ promos }: { promos: Promotion[] }) {
  const live = promos
    .filter((p) => p.kind === 'slot_boost' && p.live_now)
    .sort((a, b) => (b.extra ?? 0) - (a.extra ?? 0))[0];
  if (!live) return null;
  const continuous = !live.start_time && !live.weekdays;
  return (
    <div className="boost-chip" title={`${live.name}: every win pays its normal points plus x${live.extra} more`}>
      <span className="boost-flame" aria-hidden="true">🔥</span>
      <span>
        <b>x{Number(live.extra).toLocaleString(undefined, { maximumFractionDigits: 2 })} extra</b>
        <small>{live.name} · until {continuous || !live.live_until ? day(live.end_date) : untilText(live.live_until)}</small>
      </span>
    </div>
  );
}

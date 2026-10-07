import { useCallback, useEffect, useState } from 'react';
import {
  decidePointRequest, fetchGrantSchedule, fetchPointRequests, saveGrantSchedule, shortDay,
  REQUEST_STATUS, timeLeft, when, WEEKDAYS, type GrantSchedule, type PointRequest,
} from '../../lib/update1';

/** The automatic grant and the line managers' requests, side by side: both are
 *  ways free points arrive, and the admin decides both. */
export function FreePointsTab({ onPendingChange }: { onPendingChange?: (n: number) => void }) {
  const [schedule, setSchedule] = useState<GrantSchedule | null>(null);
  const [days, setDays] = useState<number[]>([0, 0, 0, 0, 0, 0, 0]);
  const [ceilingOn, setCeilingOn] = useState(true);
  const [ceiling, setCeiling] = useState(1000);
  const [requests, setRequests] = useState<PointRequest[]>([]);
  const [notes, setNotes] = useState<Record<number, string>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const [s, r] = await Promise.all([fetchGrantSchedule(), fetchPointRequests()]);
      setSchedule(s);
      setDays(s.days.map(Number));
      setCeilingOn(s.ceiling_on);
      setCeiling(s.ceiling);
      setRequests(r);
      onPendingChange?.(r.filter((x) => x.status === 'pending').length);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not load the free-point settings.');
    }
  }, [onPendingChange]);

  useEffect(() => { void load(); }, [load]);

  const dirty = schedule !== null && (
    days.some((d, i) => d !== Number(schedule.days[i]))
    || ceilingOn !== schedule.ceiling_on || ceiling !== schedule.ceiling);
  const daysValid = days.every((d) => Number.isInteger(d) && d >= 0 && d <= 100000);
  const ceilingValid = Number.isInteger(ceiling) && ceiling >= 1;

  async function save() {
    setBusy('save'); setError(null); setNotice(null);
    try {
      const s = await saveGrantSchedule(days, ceilingOn, ceiling);
      setSchedule(s);
      setNotice('Schedule saved. It applies from the next grant.');
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save the schedule.');
    } finally { setBusy(null); }
  }

  async function decide(r: PointRequest, approve: boolean) {
    setBusy(`d${r.id}`); setError(null); setNotice(null);
    try {
      await decidePointRequest(r.id, approve, notes[r.id]);
      setNotice(approve
        ? `Approved: ${r.amount.toLocaleString()} free points are in ${r.target}'s free wallet.`
        : `Declined the request for ${r.target}.`);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not record that decision.');
      await load();
    } finally { setBusy(null); }
  }

  const pending = requests.filter((r) => r.status === 'pending');
  const past = requests.filter((r) => r.status !== 'pending').slice(0, 30);
  const weekly = days.reduce((a, b) => a + (Number(b) || 0), 0);

  return (
    <div className="admin-pane stack">
      <div className="card">
        <h3>
          Requests from line managers <span className="count">{pending.length}</span>
          {pending.length > 0 && <span className="warnpill">needs a decision</span>}
        </h3>
        <p className="hint">
          Approved points go straight into the person's free wallet. No limit, and the
          ceiling below doesn't apply. A request expires if it isn't decided within 72
          hours; warnings appear at 48, 24 and 12 hours left.
        </p>
        {error && <p className="auth-error" role="alert">{error}</p>}
        {notice && <p className="auth-notice" role="status">{notice}</p>}

        {pending.length === 0 ? <p className="empty">Nothing waiting.</p> : (
          <ul className="claim-list">
            {pending.map((r) => (
              <li className="claim req" key={r.id} data-reminder={r.reminder ?? undefined}>
                <div className="req-body">
                  <b>
                    {r.amount.toLocaleString()} free points for {r.target}
                    {r.is_self && <em className="tag rule">self-request</em>}
                  </b>
                  <span className="claim-meta">
                    asked by {r.requester} ({r.requester_email}) · {when(r.created_at)}
                  </span>
                  <span className="req-comment">
                    {r.note ? <>Comment: “{r.note}”</> : <i>No comment (sent before comments were required)</i>}
                  </span>
                  <span className="req-deadline">
                    {r.reminder && <span className="reminder-pill">{r.reminder} warning</span>}
                    {timeLeft(r.hours_left)} · expires {when(r.expires_at)}
                  </span>
                </div>
                <div className="claim-actions">
                  <label className="field inline">
                    <input value={notes[r.id] ?? ''} placeholder="Note (optional)" maxLength={200}
                           onChange={(e) => setNotes((n) => ({ ...n, [r.id]: e.target.value }))} />
                  </label>
                  <button className="spin small" disabled={busy !== null}
                          onClick={() => decide(r, true)}>
                    {busy === `d${r.id}` ? '…' : 'Approve'}
                  </button>
                  <button className="linkish danger" disabled={busy !== null}
                          onClick={() => decide(r, false)}>Decline</button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="card form">
        <h3>Automatic free points</h3>
        <p className="hint">
          Paid to everyone at <b>12:00 Bangkok time</b> on the days that have an amount.
          Set a day to 0 to skip it.
          {schedule?.next
            ? <> Next grant: <b>{shortDay(schedule.next.date)}</b>, {schedule.next.amount.toLocaleString()} points.</>
            : <> No day has an amount, so nothing is paid.</>}
          {schedule?.last_run && (
            <> Last paid {shortDay(schedule.last_run.day)} to {schedule.last_run.people} {schedule.last_run.people === 1 ? 'person' : 'people'}.</>
          )}
        </p>

        <div className="daygrid">
          {WEEKDAYS.map((d, i) => (
            <label className="dayrow" key={d} data-off={days[i] === 0 ? 'true' : undefined}>
              <input type="checkbox" checked={days[i] > 0}
                     onChange={(e) => setDays((all) => all.map((v, k) =>
                       k === i ? (e.target.checked ? (v > 0 ? v : 200) : 0) : v))} />
              <span className="dayname">{d}</span>
              <input type="number" min={0} max={100000} step={1} value={days[i]}
                     aria-label={`${d} amount`}
                     onChange={(e) => setDays((all) => all.map((v, k) =>
                       k === i ? Math.max(0, Math.floor(Number(e.target.value) || 0)) : v))} />
              <span className="dayunit">points</span>
            </label>
          ))}
        </div>
        <p className="hint">Up to {weekly.toLocaleString()} points a week per person.</p>

        <label className="checkline">
          <input type="checkbox" checked={ceilingOn} onChange={(e) => setCeilingOn(e.target.checked)} />
          <span>Limit: only top up to a ceiling</span>
        </label>
        <div className="row2">
          <label className="field">
            <span>Ceiling (free points)</span>
            <input type="number" min={1} step={1} value={ceiling} disabled={!ceilingOn}
                   onChange={(e) => setCeiling(Math.floor(Number(e.target.value) || 0))} />
          </label>
          <p className="hint ceiling-eg">
            {ceilingOn
              ? <>With the limit on, someone holding 837 before a 200-point day gets
                  {' '}{Math.max(0, Math.min(200, ceiling - 837)).toLocaleString()}, and anyone at or
                  above {ceiling.toLocaleString()} gets nothing.</>
              : <>With the limit off, everyone gets the day's full amount whatever
                  their balance.</>}
          </p>
        </div>

        <div className="form-actions">
          <button className="spin" disabled={!dirty || !daysValid || !ceilingValid || busy !== null}
                  onClick={save}>
            {busy === 'save' ? 'Saving…' : 'Save schedule'}
          </button>
          {dirty && <span className="hint">Unsaved changes</span>}
        </div>
      </div>

      {past.length > 0 && (
        <div className="card">
          <h3>Decided requests <span className="count">{past.length}</span></h3>
          <ul className="claim-list">
            {past.map((r) => (
              <li className="claim" key={r.id}>
                <div>
                  <b>{r.amount.toLocaleString()} for {r.target}</b>
                  <span className="claim-meta">
                    asked by {r.requester} · {when(r.created_at)}
                    {r.decided_by && <> · by {r.decided_by}</>}
                    {r.decision_note && <> · “{r.decision_note}”</>}
                  </span>
                </div>
                <span className="status-pill" data-status={r.status}>{REQUEST_STATUS[r.status]}</span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}

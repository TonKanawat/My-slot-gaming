import { useEffect, useRef, useState } from 'react';
import { saveDisplayName } from '../lib/update1';
import { useNameCheck } from '../lib/useNameCheck';

/** The signed-in person's name in the top bar. Clicking it lets them change it;
 *  this is the name everyone else sees in the ranking. */
export function NameEditor({ name, email, onSaved }: {
  name: string | null;
  email: string;
  onSaved: (name: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [value, setValue] = useState(name ?? '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const box = useRef<HTMLDivElement>(null);
  const check = useNameCheck(open ? value : '', { current: name });

  useEffect(() => { if (open) { setValue(name ?? ''); setError(null); } }, [open, name]);

  // Close on a click outside or Escape.
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (box.current && !box.current.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false); };
    document.addEventListener('mousedown', onDown);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDown);
      document.removeEventListener('keydown', onKey);
    };
  }, [open]);

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setError(null);
    try {
      const saved = await saveDisplayName(value);
      onSaved(saved);
      setOpen(false);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not save that name.');
    } finally { setBusy(false); }
  }

  const shown = name?.trim() || email.split('@')[0];

  return (
    <div className="name-editor" ref={box}>
      <button className="name-btn" onClick={() => setOpen((o) => !o)} aria-expanded={open}
              title="Change your display name">
        <span className="name-text">{shown}</span>
        <svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true">
          <path d="M11.2 2.2a1.5 1.5 0 0 1 2.1 2.1L5.6 12l-2.9.8.8-2.9z"
                fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round" />
        </svg>
      </button>
      {open && (
        <form className="name-pop" onSubmit={save}>
          <label htmlFor="display-name">Display name</label>
          <input id="display-name" value={value} maxLength={30} autoFocus
                 onChange={(e) => setValue(e.target.value)} placeholder="How others see you"
                 aria-invalid={check.kind === 'taken' || check.kind === 'invalid'}
                 aria-describedby="display-name-check"
                 data-state={check.kind} />
          <span id="display-name-check" className="name-check" data-state={check.kind} role="status">
            {check.kind === 'checking' && 'Checking…'}
            {check.kind === 'ok' && '✓ Nobody else uses this name'}
            {check.kind === 'taken' && check.check.message}
            {check.kind === 'invalid' && check.message}
          </span>
          <span className="name-hint">2–30 characters · shown in the ranking · {email}</span>
          {error && <span className="name-error" role="alert">{error}</span>}
          <div className="name-actions">
            <button type="button" className="linkish" onClick={() => setOpen(false)}>Cancel</button>
            <button type="submit" className="spin small"
                    disabled={busy || value.trim().length < 2
                              || check.kind === 'taken' || check.kind === 'invalid'
                              || check.kind === 'checking'}>{busy ? 'Saving…' : 'Save'}</button>
          </div>
        </form>
      )}
    </div>
  );
}

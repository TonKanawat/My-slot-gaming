import { useEffect, useState } from 'react';
import { checkDisplayName, nameKey, type NameCheck } from './update1';

export type NameState =
  | { kind: 'idle' }          // nothing to check (empty, or unchanged)
  | { kind: 'checking' }
  | { kind: 'ok' }
  | { kind: 'taken'; check: NameCheck }
  | { kind: 'invalid'; message: string };

/** Asks the server, a moment after typing stops, whether a display name is free.
 *  The server stays the final word — saving re-checks — this is the early warning. */
export function useNameCheck(name: string, opts: { current?: string | null; isNew?: boolean } = {}) {
  const [state, setState] = useState<NameState>({ kind: 'idle' });
  const key = nameKey(name);
  const unchanged = !opts.isNew && opts.current != null && key === nameKey(opts.current);

  useEffect(() => {
    if (key === '' || unchanged) { setState({ kind: 'idle' }); return; }
    if (key.length < 2) { setState({ kind: 'invalid', message: 'At least 2 characters.' }); return; }
    if (key.length > 30) { setState({ kind: 'invalid', message: 'At most 30 characters.' }); return; }
    setState({ kind: 'checking' });
    let alive = true;
    const t = window.setTimeout(() => {
      checkDisplayName(name, opts.isNew ?? false)
        .then((r) => {
          if (!alive) return;
          if (r.ok) setState({ kind: 'ok' });
          else if (r.reason === 'taken') setState({ kind: 'taken', check: r });
          else setState({ kind: 'invalid', message: r.message ?? 'That name cannot be used.' });
        })
        // A failed check must not block anyone: saving checks again anyway.
        .catch(() => alive && setState({ kind: 'idle' }));
    }, 350);
    return () => { alive = false; window.clearTimeout(t); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, unchanged, opts.isNew]);

  return state;
}

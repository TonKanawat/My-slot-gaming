import { useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import {
  archiveSymbol, saveSymbol, symbolUrl, uploadSymbolImage,
  type CombinationRow, type SymbolRow,
} from '../../lib/admin';
import { SymbolList } from './SymbolList';

interface Props {
  symbols: SymbolRow[];
  combinations: CombinationRow[];
  onChanged: () => void;
}

type Kind = 'normal' | 'wild' | 'scatter';

function kindOf(s: SymbolRow): Kind {
  return s.is_wild ? 'wild' : s.is_scatter ? 'scatter' : 'normal';
}

export function SymbolsTab({ symbols, combinations, onChanged }: Props) {
  const [editing, setEditing] = useState<SymbolRow | null>(null);
  const [name, setName] = useState('');
  const [weight, setWeight] = useState(100);
  const [kind, setKind] = useState<Kind>('normal');
  const [rounds, setRounds] = useState(5);
  const [file, setFile] = useState<File | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const formRef = useRef<HTMLFormElement>(null);

  // A symbol in no group is invisible to the win engine: every line it lands on
  // fails, because a line pays only when all five cells belong to one group.
  const ungrouped = useMemo(() => {
    const covered = new Set<string>();
    for (const c of combinations) for (const s of c.symbols) covered.add(s.id);
    return new Set(symbols.filter((s) => !covered.has(s.id)).map((s) => s.id));
  }, [symbols, combinations]);

  function reset() {
    setEditing(null); setName(''); setWeight(100); setKind('normal');
    setRounds(5); setFile(null); setError(null);
    if (fileRef.current) fileRef.current.value = '';
  }

  function edit(s: SymbolRow) {
    setEditing(s);
    setName(s.name);
    setWeight(s.weight);
    setKind(kindOf(s));
    setRounds(s.scatter_free_spins || 5);
    setFile(null);
    setError(null);
    if (fileRef.current) fileRef.current.value = '';
  }

  // Bring the form into view when editing starts from a card further down the page.
  useEffect(() => {
    if (editing) formRef.current?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  }, [editing]);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setError(null);

    if (!editing && !file) { setError('Choose an image first.'); return; }
    if (file && file.size > 300 * 1024) { setError('That image is over 300 KB.'); return; }

    setBusy(true);
    try {
      // Editing without picking a new file keeps the picture it already has.
      const path = file ? await uploadSymbolImage(file) : editing!.image_path;
      await saveSymbol({
        id: editing?.id ?? null,
        name, image_path: path, weight, kind, scatter_free_spins: rounds,
      });
      reset();
      onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not save that symbol.');
    } finally {
      setBusy(false);
    }
  }

  async function remove(s: SymbolRow) {
    setError(null);
    try {
      await archiveSymbol(s.id);
      if (editing?.id === s.id) reset();
      onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not archive that symbol.');
    }
  }

  return (
    <div className="admin-pane">
      <form className="card form" onSubmit={submit} ref={formRef}>
        <h3>{editing ? `Edit ${editing.name}` : 'Add a symbol'}</h3>

        {editing && (
          <div className="edit-current">
            <img src={symbolUrl(editing.image_path)} alt="" />
            <span>Leave the file empty to keep this picture.</span>
          </div>
        )}

        <label className="field">
          <span>{editing ? 'Replace image (optional)' : 'Image — square PNG or WebP, under 300 KB'}</span>
          <input
            ref={fileRef} type="file" accept="image/png,image/webp,image/svg+xml"
            onChange={(e) => setFile(e.target.files?.[0] ?? null)}
            required={!editing}
          />
        </label>

        <div className="row2">
          <label className="field">
            <span>Name</span>
            <input value={name} onChange={(e) => setName(e.target.value)}
                   placeholder="e.g. Ake" required maxLength={40} />
          </label>
          <label className="field">
            <span>Reel weight</span>
            <input type="number" min={1} max={10000} value={weight}
                   onChange={(e) => setWeight(Number(e.target.value))} required />
          </label>
        </div>

        <label className="field">
          <span>Type</span>
          <select value={kind} onChange={(e) => setKind(e.target.value as Kind)}>
            <option value="normal">Normal</option>
            <option value="wild">Wild — substitutes for any symbol</option>
            <option value="scatter">Scatter — grants free spins</option>
          </select>
        </label>

        {kind === 'scatter' && (
          <label className="field">
            <span>Free spins this scatter grants (max 5)</span>
            <input type="number" min={1} max={5} value={rounds}
                   onChange={(e) => setRounds(Number(e.target.value))} />
          </label>
        )}
        {kind === 'scatter' && (
          <p className="notice-line">
            <b>Pays only on a winning line.</b> A scatter gives its free spins only when it
            lands on a payline that wins, so it must be in a winning group — a scatter in
            no group never pays.
          </p>
        )}

        <p className="hint">
          {kind === 'scatter'
            ? 'Scatters drive almost the whole payout rate. A weight near 3, against 100 for a normal symbol, lands about 119% return.'
            : 'Weight is relative. Leave normal symbols at 100 and they all appear equally often.'}
        </p>

        {error && <p className="auth-error" role="alert">{error}</p>}

        <div className="form-actions">
          <button className="spin" disabled={busy}>
            {busy ? 'Saving…' : editing ? 'Save changes' : 'Add symbol'}
          </button>
          {editing && <button type="button" className="linkish" onClick={reset}>Cancel</button>}
        </div>
      </form>

      <SymbolList
        symbols={symbols}
        editingId={editing?.id ?? null}
        ungrouped={ungrouped}
        onEdit={edit}
        onArchive={remove}
      />
    </div>
  );
}

import { useCallback, useEffect, useState } from 'react';
import { SymbolsTab } from './admin/SymbolsTab';
import { CombinationsTab } from './admin/CombinationsTab';
import { PlayersTab } from './admin/PlayersTab';
import { RulesTab } from './admin/RulesTab';
import { SystemTab } from './admin/SystemTab';
import {
  fetchCombinations, fetchPlayers, fetchSymbols,
  type CombinationRow, type PlayerRow, type SymbolRow,
} from '../lib/admin';
import { fetchReadiness, type Readiness } from '../lib/api';

interface Props {
  email: string;
  onSignOut: () => void;
  onReadinessChange?: (r: Readiness) => void;
  /** Rendered when the game is playable, so the admin can get back to the board. */
  onPlay?: () => void;
}

type Tab = 'symbols' | 'combinations' | 'players' | 'rules' | 'system';

export function AdminPanel({ email, onSignOut, onReadinessChange, onPlay }: Props) {
  const [tab, setTab] = useState<Tab>('symbols');
  const [symbols, setSymbols] = useState<SymbolRow[]>([]);
  const [combinations, setCombinations] = useState<CombinationRow[]>([]);
  const [players, setPlayers] = useState<PlayerRow[]>([]);
  const [readiness, setReadiness] = useState<Readiness | null>(null);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    try {
      const [s, c, p, r] = await Promise.all([
        fetchSymbols(), fetchCombinations(), fetchPlayers(), fetchReadiness(),
      ]);
      setSymbols(s);
      setCombinations(c);
      setPlayers(p);
      setReadiness(r);
      onReadinessChange?.(r);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not load the configuration.');
    }
  }, [onReadinessChange]);

  useEffect(() => { void reload(); }, [reload]);

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true" />
          <span className="brand-name">bluePi Slot</span>
          <span className="role-pill">back office</span>
        </div>
        <div className="who">
          <span className="who-email">{email}</span>
          {readiness?.ready && onPlay && (
            <button className="linkish" onClick={onPlay}>Go to the game</button>
          )}
          <button className="linkish" onClick={onSignOut}>Sign out</button>
        </div>
      </header>

      <main className="admin">
        {readiness && (
          <div className="status" data-ready={readiness.ready ? 'true' : undefined}>
            {readiness.ready ? (
              <p><b>The slot is playable.</b> {readiness.symbols} symbols,
                {' '}{readiness.groups} winning {readiness.groups === 1 ? 'group' : 'groups'},
                {' '}{readiness.scatters} scatter{readiness.scatters === 1 ? '' : 's'}.</p>
            ) : (
              <>
                <p><b>The slot is locked until you finish setting it up.</b> Still needed:</p>
                <ul className="missing">
                  {readiness.missing.map((m) => <li key={m}>{m}</li>)}
                </ul>
              </>
            )}
          </div>
        )}

        <nav className="tabs" role="tablist">
          <button role="tab" aria-selected={tab === 'symbols'}
                  data-on={tab === 'symbols' ? 'true' : undefined}
                  onClick={() => setTab('symbols')}>
            Symbols <span className="count">{symbols.length}</span>
          </button>
          <button role="tab" aria-selected={tab === 'combinations'}
                  data-on={tab === 'combinations' ? 'true' : undefined}
                  onClick={() => setTab('combinations')}>
            Winning combinations <span className="count">{combinations.length}</span>
          </button>
          <button role="tab" aria-selected={tab === 'rules'}
                  data-on={tab === 'rules' ? 'true' : undefined}
                  onClick={() => setTab('rules')}>
            Payout rules
          </button>
          <button role="tab" aria-selected={tab === 'system'}
                  data-on={tab === 'system' ? 'true' : undefined}
                  onClick={() => setTab('system')}>
            System
          </button>
          <button role="tab" aria-selected={tab === 'players'}
                  data-on={tab === 'players' ? 'true' : undefined}
                  onClick={() => setTab('players')}>
            People <span className="count">{players.length}</span>
          </button>
        </nav>

        {error && <p className="auth-error" role="alert">{error}</p>}

        {tab === 'symbols' &&
          <SymbolsTab symbols={symbols} combinations={combinations} onChanged={reload} />}
        {tab === 'combinations' &&
          <CombinationsTab symbols={symbols} combinations={combinations} onChanged={reload} />}
        {tab === 'rules' && <RulesTab onChanged={reload} />}
        {tab === 'system' && <SystemTab />}
        {tab === 'players' && <PlayersTab players={players} onChanged={reload} />}
      </main>
    </div>
  );
}

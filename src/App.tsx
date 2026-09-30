import { useCallback, useEffect, useMemo, useState } from 'react';
import { Board } from './components/Board';
import { BetSelector } from './components/BetSelector';
import { Wallets } from './components/Wallets';
import { SignIn } from './components/SignIn';
import { Notice } from './components/Notice';
import { WhyPanel } from './components/WhyPanel';
import { AdminPanel } from './components/AdminPanel';
import { RewardsPanel } from './components/RewardsPanel';
import { CombinationsPage } from './components/CombinationsPage';
import { RankingPage } from './components/RankingPage';
import { RequestPointsPage } from './components/RequestPointsPage';
import { NameEditor } from './components/NameEditor';
import { LineLegend } from './components/LineLegend';
import type { Tab as AdminTab } from './components/AdminPanel';
import {
  fetchGrantSchedule, fetchPointRequests, weekday, type GrantSchedule,
} from './lib/update1';
import { supabase } from './lib/supabase';
import { useSession } from './lib/session';
import {
  fetchActiveSymbols, fetchFreeSpins, fetchReadiness, fetchWallet, play,
  NO_FREE_SPINS,
  type FreeSpins, type Readiness, type SpinResult, type Wallet,
} from './lib/api';
import type { SymbolRow } from './lib/admin';
import type { Bet } from './game/types';
import './styles/app.css';

export default function App() {
  const { loading, session, profile, rejected, claimError, signOut } = useSession();
  const [readiness, setReadiness] = useState<Readiness | null>(null);
  const [readinessError, setReadinessError] = useState<string | null>(null);
  const [showAdmin, setShowAdmin] = useState(false);
  const [showRewards, setShowRewards] = useState(false);
  const [showCombos, setShowCombos] = useState(false);
  const [showRanking, setShowRanking] = useState(false);
  const [showRequests, setShowRequests] = useState(false);
  const [adminTab, setAdminTab] = useState<AdminTab | undefined>(undefined);
  const [displayName, setDisplayName] = useState<string | null>(null);

  useEffect(() => { setDisplayName(profile?.display_name ?? null); }, [profile]);

  useEffect(() => {
    if (!profile) return;
    fetchReadiness()
      .then(setReadiness)
      .catch((e: Error) => setReadinessError(e.message));
  }, [profile]);

  if (!supabase) {
    return (
      <Notice title="Not connected" tone="warn">
        <p>
          This deployment has no database configuration. Add{' '}
          <code>VITE_SUPABASE_URL</code> and <code>VITE_SUPABASE_ANON_KEY</code> in the
          hosting environment, then redeploy.
        </p>
      </Notice>
    );
  }

  if (loading) {
    return <Notice title="Loading…" />;
  }

  if (!session) {
    return <SignIn />;
  }

  // Signed in with Supabase, but the address was never registered for the game.
  if (rejected || !profile) {
    return (
      <Notice
        title="Registration failed"
        tone="warn"
        action={<button className="linkish" onClick={signOut}>Sign out</button>}
      >
        <p>This account cannot be used. Please contact your system admin.</p>
        {claimError && <p className="detail">Details: <code>{claimError}</code></p>}
      </Notice>
    );
  }

  if (readinessError) {
    return (
      <Notice title="Something went wrong" tone="warn"
        action={<button className="linkish" onClick={signOut}>Sign out</button>}>
        <p>{readinessError}</p>
      </Notice>
    );
  }

  const isAdmin = profile.role === 'system_admin' || profile.role === 'deputy_admin';

  // An admin who opens the back office, or who has no choice because the game is
  // not configured yet. Everyone else just gets told to wait.
  if (isAdmin && (showAdmin || (readiness && !readiness.ready))) {
    return (
      <AdminPanel
        email={profile.email}
        onSignOut={signOut}
        onReadinessChange={setReadiness}
        onPlay={() => { setShowAdmin(false); setAdminTab(undefined); }}
        initialTab={adminTab}
      />
    );
  }

  // Reachable whether or not the board is configured: a player looking up the rules
  // should not be blocked by a game that is mid-setup.
  if (showCombos) {
    return (
      <CombinationsPage
        email={profile.email}
        onSignOut={signOut}
        onBack={() => setShowCombos(false)}
      />
    );
  }

  if (showRanking) {
    return (
      <RankingPage email={profile.email} onSignOut={signOut} onBack={() => setShowRanking(false)} />
    );
  }

  if (showRequests && profile.role === 'line_manager') {
    return (
      <RequestPointsPage email={profile.email} userId={profile.user_id}
                         onSignOut={signOut} onBack={() => setShowRequests(false)} />
    );
  }

  if (showRewards) {
    return (
      <RewardsPanel
        email={profile.email}
        isAdmin={isAdmin}
        onSignOut={signOut}
        onBack={() => setShowRewards(false)}
      />
    );
  }

  if (readiness && !readiness.ready) {
    return (
      <Notice
        title="The slot isn't ready yet"
        action={<button className="linkish" onClick={signOut}>Sign out</button>}
      >
        <p>An admin still needs to finish setting up the game:</p>
        <ul className="missing">
          {readiness.missing.map((m) => <li key={m}>{m}</li>)}
        </ul>
      </Notice>
    );
  }

  return (
    <Game
      onSignOut={signOut}
      email={profile.email}
      name={displayName}
      onNameSaved={setDisplayName}
      isAdmin={isAdmin}
      isLineManager={profile.role === 'line_manager'}
      onOpenAdmin={(t?: AdminTab) => { setAdminTab(t); setShowAdmin(true); }}
      onOpenRewards={() => setShowRewards(true)}
      onOpenCombos={() => setShowCombos(true)}
      onOpenRanking={() => setShowRanking(true)}
      onOpenRequests={() => setShowRequests(true)}
    />
  );
}

/** The playable board. Every spin is decided by the server: the grid, the win and
 *  the wallet all come back from one call, and the browser only animates them. */
function Game({
  onSignOut, email, name, onNameSaved, isAdmin, isLineManager,
  onOpenAdmin, onOpenRewards, onOpenCombos, onOpenRanking, onOpenRequests,
}: {
  onSignOut: () => void; email: string; name: string | null; onNameSaved: (n: string) => void;
  isAdmin: boolean; isLineManager: boolean; onOpenAdmin: (tab?: AdminTab) => void;
  onOpenRewards: () => void; onOpenCombos: () => void; onOpenRanking: () => void;
  onOpenRequests: () => void;
}) {
  const [symbols, setSymbols] = useState<SymbolRow[]>([]);
  const [grid, setGrid] = useState<string[][]>([]);
  const [spinToken, setSpinToken] = useState(0);
  const [spinning, setSpinning] = useState(false);
  const [bet, setBet] = useState<Bet>(25);
  const [wallet, setWallet] = useState<Wallet>({ free_points: 0, points: 0 });
  const [result, setResult] = useState<SpinResult | null>(null);
  // Server-held, so it survives a refresh. Never derived from the last spin alone.
  const [freeSpins, setFreeSpins] = useState<FreeSpins>(NO_FREE_SPINS);
  const [message, setMessage] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  // The line being pointed at in the legend, shown on its own on the board.
  const [focusLine, setFocusLine] = useState<number | null>(null);
  const [schedule, setSchedule] = useState<GrantSchedule | null>(null);
  // Admins: free-point requests waiting, and how many are close to expiring.
  const [waiting, setWaiting] = useState<{ n: number; urgent: number }>({ n: 0, urgent: 0 });

  useEffect(() => {
    fetchGrantSchedule().then(setSchedule).catch(() => setSchedule(null));
    if (isAdmin) {
      fetchPointRequests()
        .then((r) => {
          const p = r.filter((x) => x.status === 'pending');
          setWaiting({ n: p.length, urgent: p.filter((x) => x.reminder === '12h').length });
        })
        .catch(() => undefined);
    }
  }, [isAdmin]);

  const freeNote = schedule?.next
    ? `spent first · +${schedule.next.amount.toLocaleString()} ${weekday(schedule.next.date)} 12:00`
      + (schedule.ceiling_on ? ` · up to ${schedule.ceiling.toLocaleString()}` : '')
    : 'spent first';

  const byId = useMemo(() => new Map(symbols.map((s) => [s.id, s])), [symbols]);
  const affordable = wallet.free_points + wallet.points;
  const freeSpinsLeft = freeSpins.remaining;

  // Load the real symbols and the real balance before anything is shown.
  useEffect(() => {
    let alive = true;
    Promise.all([fetchActiveSymbols(), fetchWallet(), fetchFreeSpins()])
      .then(([syms, w, fs]) => {
        if (!alive) return;
        setSymbols(syms);
        setWallet(w);
        setFreeSpins(fs);
        // A resting board, drawn from the real symbol set, before the first spin.
        setGrid(Array.from({ length: 5 }, () =>
          Array.from({ length: 5 }, () => syms[Math.floor(Math.random() * syms.length)]?.id ?? '')));
        setLoading(false);
      })
      .catch((e: Error) => { if (alive) { setMessage(e.message); setLoading(false); } });
    return () => { alive = false; };
  }, []);

  const spin = useCallback(async () => {
    if (spinning) return;
    if (freeSpinsLeft === 0 && bet > affordable) {
      setMessage("You don't have enough points for that bet.");
      return;
    }
    setMessage(null);
    setSpinning(true);
    try {
      const r = await play(bet);
      setResult(r);
      setFocusLine(null);
      setGrid(r.grid);
      setWallet({ free_points: r.free_points, points: r.points });
      setFreeSpins((prev) => ({
        remaining:     r.free_spins_left,
        round:         r.free_spin_round,
        rounds_max:    prev.rounds_max,
        stake:         r.free_spins_left > 0 ? r.bet : null,
        ban_bets_left: r.ban_bets_left,
      }));
      setSpinToken((t) => t + 1);
    } catch (err) {
      setSpinning(false);
      setMessage(err instanceof Error ? err.message : 'That spin could not be played.');
    }
  }, [spinning, bet, affordable, freeSpinsLeft]);

  if (loading) return <Notice title="Loading…" />;

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true" />
          <span className="brand-name">bluePi Slot</span>
        </div>
        <Wallets freePoints={wallet.free_points} points={wallet.points} freeNote={freeNote} />
        <div className="who">
          <NameEditor name={name} email={email} onSaved={onNameSaved} />
          <nav className="topnav" aria-label="Pages">
            <button className="linkish" onClick={onOpenCombos}>Winning combinations</button>
            <button className="linkish" onClick={onOpenRanking}>Ranking</button>
            <button className="linkish" onClick={onOpenRewards}>Rewards</button>
            {isLineManager && <button className="linkish" onClick={onOpenRequests}>Request points</button>}
            {isAdmin && <button className="linkish" onClick={() => onOpenAdmin()}>Back office</button>}
            <button className="linkish" onClick={onSignOut}>Sign out</button>
          </nav>
        </div>
      </header>

      <main className="stage">
        {isAdmin && waiting.n > 0 && (
          <button className="req-banner" onClick={() => onOpenAdmin('freepoints')}
                  data-urgent={waiting.urgent > 0 ? 'true' : undefined}>
            <b>{waiting.n} free-point {waiting.n === 1 ? 'request is' : 'requests are'} waiting for you</b>
            {waiting.urgent > 0 && <> · {waiting.urgent} {waiting.urgent === 1 ? 'expires' : 'expire'} in under 12 hours</>}
            <span className="req-banner-go">Review →</span>
          </button>
        )}
        {/* Board and controls sit side by side: the bet column and Spin are within
            reach of the reels rather than below the fold on a laptop. */}
        <div className="play-area">
          <Board
            grid={grid} byId={byId} pool={symbols} spinToken={spinToken}
            winningLines={result?.lines ?? []} highlighted={focusLine}
            onAllSettled={() => setSpinning(false)}
          />

          <div className="controls">
            <div className="control-row">
              <span className="control-label">Bet</span>
              <BetSelector value={bet} onChange={setBet}
                           disabled={spinning || freeSpinsLeft > 0} affordable={affordable} />
            </div>
            <button className="spin" onClick={spin} disabled={spinning}>
              {spinning ? 'Spinning…' : freeSpinsLeft > 0 ? `Free spin (${freeSpinsLeft})` : 'Spin'}
            </button>
          </div>
        </div>

        {/* Both of these are read from the server, not from the last spin, so
            refreshing the page or coming back to the tab cannot appear to swallow
            the chain or quietly drop a penalty that is still being served. */}
        {freeSpins.ban_bets_left > 0 && (
          <p className="yellow standalone" role="status">
            <b>Yellow card</b> · scatters pay no free spins for your next{' '}
            {freeSpins.ban_bets_left} {freeSpins.ban_bets_left === 1 ? 'bet' : 'bets'}
          </p>
        )}

        {freeSpinsLeft > 0 && (
          <p className="freespins standalone" role="status">
            <b>{freeSpinsLeft} free {freeSpinsLeft === 1 ? 'spin' : 'spins'} left</b>
            {' · '}round {freeSpins.round} of {freeSpins.rounds_max}
            {freeSpins.stake !== null && <>{' · '}playing at {freeSpins.stake} points</>}
          </p>
        )}

        {result && !spinning && (
          <div className="outcome" data-win={result.payout > 0 ? 'true' : undefined}>
            {result.line_count > 0 ? (
              <p>
                <b>{result.line_count} winning {result.line_count === 1 ? 'line' : 'lines'}</b>
                {' · '}×{result.multiplier}
                {' · '}<b>+{result.payout.toLocaleString()} points</b>
                {result.was_free_spin && <span className="tag rule">free spin</span>}
              </p>
            ) : (
              <p>No winning lines this time.{result.was_free_spin && <span className="tag rule">free spin</span>}</p>
            )}
            {result.lines.length > 1 && (
              <p className="hint legend-hint">Each winning line has its own colour. Point at one to see it alone.</p>
            )}
            <LineLegend lines={result.lines} active={focusLine} onHover={setFocusLine} />
            <WhyPanel grid={result.grid} />
          </div>
        )}

        {message && <p className="message" role="status">{message}</p>}
      </main>
    </div>
  );
}

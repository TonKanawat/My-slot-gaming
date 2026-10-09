import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react';
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
import { TopNav, type View } from './components/TopNav';
import { LineLegend } from './components/LineLegend';
import { LiveBoostChip, PromoBanner } from './components/PromoBanner';
import { dismissPromotions, fetchPromotions, type Promotion } from './lib/promotions';
import type { Tab as AdminTab } from './components/AdminPanel';
import {
  fetchGrantSchedule, fetchPointRequests, weekday, type GrantSchedule,
} from './lib/update1';
import { supabase } from './lib/supabase';
import { useSession } from './lib/session';
import {
  fetchActiveSymbols, fetchCombinationNames, fetchFreeSpins, fetchReadiness, fetchWallet, play,
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
  const [view, setView] = useState<View>('game');
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
  const isLineManager = profile.role === 'line_manager';
  const gameReady = readiness?.ready ?? false;

  const go = (v: View, tab?: AdminTab) => {
    setAdminTab(v === 'admin' ? tab : undefined);
    setView(v);
    window.scrollTo(0, 0);
  };

  // An admin with a game that isn't configured yet has nowhere else to play.
  const current: View =
    isAdmin && readiness && !readiness.ready && view === 'game' ? 'admin'
    : view === 'admin' && !isAdmin ? 'game'
    : view === 'requests' && !isLineManager ? 'game'
    : view;

  const nav = (
    <TopNav
      current={current} name={displayName} email={profile.email} onNameSaved={setDisplayName}
      isAdmin={isAdmin} isLineManager={isLineManager} gameReady={gameReady}
      onNavigate={go} onSignOut={signOut}
    />
  );

  if (current === 'admin') {
    return (
      <AdminPanel
        key={adminTab ?? 'admin'}
        nav={nav}
        onReadinessChange={setReadiness}
        initialTab={adminTab}
      />
    );
  }

  // These pages work whether or not the board is configured: looking up the rules
  // or the ranking shouldn't be blocked by a game that is mid-setup.
  if (current === 'combos') return <CombinationsPage nav={nav} />;
  if (current === 'ranking') return <RankingPage nav={nav} />;
  if (current === 'requests') return <RequestPointsPage nav={nav} userId={profile.user_id} />;
  if (current === 'rewards') return <RewardsPanel nav={nav} email={profile.email} isAdmin={isAdmin} />;

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
        <p className="notice-links">
          Meanwhile:{' '}
          <button className="linkish" onClick={() => go('combos')}>Winning combinations</button>
          {' · '}
          <button className="linkish" onClick={() => go('ranking')}>Ranking</button>
          {' · '}
          <button className="linkish" onClick={() => go('rewards')}>Rewards</button>
        </p>
      </Notice>
    );
  }

  return (
    <Game
      nav={nav}
      isAdmin={isAdmin}
      onOpenAdmin={(t?: AdminTab) => go('admin', t)}
    />
  );
}

/** The playable board. Every spin is decided by the server: the grid, the win and
 *  the wallet all come back from one call, and the browser only animates them. */
function Game({ nav, isAdmin, onOpenAdmin }: {
  nav: ReactNode; isAdmin: boolean; onOpenAdmin: (tab?: AdminTab) => void;
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
  // Lines pinned in the legend; they stay on the board until unpinned or the next spin.
  const [pinned, setPinned] = useState<number[]>([]);
  // Whether a Yellow Card was in force when the last spin was played: scatters on a
  // winning line then pay nothing, and the result should say so.
  const [bannedAtSpin, setBannedAtSpin] = useState(false);
  const [comboNames, setComboNames] = useState<Map<string, string>>(new Map());
  const [schedule, setSchedule] = useState<GrantSchedule | null>(null);
  // Admins: free-point requests waiting, and how many are close to expiring.
  const [waiting, setWaiting] = useState<{ n: number; urgent: number }>({ n: 0, urgent: 0 });
  // Promotions: the home-page label and the live-boost chip. Re-read every minute
  // so a promotion that starts or ends while the page is open shows up.
  const [promos, setPromos] = useState<Promotion[]>([]);
  const loadPromos = useCallback(() => {
    fetchPromotions().then(setPromos).catch(() => undefined);
  }, []);
  useEffect(() => {
    loadPromos();
    const t = window.setInterval(loadPromos, 60_000);
    return () => window.clearInterval(t);
  }, [loadPromos]);

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
    // Group names are only for labels: a failure here must not block the game.
    fetchCombinationNames().then((m) => { if (alive) setComboNames(m); }).catch(() => undefined);
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
      const wasBanned = freeSpins.ban_bets_left > 0;
      const r = await play(bet);
      setBannedAtSpin(wasBanned);
      setResult(r);
      setPinned([]);
      // A group added since the page loaded has no name here yet: fetch again.
      if (r.lines.some((l) => !comboNames.has(l.combination))) {
        fetchCombinationNames().then(setComboNames).catch(() => undefined);
      }
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
  }, [spinning, bet, affordable, freeSpinsLeft, comboNames, freeSpins.ban_bets_left]);

  if (loading) return <Notice title="Loading…" />;

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true" />
          <span className="brand-name">bluePi Slot</span>
        </div>
        <Wallets freePoints={wallet.free_points} points={wallet.points} freeNote={freeNote} />
        {nav}
      </header>

      <main className="stage">
        <PromoBanner
          promos={promos}
          onDismiss={async (ids) => { await dismissPromotions(ids); loadPromos(); }}
        />
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
            winningLines={result?.lines ?? []} highlighted={pinned}
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
            <LiveBoostChip promos={promos} />
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
                {result.promo && (
                  <span className="promo-gain">
                    {' '}({result.promo.base_payout.toLocaleString()} + <b>{result.promo.bonus.toLocaleString()}</b>
                    {' '}🔥 {result.promo.name} x{Number(result.promo.extra).toLocaleString(undefined, { maximumFractionDigits: 2 })})
                  </span>
                )}
                {result.was_free_spin && <span className="tag rule">free spin</span>}
              </p>
            ) : (
              <p>No winning lines this time.{result.was_free_spin && <span className="tag rule">free spin</span>}</p>
            )}
            <ScatterNote result={result} banned={bannedAtSpin} />
            <LineLegend
              lines={result.lines} names={comboNames} pinned={pinned}
              onToggle={(p) => setPinned((cur) => cur.includes(p) ? cur.filter((x) => x !== p) : [...cur, p])}
              onClear={() => setPinned([])}
            />
            <WhyPanel grid={result.grid} />
          </div>
        )}

        {message && <p className="message" role="status">{message}</p>}
      </main>
    </div>
  );
}

/** Why this spin did or didn't give free spins. Scatters pay only when they sit on
 *  a winning line, which is easy to miss, so the result says it in words. */
function ScatterNote({ result, banned }: { result: SpinResult; banned: boolean }) {
  const paid = result.scatters_paid ?? [];
  const missed = result.scatters_missed ?? 0;
  if (paid.length === 0 && missed === 0) return null;

  const who = paid.map((p) => `${p.name} (+${p.spins})`).join(', ');
  const capped = (result.free_spins_raw ?? 0) > result.free_spins;

  return (
    <p className="scatter-note" data-kind={paid.length > 0 && !banned ? 'paid' : 'missed'}>
      {paid.length > 0 && !banned && (
        <>
          <b>+{result.free_spins} free {result.free_spins === 1 ? 'spin' : 'spins'}</b>
          {' — '}scatter on a winning line: {who}
          {capped && <> · capped at {result.free_spins} per spin</>}
        </>
      )}
      {paid.length > 0 && banned && (
        <>Scatter on a winning line ({who}), but the <b>Yellow card</b> blocks free spins for now.</>
      )}
      {paid.length === 0 && missed > 0 && (
        <>
          {missed === 1 ? 'A scatter landed' : `${missed} scatters landed`} off the winning lines
          {' — '}scatters give free spins only when they are on a winning line.
        </>
      )}
      {paid.length > 0 && missed > 0 && (
        <span className="scatter-also">
          {' · '}{missed} other {missed === 1 ? 'scatter was' : 'scatters were'} off the winning lines and paid nothing
        </span>
      )}
    </p>
  );
}

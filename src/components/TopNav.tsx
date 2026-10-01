import { NameEditor } from './NameEditor';

export type View = 'game' | 'combos' | 'ranking' | 'rewards' | 'requests' | 'admin';

interface Props {
  current: View;
  name: string | null;
  email: string;
  onNameSaved: (name: string) => void;
  isAdmin: boolean;
  isLineManager: boolean;
  /** The board can only be opened once the game is configured. */
  gameReady: boolean;
  onNavigate: (v: View) => void;
  onSignOut: () => void;
}

/** The same links on every page, with the page you're on marked, so moving from
 *  Ranking to Rewards doesn't mean going back to the game first. */
export function TopNav({
  current, name, email, onNameSaved, isAdmin, isLineManager, gameReady, onNavigate, onSignOut,
}: Props) {
  const links: { view: View; label: string; show: boolean }[] = [
    { view: 'game',     label: 'Play',                 show: gameReady },
    { view: 'combos',   label: 'Winning combinations', show: true },
    { view: 'ranking',  label: 'Ranking',              show: true },
    { view: 'rewards',  label: 'Rewards',              show: true },
    { view: 'requests', label: 'Request points',       show: isLineManager },
    { view: 'admin',    label: 'Back office',          show: isAdmin },
  ];

  return (
    <div className="who sitenav">
      <nav className="topnav" aria-label="Pages">
        {links.filter((l) => l.show).map((l) => (
          <button
            key={l.view}
            className="linkish navlink"
            data-on={current === l.view ? 'true' : undefined}
            aria-current={current === l.view ? 'page' : undefined}
            onClick={() => { if (current !== l.view) onNavigate(l.view); }}
          >
            {l.label}
          </button>
        ))}
      </nav>
      <div className="who-me">
        <NameEditor name={name} email={email} onSaved={onNameSaved} />
        <button className="linkish" onClick={onSignOut}>Sign out</button>
      </div>
    </div>
  );
}

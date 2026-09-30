interface Props { freePoints: number; points: number; freeNote?: string; }

/** Free points are always spent first, so they lead. */
export function Wallets({ freePoints, points, freeNote }: Props) {
  return (
    <div className="wallets">
      <div className="wallet">
        <span className="wallet-label">Free points</span>
        <span className="wallet-value">{freePoints.toLocaleString()}</span>
        <span className="wallet-note">{freeNote ?? 'spent first'}</span>
      </div>
      <div className="wallet" data-kind="prize">
        <span className="wallet-label">Wallet</span>
        <span className="wallet-value">{points.toLocaleString()}</span>
        <span className="wallet-note">winnings · claim rewards from here</span>
      </div>
    </div>
  );
}

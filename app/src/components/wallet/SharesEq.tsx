import { fmtTokens } from "@/lib/format";

/**
 * ERC-8056: a Stock Token balance is a raw amount; `uiMultiplier` (18 dp, 1e18 = 1.0) turns it into the
 * number of underlying shares it represents after dividends and splits. Raw balances never change,
 * the multiplier does. Shown next to every Stock Token figure.
 */
export function SharesEq({
  raw,
  uiMultiplier,
  decimals = 18,
  symbol,
}: {
  raw: bigint | string;
  uiMultiplier: bigint | string;
  decimals?: number;
  symbol?: string;
}) {
  const r = BigInt(raw);
  const m = BigInt(uiMultiplier);
  const eq = (r * m) / 10n ** 18n;
  const same = m === 10n ** 18n;
  return (
    <span className="note whitespace-nowrap" title="Shares equivalent via ERC-8056 uiMultiplier">
      ≈ {fmtTokens(eq, decimals, 4)} shares{same ? "" : ` (×${(Number(m) / 1e18).toFixed(4)})`}
      {symbol ? ` of ${symbol}` : ""}
    </span>
  );
}

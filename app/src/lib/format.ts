import { formatUnits } from "viem";

/** Units: USDG 6 dp, stock tokens 18 dp, vault shares 24 dp, prices 8 dp, uiMultiplier 18 dp. */

const nf = (min: number, max: number) =>
  new Intl.NumberFormat("en-US", { minimumFractionDigits: min, maximumFractionDigits: max });

export function fmtUsd(value: bigint | string | null | undefined, decimals = 6, dp = 2): string {
  if (value === null || value === undefined) return "—";
  const n = Number(formatUnits(BigInt(value), decimals));
  return "$" + nf(dp, dp).format(n);
}

/** Compact USD for big figures: $25,000 → "$25.0k", $10,400,000 → "$10.4M". */
export function fmtUsdCompact(value: bigint | string | null | undefined, decimals = 6): string {
  if (value === null || value === undefined) return "—";
  const n = Number(formatUnits(BigInt(value), decimals));
  if (n >= 1_000_000) return "$" + nf(1, 1).format(n / 1_000_000) + "M";
  if (n >= 10_000) return "$" + nf(1, 1).format(n / 1_000) + "k";
  return "$" + nf(0, 0).format(n);
}

export function fmtPrice8(value: bigint | string | null | undefined): string {
  if (value === null || value === undefined) return "—";
  return "$" + nf(2, 2).format(Number(formatUnits(BigInt(value), 8)));
}

export function fmtTokens(
  value: bigint | string | null | undefined,
  decimals = 18,
  dp = 4,
): string {
  if (value === null || value === undefined) return "—";
  const n = Number(formatUnits(BigInt(value), decimals));
  return nf(0, dp).format(n);
}

/** Fraction (0.0071) → "0.71%". */
export function fmtPct(fraction: number | null | undefined, dp = 2): string {
  if (fraction === null || fraction === undefined || !Number.isFinite(fraction)) return "—";
  return nf(dp, dp).format(fraction * 100) + "%";
}

/** Basis points → "+8.0%". */
export function fmtBps(bps: number | null | undefined, sign = true): string {
  if (bps === null || bps === undefined) return "—";
  const p = bps / 100;
  return (sign && p > 0 ? "+" : "") + nf(1, 1).format(p) + "%";
}

export function short(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

export function fmtDateUtc(unix: bigint | number | string | null | undefined): string {
  if (unix === null || unix === undefined) return "—";
  const n = Number(unix);
  if (!n) return "—";
  const d = new Date(n * 1000);
  const day = d.toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });
  const time = d.toISOString().slice(11, 16);
  return `${day} ${time} UTC`;
}

export function fmtDateShort(unix: bigint | number | string | null | undefined): string {
  if (unix === null || unix === undefined) return "—";
  const n = Number(unix);
  if (!n) return "—";
  return new Date(n * 1000).toLocaleDateString("en-GB", { day: "numeric", month: "short", timeZone: "UTC" });
}

/** Seconds → "2d 04:13:09" / "04:13:09". */
export function fmtCountdown(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const d = Math.floor(s / 86_400);
  const h = Math.floor((s % 86_400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const hms = `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
  return d > 0 ? `${d}d ${hms}` : hms;
}

export function fmtDays(seconds: number): string {
  const d = seconds / 86_400;
  if (d >= 1) return nf(0, 1).format(d) + (d === 1 ? " day" : " days");
  const h = seconds / 3600;
  return nf(0, 0).format(h) + (h === 1 ? " hour" : " hours");
}

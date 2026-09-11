const usdCompact = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", notation: "compact", maximumFractionDigits: 2 });
const usdFull = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 2, minimumFractionDigits: 2 });

export function usd(value: number | null | undefined, opts: { compact?: boolean } = {}): string {
  if (value === null || value === undefined || !Number.isFinite(value)) return "–";
  if (opts.compact && Math.abs(value) >= 100_000) return usdCompact.format(value);
  return usdFull.format(value);
}

export function pct(value: number | null | undefined, digits = 2): string {
  if (value === null || value === undefined || !Number.isFinite(value)) return "–";
  return `${(value * 100).toFixed(digits)}%`;
}

/** Token amount with sensible precision for its magnitude. */
export function tokenAmount(value: number | null | undefined, symbol?: string): string {
  if (value === null || value === undefined || !Number.isFinite(value)) return "–";
  const abs = Math.abs(value);
  const digits = abs === 0 ? 2 : abs >= 1_000 ? 2 : abs >= 1 ? 4 : 6;
  const s = value.toLocaleString("en-US", { maximumFractionDigits: digits, minimumFractionDigits: Math.min(2, digits) });
  return symbol ? `${s} ${symbol}` : s;
}

export function healthFactor(value: number | null | undefined): string {
  if (value === null || value === undefined) return "∞";
  if (!Number.isFinite(value)) return "∞";
  if (value > 100) return ">100";
  return value.toFixed(2);
}

export function shortAddress(address?: string | null): string {
  if (!address) return "";
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

export function duration(seconds: number): string {
  if (seconds <= 0) return "now";
  const d = Math.floor(seconds / 86_400);
  const h = Math.floor((seconds % 86_400) / 3_600);
  const m = Math.floor((seconds % 3_600) / 60);
  const s = Math.floor(seconds % 60);
  if (d) return `${d}d ${h}h`;
  if (h) return `${h}h ${m}m`;
  if (m) return `${m}m ${s}s`;
  return `${s}s`;
}

export function timeAgo(iso: string | number): string {
  const t = typeof iso === "number" ? iso * 1000 : new Date(iso).getTime();
  const s = Math.max(0, Math.round((Date.now() - t) / 1000));
  return `${duration(s)} ago`;
}

/** Parse a user-typed decimal into base units without floating point. Returns null if invalid. */
export function parseAmount(input: string, decimals: number): bigint | null {
  const s = input.trim();
  if (!/^\d*\.?\d*$/.test(s) || s === "" || s === ".") return null;
  const [whole = "0", frac = ""] = s.split(".");
  if (frac.length > decimals) return null;
  return BigInt(whole || "0") * 10n ** BigInt(decimals) + BigInt((frac + "0".repeat(decimals)).slice(0, decimals) || "0");
}

export function formatUnitsExact(raw: string | bigint, decimals: number): string {
  const v = BigInt(raw);
  const unit = 10n ** BigInt(decimals);
  const whole = v / unit;
  const frac = (v % unit).toString().padStart(decimals, "0").replace(/0+$/, "");
  return frac ? `${whole}.${frac}` : whole.toString();
}

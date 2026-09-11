/**
 * Risk classification: the single source of truth used by the monitor, the API and the dashboard.
 * Pure functions, so every threshold is unit-tested (shared/test/risk.test.ts).
 */
import { MAX_UINT256, WAD, rayToNumber } from "./math.js";

export const RISK_LEVELS = ["SAFE", "WARNING", "DANGER", "LIQUIDATABLE", "UNKNOWN"] as const;
export type RiskLevel = (typeof RISK_LEVELS)[number];

export interface HealthThresholds {
  /** HF below this is WARNING (default 1.5). */
  warning: bigint;
  /** HF below this is DANGER (default 1.2). */
  danger: bigint;
}

export const DEFAULT_HEALTH_THRESHOLDS: HealthThresholds = {
  warning: (15n * WAD) / 10n,
  danger: (12n * WAD) / 10n,
};

/**
 *   no debt              SAFE
 *   HF >= 1.5            SAFE
 *   1.2 <= HF < 1.5      WARNING       a ~20-33% collateral drop from liquidation
 *   1.0 <= HF < 1.2      DANGER        < ~17% from liquidation
 *   HF < 1.0             LIQUIDATABLE
 *   unpriceable          UNKNOWN       an exposed oracle is down: cannot be valued, cannot be liquidated
 */
export function classifyHealthFactor(
  healthFactor: bigint,
  opts: { priced: boolean; thresholds?: HealthThresholds } = { priced: true },
): RiskLevel {
  if (!opts.priced) return "UNKNOWN";
  if (healthFactor === MAX_UINT256) return "SAFE";
  const t = opts.thresholds ?? DEFAULT_HEALTH_THRESHOLDS;
  if (healthFactor < WAD) return "LIQUIDATABLE";
  if (healthFactor < t.danger) return "DANGER";
  if (healthFactor < t.warning) return "WARNING";
  return "SAFE";
}

/** Price drop in collateral (as a fraction) that would bring the account to HF = 1. */
export function distanceToLiquidation(healthFactor: bigint): number | null {
  if (healthFactor === MAX_UINT256) return null;
  if (healthFactor <= WAD) return 0;
  return 1 - Number((WAD * 1_000_000n) / healthFactor) / 1_000_000;
}

// ------------------------------------------------------------------ findings

export type Severity = "info" | "warning" | "critical";

export interface Finding {
  kind: string;
  severity: Severity;
  subject: string;
  message: string;
  data: Record<string, unknown>;
}

/** Oracle PriceStatus enum as returned by the contracts. */
export const PRICE_STATUS = ["OK", "OK_PRIMARY_ONLY", "OK_FALLBACK", "NOT_CONFIGURED", "PAUSED", "DEVIATION", "UNAVAILABLE"] as const;
export type PriceStatusName = (typeof PRICE_STATUS)[number];

export interface MarketRiskInput {
  reserve: string;
  symbol: string;
  utilizationRay: bigint;
  cash: bigint;
  totalSupplied: bigint;
  deficit: bigint;
  priceStatus: PriceStatusName;
  /** Seconds since the feed's last update, if known. */
  priceAgeSeconds?: number;
  heartbeatSeconds?: number;
  /** Utilization at the previous observation, to detect abnormal jumps. */
  previousUtilizationRay?: bigint;
}

export interface MarketRiskConfig {
  highUtilization: number; //      default 0.90
  criticalUtilization: number; //  default 0.97
  utilizationJump: number; //      default 0.15 absolute
  lowLiquidityShare: number; //    default 0.05 of supplied
  staleWarningShare: number; //    default 0.80 of heartbeat
}

export const DEFAULT_MARKET_RISK_CONFIG: MarketRiskConfig = {
  highUtilization: 0.9,
  criticalUtilization: 0.97,
  utilizationJump: 0.15,
  lowLiquidityShare: 0.05,
  staleWarningShare: 0.8,
};

export function evaluateMarket(m: MarketRiskInput, cfg: MarketRiskConfig = DEFAULT_MARKET_RISK_CONFIG): Finding[] {
  const out: Finding[] = [];
  const u = rayToNumber(m.utilizationRay);
  const subject = m.reserve;

  if (u >= cfg.criticalUtilization) {
    out.push({ kind: "HIGH_UTILIZATION", severity: "critical", subject, message: `${m.symbol} utilization ${(u * 100).toFixed(1)}%: withdrawals and liquidations may lack liquidity`, data: { utilization: u } });
  } else if (u >= cfg.highUtilization) {
    out.push({ kind: "HIGH_UTILIZATION", severity: "warning", subject, message: `${m.symbol} utilization ${(u * 100).toFixed(1)}% is above the kink`, data: { utilization: u } });
  }

  if (m.previousUtilizationRay !== undefined) {
    const jump = u - rayToNumber(m.previousUtilizationRay);
    if (Math.abs(jump) >= cfg.utilizationJump) {
      out.push({ kind: "ABNORMAL_UTILIZATION", severity: "warning", subject, message: `${m.symbol} utilization moved ${(jump * 100).toFixed(1)} points since the last observation`, data: { jump } });
    }
  }

  if (m.totalSupplied > 0n) {
    const liquidityShare = Number((m.cash * 1_000_000n) / m.totalSupplied) / 1_000_000;
    if (liquidityShare < cfg.lowLiquidityShare) {
      out.push({ kind: "LOW_LIQUIDITY", severity: "critical", subject, message: `${m.symbol} available liquidity is ${(liquidityShare * 100).toFixed(2)}% of supply`, data: { liquidityShare } });
    }
  }

  switch (m.priceStatus) {
    case "OK":
      break;
    case "OK_PRIMARY_ONLY":
    case "OK_FALLBACK":
      out.push({ kind: "ORACLE_DEGRADED", severity: "warning", subject, message: `${m.symbol} oracle degraded (${m.priceStatus}): running on a single source`, data: { status: m.priceStatus } });
      break;
    default:
      out.push({ kind: "ORACLE_UNAVAILABLE", severity: "critical", subject, message: `${m.symbol} price unavailable (${m.priceStatus}): borrows, collateral withdrawals and liquidations are halted for exposed accounts`, data: { status: m.priceStatus } });
  }

  if (m.priceAgeSeconds !== undefined && m.heartbeatSeconds && m.priceStatus === "OK") {
    const share = m.priceAgeSeconds / m.heartbeatSeconds;
    if (share >= cfg.staleWarningShare) {
      out.push({ kind: "ORACLE_STALE_SOON", severity: "warning", subject, message: `${m.symbol} price is ${Math.round(share * 100)}% of its heartbeat old`, data: { ageSeconds: m.priceAgeSeconds, heartbeatSeconds: m.heartbeatSeconds } });
    }
  }

  if (m.deficit > 0n) {
    out.push({ kind: "BAD_DEBT", severity: "critical", subject, message: `${m.symbol} carries unrecovered bad debt (deficit)`, data: { deficit: m.deficit.toString() } });
  }
  return out;
}

export interface AccountRiskInput {
  account: string;
  priced: boolean;
  healthFactor: bigint;
  collateralUsd: number;
  debtUsd: number;
}

export interface AccountRiskConfig {
  thresholds: HealthThresholds;
  largeDebtUsd: number; //          default $100k
  largeShareOfBorrows: number; //   default 20% of protocol borrows
}

export const DEFAULT_ACCOUNT_RISK_CONFIG: AccountRiskConfig = {
  thresholds: DEFAULT_HEALTH_THRESHOLDS,
  largeDebtUsd: 100_000,
  largeShareOfBorrows: 0.2,
};

export function evaluateAccount(
  a: AccountRiskInput,
  protocolBorrowsUsd: number,
  cfg: AccountRiskConfig = DEFAULT_ACCOUNT_RISK_CONFIG,
): { level: RiskLevel; findings: Finding[] } {
  const level = classifyHealthFactor(a.healthFactor, { priced: a.priced, thresholds: cfg.thresholds });
  const findings: Finding[] = [];
  const subject = a.account;

  if (level === "LIQUIDATABLE") {
    findings.push({ kind: "LIQUIDATABLE", severity: "critical", subject, message: `Account is liquidatable (HF < 1)`, data: { debtUsd: a.debtUsd } });
  } else if (level === "DANGER") {
    findings.push({ kind: "NEAR_LIQUIDATION", severity: "warning", subject, message: `Account is close to liquidation`, data: { debtUsd: a.debtUsd } });
  } else if (level === "UNKNOWN") {
    findings.push({ kind: "UNPRICEABLE_ACCOUNT", severity: "warning", subject, message: `Account cannot be valued: an exposed oracle is unavailable`, data: {} });
  }

  if (a.priced && a.debtUsd > 0 && a.collateralUsd < a.debtUsd) {
    findings.push({ kind: "POTENTIAL_BAD_DEBT", severity: "critical", subject, message: `Collateral ($${a.collateralUsd.toFixed(2)}) is worth less than debt ($${a.debtUsd.toFixed(2)})`, data: { shortfallUsd: a.debtUsd - a.collateralUsd } });
  }

  const share = protocolBorrowsUsd > 0 ? a.debtUsd / protocolBorrowsUsd : 0;
  if (a.debtUsd >= cfg.largeDebtUsd || (a.debtUsd > 0 && share >= cfg.largeShareOfBorrows)) {
    findings.push({ kind: "LARGE_BORROW", severity: "info", subject, message: `Large borrower: $${Math.round(a.debtUsd).toLocaleString("en-US")} (${(share * 100).toFixed(1)}% of protocol borrows)`, data: { debtUsd: a.debtUsd, share } });
  }
  return { level, findings };
}

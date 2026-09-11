import type { Health, Market, RiskLevel } from "./api";

/**
 * Client-side what-if maths for the action forms: "what will my health factor be after this?"
 * The pool remains the authority (every form also simulates the transaction before signing).
 * These mirror RiskEngine: HF = sum(collateral_i * LT_i) / totalDebt.
 */
export interface Projection {
  healthFactor: number | null; // null = no debt
  borrowCapacityUsd: number;
  debtUsd: number;
}

export type Action = "supply" | "withdraw" | "borrow" | "repay";

export function project(h: Health, market: Market, action: Action, amount: number, collateralEnabled: boolean): Projection {
  const valueUsd = amount * market.price.usd;
  let liq = h.liquidationThresholdUsd;
  let cap = h.borrowCapacityUsd;
  let debt = h.totalDebtUsd;
  // Supplying auto-enables collateral on a first own supply; withdrawal only matters if it is collateral.
  const countsAsCollateral = collateralEnabled || (action === "supply" && market.config.collateralEnabled);
  switch (action) {
    case "supply":
      if (countsAsCollateral) {
        liq += valueUsd * market.config.liquidationThreshold;
        cap += valueUsd * market.config.ltv;
      }
      break;
    case "withdraw":
      if (collateralEnabled) {
        liq -= valueUsd * market.config.liquidationThreshold;
        cap -= valueUsd * market.config.ltv;
      }
      break;
    case "borrow":
      debt += valueUsd;
      break;
    case "repay":
      debt = Math.max(0, debt - valueUsd);
      break;
  }
  return {
    healthFactor: debt <= 1e-9 ? null : Math.max(0, liq) / debt,
    borrowCapacityUsd: Math.max(0, cap),
    debtUsd: debt,
  };
}

/** Levels mirror shared/src/risk.ts (the API returns the canonical level for stored data). */
export function levelFor(hf: number | null): RiskLevel {
  if (hf === null) return "SAFE";
  if (hf < 1) return "LIQUIDATABLE";
  if (hf < 1.2) return "DANGER";
  if (hf < 1.5) return "WARNING";
  return "SAFE";
}

export const LEVEL_META: Record<RiskLevel, { label: string; tone: "good" | "warning" | "serious" | "critical" | "neutral"; hint: string }> = {
  SAFE: { label: "Safe", tone: "good", hint: "HF ≥ 1.5 or no debt" },
  WARNING: { label: "Warning", tone: "warning", hint: "1.2 ≤ HF < 1.5" },
  DANGER: { label: "Danger", tone: "serious", hint: "1.0 ≤ HF < 1.2" },
  LIQUIDATABLE: { label: "Liquidatable", tone: "critical", hint: "HF < 1" },
  UNKNOWN: { label: "Unpriceable", tone: "neutral", hint: "An exposed oracle is unavailable" },
};

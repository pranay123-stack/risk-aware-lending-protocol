import {
  BPS,
  PRICE_STATUS,
  aprToApy,
  classifyHealthFactor,
  distanceToLiquidation,
  healthFactorToNumber,
  rayToNumber,
  toNumber,
  usdValue,
  wadToNumber,
  type PriceStatusName,
  type RiskLevel,
} from "@lending/shared";
import type { Address } from "viem";
import type { MarketData, UserPositions } from "./chain/reader.js";

/**
 * API DTOs. Every on-chain quantity is returned twice: `raw` (exact integer string, for anything
 * that computes or signs) and a display number (for charts and tables). Clients never have to
 * parse a float back into an amount.
 */
export interface AmountDto {
  raw: string;
  amount: number;
  usd: number;
}

export function amountDto(raw: bigint, decimals: number, priceWad: bigint): AmountDto {
  return { raw: raw.toString(), amount: toNumber(raw, decimals), usd: usdValue(raw, decimals, priceWad) };
}

const bps = (v: number | bigint) => Number(v) / Number(BPS);

export function priceStatusName(status: number): PriceStatusName {
  return PRICE_STATUS[status] ?? "UNAVAILABLE";
}

export interface MarketDto {
  asset: Address;
  symbol: string;
  decimals: number;
  price: { usd: number; raw: string; status: PriceStatusName };
  totalSupplied: AmountDto;
  totalBorrowed: AmountDto;
  availableLiquidity: AmountDto;
  treasury: AmountDto;
  deficit: AmountDto;
  utilization: number;
  supplyApr: number;
  supplyApy: number;
  borrowApr: number;
  borrowApy: number;
  config: {
    ltv: number;
    liquidationThreshold: number;
    liquidationBonus: number;
    reserveFactor: number;
    supplyCap: string;
    borrowCap: string;
    active: boolean;
    frozen: boolean;
    paused: boolean;
    borrowingEnabled: boolean;
    collateralEnabled: boolean;
  };
  interestRateModel: {
    address: Address;
    baseRate: number;
    slope1: number;
    slope2: number;
    optimalUtilization: number;
    raw: { baseRate: string; slope1: string; slope2: string; optimalUtilization: string };
  };
  indexes: { liquidity: string; borrow: string };
}

export function marketDto(m: MarketData): MarketDto {
  const d = Number(m.decimals);
  return {
    asset: m.asset,
    symbol: m.symbol,
    decimals: d,
    price: { usd: wadToNumber(m.price), raw: m.price.toString(), status: priceStatusName(m.priceStatus) },
    totalSupplied: amountDto(m.totalSupplied, d, m.price),
    totalBorrowed: amountDto(m.totalBorrowed, d, m.price),
    availableLiquidity: amountDto(m.cash, d, m.price),
    treasury: amountDto(m.treasury, d, m.price),
    deficit: amountDto(m.deficit, d, m.price),
    utilization: rayToNumber(m.utilization),
    supplyApr: rayToNumber(m.liquidityRate),
    supplyApy: aprToApy(m.liquidityRate),
    borrowApr: rayToNumber(m.borrowRate),
    borrowApy: aprToApy(m.borrowRate),
    config: {
      ltv: bps(m.config.ltv),
      liquidationThreshold: bps(m.config.liquidationThreshold),
      liquidationBonus: bps(m.config.liquidationBonus),
      reserveFactor: bps(m.config.reserveFactor),
      supplyCap: m.config.supplyCap.toString(),
      borrowCap: m.config.borrowCap.toString(),
      active: m.config.active,
      frozen: m.config.frozen,
      paused: m.config.paused,
      borrowingEnabled: m.config.borrowingEnabled,
      collateralEnabled: m.config.collateralEnabled,
    },
    interestRateModel: {
      address: m.interestRateModel,
      baseRate: rayToNumber(m.baseRate),
      slope1: rayToNumber(m.slope1),
      slope2: rayToNumber(m.slope2),
      optimalUtilization: rayToNumber(m.optimalUtilization),
      raw: {
        baseRate: m.baseRate.toString(),
        slope1: m.slope1.toString(),
        slope2: m.slope2.toString(),
        optimalUtilization: m.optimalUtilization.toString(),
      },
    },
    indexes: { liquidity: m.liquidityIndex.toString(), borrow: m.borrowIndex.toString() },
  };
}

export interface PositionDto {
  asset: Address;
  symbol: string;
  decimals: number;
  supplied: AmountDto;
  borrowed: AmountDto;
  collateralEnabled: boolean;
  walletBalance: AmountDto;
  /** ERC-20 allowance to the pool, raw units. */
  allowance: string;
  maxBorrow: AmountDto;
  maxWithdraw: AmountDto;
  supplyApy: number;
  borrowApy: number;
}

export interface HealthDto {
  address: Address;
  priced: boolean;
  healthFactor: number | null; // null = no debt (infinite)
  healthFactorRaw: string;
  riskLevel: RiskLevel;
  distanceToLiquidation: number | null;
  totalCollateralUsd: number;
  totalDebtUsd: number;
  borrowCapacityUsd: number;
  availableToBorrowUsd: number;
  liquidationThresholdUsd: number;
  /** Collateral-weighted averages, as fractions. */
  averageLtv: number;
  averageLiquidationThreshold: number;
}

export function healthDto(address: Address, h: UserPositions[1]): HealthDto {
  const collateral = wadToNumber(h.totalCollateralValue);
  const debt = wadToNumber(h.totalDebtValue);
  const capacity = wadToNumber(h.borrowCapacityValue);
  const liq = wadToNumber(h.liquidationValue);
  const hf = healthFactorToNumber(h.healthFactor);
  return {
    address,
    priced: h.ok,
    healthFactor: h.ok && Number.isFinite(hf) ? hf : null,
    healthFactorRaw: h.healthFactor.toString(),
    riskLevel: classifyHealthFactor(h.healthFactor, { priced: h.ok }),
    distanceToLiquidation: h.ok ? distanceToLiquidation(h.healthFactor) : null,
    totalCollateralUsd: collateral,
    totalDebtUsd: debt,
    borrowCapacityUsd: capacity,
    availableToBorrowUsd: Math.max(0, capacity - debt),
    liquidationThresholdUsd: liq,
    averageLtv: collateral > 0 ? capacity / collateral : 0,
    averageLiquidationThreshold: collateral > 0 ? liq / collateral : 0,
  };
}

export function positionsDto(p: UserPositions, markets: readonly MarketData[]): PositionDto[] {
  const byAsset = new Map(markets.map((m) => [m.asset.toLowerCase(), m]));
  return p[0].map((r) => {
    const m = byAsset.get(r.asset.toLowerCase());
    const d = Number(m?.decimals ?? 18);
    const price = m?.price ?? 0n;
    return {
      asset: r.asset,
      symbol: m?.symbol ?? "?",
      decimals: d,
      supplied: amountDto(r.supplyBalance, d, price),
      borrowed: amountDto(r.debtBalance, d, price),
      collateralEnabled: r.collateralEnabled,
      walletBalance: amountDto(r.walletBalance, d, price),
      allowance: r.allowance.toString(),
      maxBorrow: amountDto(r.maxBorrow, d, price),
      maxWithdraw: amountDto(r.maxWithdraw, d, price),
      supplyApy: m ? aprToApy(m.liquidityRate) : 0,
      borrowApy: m ? aprToApy(m.borrowRate) : 0,
    };
  });
}

/** JSON-safe conversion of anything containing bigints. */
export function jsonSafe<T>(value: T): unknown {
  return JSON.parse(JSON.stringify(value, (_k, v) => (typeof v === "bigint" ? v.toString() : v)));
}

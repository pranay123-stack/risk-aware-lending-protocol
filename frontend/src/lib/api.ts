/**
 * Typed client for the protocol API (backend/openapi.yaml). Live state comes from the chain via
 * the API; the dashboard never recomputes balances from events.
 */
import type { Address } from "viem";

export const API_URL = (process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:4400").replace(/\/$/, "");
export const WS_URL = API_URL.replace(/^http/, "ws") + "/ws";

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

export async function api<T>(path: string): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`${API_URL}${path}`, { cache: "no-store" });
  } catch {
    throw new ApiError(0, "API_UNREACHABLE", `API not reachable at ${API_URL}`);
  }
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new ApiError(res.status, body?.error?.code ?? "HTTP_ERROR", body?.error?.message ?? res.statusText);
  return body as T;
}

// ------------------------------------------------------------------ DTOs

export interface Amount {
  raw: string;
  amount: number;
  usd: number;
}

export type PriceStatus = "OK" | "OK_PRIMARY_ONLY" | "OK_FALLBACK" | "NOT_CONFIGURED" | "PAUSED" | "DEVIATION" | "UNAVAILABLE";
export type RiskLevel = "SAFE" | "WARNING" | "DANGER" | "LIQUIDATABLE" | "UNKNOWN";

export interface Market {
  asset: Address;
  symbol: string;
  decimals: number;
  price: { usd: number; raw: string; status: PriceStatus };
  totalSupplied: Amount;
  totalBorrowed: Amount;
  availableLiquidity: Amount;
  treasury: Amount;
  deficit: Amount;
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
  interestRateModel: { address: Address; baseRate: number; slope1: number; slope2: number; optimalUtilization: number };
  indexes: { liquidity: string; borrow: string };
}

export interface MarketDetail {
  market: Market;
  rateCurve: { utilization: number; borrowApr: number; supplyApr: number }[];
  rateHistory: { block_number: number; block_time: string; supply_apr: number; borrow_apr: number }[];
}

export interface Position {
  asset: Address;
  symbol: string;
  decimals: number;
  supplied: Amount;
  borrowed: Amount;
  collateralEnabled: boolean;
  walletBalance: Amount;
  allowance: string;
  maxBorrow: Amount;
  maxWithdraw: Amount;
  supplyApy: number;
  borrowApy: number;
}

export interface Health {
  address: Address;
  priced: boolean;
  healthFactor: number | null;
  healthFactorRaw: string;
  riskLevel: RiskLevel;
  distanceToLiquidation: number | null;
  totalCollateralUsd: number;
  totalDebtUsd: number;
  borrowCapacityUsd: number;
  availableToBorrowUsd: number;
  liquidationThresholdUsd: number;
  averageLtv: number;
  averageLiquidationThreshold: number;
}

export type Account = Health & { blockNumber: number; positions: Position[] };

export interface ProtocolTvl {
  tvlUsd: number;
  totalSuppliedUsd: number;
  totalBorrowedUsd: number;
  availableLiquidityUsd: number;
  treasuryUsd: number;
  deficitUsd: number;
  utilization: number;
}

export interface ProtocolStatus {
  paused: boolean;
  liquidationGracePeriodSeconds: number;
  liquidationGraceUntil: number;
  liquidationsBlockedByGrace: boolean;
  timelockDelaySeconds: number;
  blockNumber: number;
  blockTimestamp: number;
}

export interface SystemHealth {
  status: "ok" | "degraded";
  database: string;
  chain: string;
  chainHead?: number;
  indexedBlock?: number | null;
  indexerLagBlocks?: number | null;
}

export interface DeploymentConfig {
  chainId: number;
  contracts: {
    aclManager: Address;
    oracleManager: Address;
    lendingPool: Address;
    poolConfigurator: Address;
    poolLens: Address;
    timelock: Address;
  };
  markets: { symbol: string; token: Address; primaryFeed: Address; secondaryFeed: Address; interestRateModel: Address; vault: Address }[];
  guardian: Address;
  timelockProposer: Address;
}

export interface RiskSummary {
  lastSweep: string | null;
  lastSweepBlock: number | null;
  levels: Record<RiskLevel, { accounts: number; debtUsd: number; collateralUsd: number }>;
  potentialBadDebtUsd: number;
  insolventAccounts: number;
  openAlerts: Partial<Record<"info" | "warning" | "critical", number>>;
}

export interface RiskAccount {
  account: Address;
  level: RiskLevel;
  priced: boolean;
  health_factor: number | null;
  collateral_usd: number;
  debt_usd: number;
  borrow_capacity_usd: number;
  taken_at: string;
}

export interface Alert {
  id: number;
  kind: string;
  severity: "info" | "warning" | "critical";
  subject: string;
  message: string;
  opened_at: string;
  last_seen_at: string;
  resolved_at: string | null;
}

export interface MarketRisk {
  asset: Address;
  symbol: string;
  utilization: number;
  priceStatus: PriceStatus;
  priceAgeSeconds: number | null;
  heartbeatSeconds: number | null;
  findings: { kind: string; severity: string; message: string }[];
}

export interface Liquidation {
  txHash: string;
  blockNumber: number;
  blockTime: string;
  borrower: Address;
  liquidator: Address;
  receiveSupply: boolean;
  debt: { asset: Address; symbol: string; raw: string; amount: number | null; usd: number | null };
  collateral: { asset: Address; symbol: string; raw: string; amount: number | null; usd: number | null };
  liquidatorProfitUsd: number | null;
}

export type Candidate = Health & {
  positions: Position[];
  bestLiquidation: {
    collateralAsset: Address;
    collateralSymbol: string;
    debtAsset: Address;
    debtSymbol: string;
    debtToCoverRaw: string;
    debtToCover: number;
    collateralSeized: number;
    closeFactor: number;
    profitUsd: number;
  } | null;
};

export interface OracleAsset {
  asset: Address;
  symbol: string;
  status: PriceStatus;
  price: number | null;
  paused: boolean;
  maxDeviationBps: number;
  bounds: { min: number; max: number };
  primary: FeedView | null;
  secondary: FeedView | null;
}

export interface FeedView {
  address: Address;
  status: string;
  price: number | null;
  updatedAt: number;
  ageSeconds: number | null;
  heartbeatSeconds: number;
}

export interface TimelockOp {
  id: `0x${string}`;
  index: number;
  target: Address;
  value: string;
  data: `0x${string}`;
  predecessor: `0x${string}`;
  salt: `0x${string}`;
  delaySeconds: number;
  scheduledAt: number;
  readyAt: number;
  secondsUntilReady: number;
  status: "pending" | "ready" | "executed" | "cancelled";
  call: { contract: string; function: string; args: unknown[] } | null;
}

export interface Analytics {
  windowHours: number;
  totals: ProtocolTvl;
  users: number;
  markets: { asset: Address; symbol: string; suppliedUsd: number; borrowedUsd: number; utilization: number; supplyApy: number; borrowApy: number }[];
  tvlHistory: { t: string; suppliedUsd: number; borrowedUsd: number }[];
  utilizationHistory: { reserve: string; symbol: string; t: string; utilization: number }[];
  rateHistory: { reserve: string; block_number: number; block_time: string; supply_apr: number; borrow_apr: number }[];
  activity: { bucket: string; name: string; n: number }[];
  liquidations: { n: number; borrowers: number; liquidators: number };
  badDebt: { reserve: string; events: number; amount: string; covered: string; deficit_added: string }[];
}

export interface ChainEvent {
  tx_hash: string;
  log_index: number;
  block_number: number;
  block_time: string;
  name: string;
  args: Record<string, string | boolean>;
}

import { oracleManagerAbi, poolLensAbi, lendingPoolAbi, timelockAbi, type Deployment } from "@lending/shared";
import type { Address, ContractFunctionReturnType, Hex, PublicClient } from "viem";

export type MarketData = ContractFunctionReturnType<typeof poolLensAbi, "view", "getMarkets">[number];
export type UserPositions = ContractFunctionReturnType<typeof poolLensAbi, "view", "getUserPositions">;
export type AccountHealth = ContractFunctionReturnType<typeof poolLensAbi, "view", "getAccountsHealth">[number];
export type LiquidationPreview = ContractFunctionReturnType<typeof poolLensAbi, "view", "previewLiquidation">;
export type PriceState = ContractFunctionReturnType<typeof oracleManagerAbi, "view", "getPriceState">;
export type AssetOracleConfig = ContractFunctionReturnType<typeof oracleManagerAbi, "view", "getAssetConfig">;

export interface OracleView {
  asset: Address;
  symbol: string;
  state: PriceState;
  config: AssetOracleConfig;
}

/**
 * All live protocol reads go through PoolLens: one eth_call returns every market or a whole
 * account, and a broken oracle degrades a single row instead of failing the request.
 *
 * Hot, request-independent reads (markets, block) are cached for `cacheMs`, so N dashboard
 * clients cost one RPC call per interval rather than N.
 */
export class ProtocolReader {
  private cache = new Map<string, { at: number; value: Promise<unknown> }>();

  constructor(
    private readonly client: PublicClient,
    private readonly deployment: Deployment,
    private readonly cacheMs: number,
  ) {}

  private cached<T>(key: string, load: () => Promise<T>): Promise<T> {
    const hit = this.cache.get(key);
    const now = Date.now();
    if (hit && now - hit.at < this.cacheMs) return hit.value as Promise<T>;
    const value = load();
    this.cache.set(key, { at: now, value });
    value.catch(() => this.cache.delete(key)); // never cache failures
    return value;
  }

  get lens(): Address {
    return this.deployment.contracts.poolLens;
  }

  async head(): Promise<{ number: bigint; timestamp: bigint }> {
    return this.cached("head", async () => {
      const b = await this.client.getBlock({ blockTag: "latest" });
      return { number: b.number, timestamp: b.timestamp };
    });
  }

  /**
   * The timestamp the NEXT transaction will execute at. On a quiet chain (Anvil auto-mining with no
   * traffic) the latest block can be hours old, so a price that looks fresh at the head is already
   * stale for the next borrow. Staleness is judged against max(head time, wall clock).
   */
  async effectiveNow(): Promise<number> {
    const head = await this.head();
    return Math.max(Number(head.timestamp), Math.floor(Date.now() / 1000));
  }

  async markets(): Promise<readonly MarketData[]> {
    return this.cached("markets", () =>
      this.client.readContract({ address: this.lens, abi: poolLensAbi, functionName: "getMarkets" }),
    );
  }

  async userPositions(user: Address): Promise<UserPositions> {
    return this.client.readContract({ address: this.lens, abi: poolLensAbi, functionName: "getUserPositions", args: [user] });
  }

  async accountsHealth(users: Address[], chunk = 100): Promise<AccountHealth[]> {
    const out: AccountHealth[] = [];
    for (let i = 0; i < users.length; i += chunk) {
      const part = await this.client.readContract({
        address: this.lens,
        abi: poolLensAbi,
        functionName: "getAccountsHealth",
        args: [users.slice(i, i + chunk)],
      });
      out.push(...part);
    }
    return out;
  }

  async previewLiquidation(borrower: Address, collateral: Address, debt: Address, amount: bigint): Promise<LiquidationPreview> {
    return this.client.readContract({
      address: this.lens,
      abi: poolLensAbi,
      functionName: "previewLiquidation",
      args: [borrower, collateral, debt, amount],
    });
  }

  async oracles(): Promise<OracleView[]> {
    return this.cached("oracles", () =>
      Promise.all(
        this.deployment.markets.map(async (m) => {
          const [state, config] = await Promise.all([
            this.client.readContract({ address: this.deployment.contracts.oracleManager, abi: oracleManagerAbi, functionName: "getPriceState", args: [m.token] }),
            this.client.readContract({ address: this.deployment.contracts.oracleManager, abi: oracleManagerAbi, functionName: "getAssetConfig", args: [m.token] }),
          ]);
          return { asset: m.token, symbol: m.symbol, state, config };
        }),
      ),
    );
  }

  async poolStatus(): Promise<{ paused: boolean; graceUntil: bigint; gracePeriod: bigint }> {
    return this.cached("poolStatus", async () => {
      const pool = this.deployment.contracts.lendingPool;
      const [paused, graceUntil, gracePeriod] = await Promise.all([
        this.client.readContract({ address: pool, abi: lendingPoolAbi, functionName: "paused" }),
        this.client.readContract({ address: pool, abi: lendingPoolAbi, functionName: "liquidationGraceUntil" }),
        this.client.readContract({ address: pool, abi: lendingPoolAbi, functionName: "liquidationGracePeriod" }),
      ]);
      return { paused, graceUntil, gracePeriod };
    });
  }

  async timelockDelay(): Promise<bigint> {
    return this.cached("tlDelay", () =>
      this.client.readContract({ address: this.deployment.contracts.timelock, abi: timelockAbi, functionName: "getMinDelay" }),
    );
  }

  /** 0 = unset, 1 = done, otherwise the ready-at timestamp. */
  async timelockTimestamp(opId: Hex): Promise<bigint> {
    return this.client.readContract({ address: this.deployment.contracts.timelock, abi: timelockAbi, functionName: "getTimestamp", args: [opId] });
  }
}

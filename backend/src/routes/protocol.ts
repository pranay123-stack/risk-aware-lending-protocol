import type { FastifyInstance } from "fastify";
import type { AppContext } from "../context.js";
import { marketDto, type MarketDto } from "../dto.js";

export interface ProtocolTotals {
  totalSuppliedUsd: number;
  totalBorrowedUsd: number;
  availableLiquidityUsd: number;
  treasuryUsd: number;
  deficitUsd: number;
  utilization: number;
}

/** Protocol-wide totals from per-market figures (markets with no valid price contribute 0). */
export function totals(markets: MarketDto[]): ProtocolTotals {
  const sum = (f: (m: MarketDto) => number) => markets.reduce((s, m) => s + f(m), 0);
  const supplied = sum((m) => m.totalSupplied.usd);
  const borrowed = sum((m) => m.totalBorrowed.usd);
  return {
    totalSuppliedUsd: supplied,
    totalBorrowedUsd: borrowed,
    availableLiquidityUsd: sum((m) => m.availableLiquidity.usd),
    treasuryUsd: sum((m) => m.treasury.usd),
    deficitUsd: sum((m) => m.deficit.usd),
    utilization: supplied > 0 ? borrowed / supplied : 0,
  };
}

export function registerProtocolRoutes(app: FastifyInstance, ctx: AppContext) {
  const markets = async () => (await ctx.reader.markets()).map(marketDto);

  /**
   * TVL here = total value supplied (collateral + lendable liquidity). DefiLlama-style "TVL"
   * (supplied minus borrowed) is returned as availableLiquidityUsd.
   */
  app.get("/protocol/tvl", async () => {
    const m = await markets();
    const t = totals(m);
    return {
      tvlUsd: t.totalSuppliedUsd,
      ...t,
      markets: m.map((x) => ({ asset: x.asset, symbol: x.symbol, suppliedUsd: x.totalSupplied.usd, borrowedUsd: x.totalBorrowed.usd })),
    };
  });

  app.get("/protocol/utilization", async () => {
    const m = await markets();
    return {
      aggregate: totals(m).utilization,
      markets: m.map((x) => ({ asset: x.asset, symbol: x.symbol, utilization: x.utilization, optimalUtilization: x.interestRateModel.optimalUtilization })),
    };
  });

  app.get("/protocol/borrow-rate", async () => {
    const m = await markets();
    return { markets: m.map((x) => ({ asset: x.asset, symbol: x.symbol, borrowApr: x.borrowApr, borrowApy: x.borrowApy, utilization: x.utilization })) };
  });

  app.get("/protocol/supply-rate", async () => {
    const m = await markets();
    return { markets: m.map((x) => ({ asset: x.asset, symbol: x.symbol, supplyApr: x.supplyApr, supplyApy: x.supplyApy, utilization: x.utilization })) };
  });

  app.get("/protocol/status", async () => {
    const [s, head, delay] = await Promise.all([ctx.reader.poolStatus(), ctx.reader.head(), ctx.reader.timelockDelay()]);
    return {
      paused: s.paused,
      liquidationGracePeriodSeconds: Number(s.gracePeriod),
      liquidationGraceUntil: Number(s.graceUntil),
      liquidationsBlockedByGrace: Number(s.graceUntil) > Number(head.timestamp),
      timelockDelaySeconds: Number(delay),
      blockNumber: Number(head.number),
      blockTimestamp: Number(head.timestamp),
    };
  });
}

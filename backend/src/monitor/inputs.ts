import type { MarketRiskInput } from "@lending/shared";
import type { AppContext } from "../context.js";
import { priceStatusName } from "../dto.js";

/** Live market risk inputs: lens market data joined with oracle feed ages and heartbeats. */
export async function marketRiskInputs(ctx: AppContext, previous?: Map<string, bigint>): Promise<MarketRiskInput[]> {
  const [markets, oracles, now] = await Promise.all([ctx.reader.markets(), ctx.reader.oracles(), ctx.reader.effectiveNow()]);
  const byAsset = new Map(oracles.map((o) => [o.asset.toLowerCase(), o]));
  return markets.map((m) => {
    const o = byAsset.get(m.asset.toLowerCase());
    const updatedAt = o ? Number(o.state.primaryUpdatedAt) : 0;
    const prev = previous?.get(m.asset.toLowerCase());
    return {
      reserve: m.asset,
      symbol: m.symbol,
      utilizationRay: m.utilization,
      cash: m.cash,
      totalSupplied: m.totalSupplied,
      deficit: m.deficit,
      priceStatus: priceStatusName(m.priceStatus),
      ...(updatedAt > 0 ? { priceAgeSeconds: Math.max(0, now - updatedAt) } : {}),
      ...(o ? { heartbeatSeconds: Number(o.config.primaryHeartbeat) } : {}),
      ...(prev !== undefined ? { previousUtilizationRay: prev } : {}),
    };
  });
}

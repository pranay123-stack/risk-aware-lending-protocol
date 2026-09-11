import { impliedSupplyRate, kinkedBorrowRate, rayToNumber, RAY } from "@lending/shared";
import type { FastifyInstance } from "fastify";
import type { AppContext } from "../context.js";
import { marketDto } from "../dto.js";
import { HttpError, parseAddress } from "../http.js";

export function registerMarketRoutes(app: FastifyInstance, ctx: AppContext) {
  app.get("/markets", async () => {
    const markets = await ctx.reader.markets();
    return { markets: markets.map(marketDto) };
  });

  app.get<{ Params: { asset: string } }>("/markets/:asset", async (req) => {
    const asset = parseAddress(req.params.asset, "asset");
    const m = (await ctx.reader.markets()).find((x) => x.asset.toLowerCase() === asset.toLowerCase());
    if (!m) throw new HttpError(404, "MARKET_NOT_FOUND", `no market for ${asset}`);

    // Rate curve from the live model parameters, for the utilization/APR chart.
    const params = { baseRate: m.baseRate, slope1: m.slope1, slope2: m.slope2, optimalUtilization: m.optimalUtilization };
    const curve = Array.from({ length: 21 }, (_, i) => {
      const u = (BigInt(i * 5) * RAY) / 100n;
      const borrow = kinkedBorrowRate(u, params);
      return {
        utilization: i * 5 / 100,
        borrowApr: rayToNumber(borrow),
        supplyApr: rayToNumber(impliedSupplyRate(borrow, u, BigInt(m.config.reserveFactor))),
      };
    });

    const history = await ctx.db.query(
      `SELECT block_number, block_time,
              (liquidity_rate / 1e27)::float8 AS supply_apr,
              (borrow_rate / 1e27)::float8 AS borrow_apr,
              liquidity_index::text, borrow_index::text
       FROM reserve_updates WHERE reserve = $1
       ORDER BY block_number DESC, log_index DESC LIMIT 200`,
      [asset.toLowerCase()],
    );

    return { market: marketDto(m), rateCurve: curve, rateHistory: history.rows.reverse() };
  });
}

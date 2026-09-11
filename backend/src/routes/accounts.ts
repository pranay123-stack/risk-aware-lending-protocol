import type { FastifyInstance } from "fastify";
import type { AppContext } from "../context.js";
import { healthDto, positionsDto } from "../dto.js";
import { parseAddress, parseLimit, parseOffset } from "../http.js";

/**
 * Account state is always read live from the chain (PoolLens), never reconstructed from indexed
 * events: interest accrues every second, and a replayed ledger would drift from the truth.
 * History, in contrast, comes from the database.
 */
export function registerAccountRoutes(app: FastifyInstance, ctx: AppContext) {
  app.get<{ Params: { address: string } }>("/accounts/:address", async (req) => {
    const address = parseAddress(req.params.address);
    const [p, markets, head] = await Promise.all([ctx.reader.userPositions(address), ctx.reader.markets(), ctx.reader.head()]);
    const positions = positionsDto(p, markets).filter(
      (x) => x.supplied.raw !== "0" || x.borrowed.raw !== "0",
    );
    return { blockNumber: Number(head.number), ...healthDto(address, p[1]), positions };
  });

  app.get<{ Params: { address: string } }>("/accounts/:address/positions", async (req) => {
    const address = parseAddress(req.params.address);
    const [p, markets] = await Promise.all([ctx.reader.userPositions(address), ctx.reader.markets()]);
    return { address, positions: positionsDto(p, markets) };
  });

  app.get<{ Params: { address: string } }>("/accounts/:address/health-factor", async (req) => {
    const address = parseAddress(req.params.address);
    const [p, head] = await Promise.all([ctx.reader.userPositions(address), ctx.reader.head()]);
    const h = healthDto(address, p[1]);
    return {
      address,
      blockNumber: Number(head.number),
      priced: h.priced,
      healthFactor: h.healthFactor,
      healthFactorRaw: h.healthFactorRaw,
      riskLevel: h.riskLevel,
      distanceToLiquidation: h.distanceToLiquidation,
    };
  });

  app.get<{ Params: { address: string }; Querystring: { limit?: string; offset?: string } }>(
    "/accounts/:address/history",
    async (req) => {
      const address = parseAddress(req.params.address).toLowerCase();
      const limit = parseLimit(req.query.limit);
      const offset = parseOffset(req.query.offset);
      // Every event where the account is the user, borrower, liquidator, repayer or caller.
      const res = await ctx.db.query(
        `SELECT tx_hash, log_index, block_number, block_time, name, args
         FROM events
         WHERE source = 'pool' AND (
           args->>'user' = $1 OR args->>'onBehalfOf' = $1 OR args->>'caller' = $1 OR
           args->>'borrower' = $1 OR args->>'liquidator' = $1 OR args->>'repayer' = $1)
           AND name <> 'ReserveDataUpdated'
         ORDER BY block_number DESC, log_index DESC
         LIMIT $2 OFFSET $3`,
        [address, limit, offset],
      );
      return { address, events: res.rows };
    },
  );
}

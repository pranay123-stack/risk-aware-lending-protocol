import { wadToNumber } from "@lending/shared";
import type { FastifyInstance } from "fastify";
import { zeroAddress } from "viem";
import type { AppContext } from "../context.js";
import { priceStatusName } from "../dto.js";

const FEED_STATUS = ["NOT_CONFIGURED", "OK", "CALL_FAILED", "INVALID_ANSWER", "INCOMPLETE_ROUND", "FUTURE_TIMESTAMP", "STALE", "OUT_OF_BOUNDS"] as const;

export function registerOracleRoutes(app: FastifyInstance, ctx: AppContext) {
  /** Full oracle picture per asset: resolved price, each feed's health, age vs heartbeat, bounds. */
  app.get("/oracle/prices", async () => {
    const [oracles, head, now] = await Promise.all([ctx.reader.oracles(), ctx.reader.head(), ctx.reader.effectiveNow()]);
    return {
      blockTimestamp: Number(head.timestamp),
      // Ages are measured against what the next transaction will see (see ProtocolReader.effectiveNow).
      evaluatedAt: now,
      assets: oracles.map((o) => {
        const s = o.state;
        const c = o.config;
        const feed = (address: string, status: number, price: bigint, updatedAt: bigint, heartbeat: number) =>
          address === zeroAddress
            ? null
            : {
                address,
                status: FEED_STATUS[status] ?? "UNKNOWN",
                price: price === 0n ? null : wadToNumber(price),
                updatedAt: Number(updatedAt),
                ageSeconds: updatedAt > 0n ? Math.max(0, now - Number(updatedAt)) : null,
                heartbeatSeconds: heartbeat,
              };
        return {
          asset: o.asset,
          symbol: o.symbol,
          status: priceStatusName(s.status),
          price: s.price === 0n ? null : wadToNumber(s.price),
          priceRaw: s.price.toString(),
          paused: c.paused,
          maxDeviationBps: Number(c.maxDeviationBps),
          bounds: { min: wadToNumber(c.minPrice), max: wadToNumber(c.maxPrice) },
          primary: feed(c.primaryFeed, s.primaryStatus, s.primaryPrice, s.primaryUpdatedAt, Number(c.primaryHeartbeat)),
          secondary: feed(c.secondaryFeed, s.secondaryStatus, s.secondaryPrice, s.secondaryUpdatedAt, Number(c.secondaryHeartbeat)),
        };
      }),
    };
  });

  app.get<{ Querystring: { asset?: string } }>("/oracle/history", async (req) => {
    const asset = req.query.asset?.toLowerCase() ?? null;
    const res = await ctx.db.query(
      `SELECT asset, feed_role, answer::text, round_id::text, updated_at, block_number, block_time
       FROM price_updates WHERE ($1::text IS NULL OR asset = $1)
       ORDER BY block_number DESC, log_index DESC LIMIT 500`,
      [asset],
    );
    return { updates: res.rows };
  });
}

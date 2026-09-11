import type { FastifyInstance } from "fastify";
import type { AppContext } from "../context.js";
import { marketDto } from "../dto.js";
import { totals } from "./protocol.js";

export function registerAnalyticsRoutes(app: FastifyInstance, ctx: AppContext) {
  /**
   * One call for the analytics page: live totals plus history from two sources:
   *   - monitor snapshots (TVL / borrows over wall-clock time)
   *   - indexed events (rates per reserve update, activity per day, liquidations, bad debt)
   */
  app.get<{ Querystring: { hours?: string } }>("/analytics", async (req) => {
    const hours = Math.min(Math.max(Number(req.query.hours ?? 24) || 24, 1), 24 * 30);
    const markets = (await ctx.reader.markets()).map(marketDto);

    const [tvl, rates, activity, liq, badDebt, users, utilization] = await Promise.all([
      ctx.db.query(
        `SELECT taken_at AS t, sum(supplied_usd) AS supplied_usd, sum(borrowed_usd) AS borrowed_usd
         FROM market_snapshots WHERE taken_at > now() - make_interval(hours => $1)
         GROUP BY taken_at ORDER BY taken_at`,
        [hours],
      ),
      ctx.db.query(
        `SELECT reserve, block_number, block_time,
                (liquidity_rate / 1e27)::float8 AS supply_apr, (borrow_rate / 1e27)::float8 AS borrow_apr
         FROM (SELECT *, row_number() OVER (PARTITION BY reserve ORDER BY block_number DESC, log_index DESC) AS rn
               FROM reserve_updates) r
         WHERE rn <= 100 ORDER BY block_number, log_index`,
      ),
      ctx.db.query(
        `SELECT date_trunc('hour', block_time) AS bucket, name, count(*)::int AS n
         FROM events WHERE source = 'pool' AND name IN ('Supply','Withdraw','Borrow','Repay','LiquidationCall')
           AND block_time > now() - make_interval(hours => $1)
         GROUP BY 1, 2 ORDER BY 1`,
        [hours],
      ),
      ctx.db.query(`SELECT count(*)::int AS n, count(DISTINCT borrower)::int AS borrowers, count(DISTINCT liquidator)::int AS liquidators FROM liquidations`),
      ctx.db.query(
        `SELECT reserve, count(*)::int AS events, sum(amount)::text AS amount, sum(covered_by_treasury)::text AS covered,
                sum(deficit_added)::text AS deficit_added
         FROM bad_debt_events GROUP BY reserve`,
      ),
      ctx.db.query(`SELECT count(*)::int AS n FROM accounts`),
      ctx.db.query(
        `SELECT reserve, symbol, taken_at AS t, (utilization / 1e27)::float8 AS utilization
         FROM market_snapshots WHERE taken_at > now() - make_interval(hours => $1) ORDER BY taken_at`,
        [hours],
      ),
    ]);

    return {
      windowHours: hours,
      totals: totals(markets),
      users: users.rows[0].n,
      markets: markets.map((m) => ({
        asset: m.asset,
        symbol: m.symbol,
        suppliedUsd: m.totalSupplied.usd,
        borrowedUsd: m.totalBorrowed.usd,
        utilization: m.utilization,
        supplyApy: m.supplyApy,
        borrowApy: m.borrowApy,
      })),
      tvlHistory: tvl.rows.map((r) => ({ t: r.t, suppliedUsd: Number(r.supplied_usd), borrowedUsd: Number(r.borrowed_usd) })),
      utilizationHistory: utilization.rows,
      rateHistory: rates.rows,
      activity: activity.rows,
      liquidations: liq.rows[0],
      badDebt: badDebt.rows,
    };
  });
}

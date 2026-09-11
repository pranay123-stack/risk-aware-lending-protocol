import { RISK_LEVELS, evaluateMarket, type RiskLevel } from "@lending/shared";
import type { FastifyInstance } from "fastify";
import type { AppContext } from "../context.js";
import { HttpError, parseLimit } from "../http.js";
import { marketRiskInputs } from "../monitor/inputs.js";

export function registerRiskRoutes(app: FastifyInstance, ctx: AppContext) {
  /** Counts per level and the debt at risk, from the monitor's latest sweep. */
  app.get("/risk/summary", async () => {
    const [levels, sweep, alerts] = await Promise.all([
      ctx.db.query(
        `SELECT level, count(*)::int AS accounts, coalesce(sum(debt_usd), 0)::float8 AS debt_usd,
                coalesce(sum(collateral_usd), 0)::float8 AS collateral_usd
         FROM account_risk_latest GROUP BY level`,
      ),
      ctx.db.query(`SELECT max(taken_at) AS at, max(block_number) AS block FROM risk_snapshots`),
      ctx.db.query(`SELECT severity, count(*)::int AS n FROM alerts WHERE resolved_at IS NULL GROUP BY severity`),
    ]);
    const byLevel = Object.fromEntries(RISK_LEVELS.map((l) => [l, { accounts: 0, debtUsd: 0, collateralUsd: 0 }]));
    for (const r of levels.rows) byLevel[r.level] = { accounts: r.accounts, debtUsd: r.debt_usd, collateralUsd: r.collateral_usd };
    const badDebt = await ctx.db.query(
      `SELECT coalesce(sum(debt_usd - collateral_usd), 0)::float8 AS shortfall, count(*)::int AS n
       FROM account_risk_latest WHERE priced AND debt_usd > collateral_usd`,
    );
    return {
      lastSweep: sweep.rows[0].at,
      lastSweepBlock: sweep.rows[0].block,
      levels: byLevel,
      potentialBadDebtUsd: badDebt.rows[0].shortfall,
      insolventAccounts: badDebt.rows[0].n,
      openAlerts: Object.fromEntries(alerts.rows.map((r) => [r.severity, r.n])),
    };
  });

  app.get<{ Querystring: { level?: string; limit?: string } }>("/risk/accounts", async (req) => {
    const level = req.query.level?.toUpperCase();
    if (level && !RISK_LEVELS.includes(level as RiskLevel)) {
      throw new HttpError(400, "INVALID_LEVEL", `level must be one of ${RISK_LEVELS.join(", ")}`);
    }
    const res = await ctx.db.query(
      `SELECT account, level, priced, health_factor::text AS health_factor_raw,
              (health_factor / 1e18)::float8 AS health_factor,
              collateral_usd, debt_usd, borrow_capacity_usd, taken_at, block_number
       FROM account_risk_latest
       WHERE ($1::text IS NULL OR level = $1) AND (debt_usd > 0 OR level = 'UNKNOWN')
       ORDER BY health_factor ASC NULLS FIRST
       LIMIT $2`,
      [level ?? null, parseLimit(req.query.limit, 100, 1000)],
    );
    return { accounts: res.rows };
  });

  app.get<{ Querystring: { status?: string; limit?: string } }>("/risk/alerts", async (req) => {
    const status = req.query.status ?? "open";
    if (!["open", "resolved", "all"].includes(status)) throw new HttpError(400, "INVALID_STATUS", "status must be open, resolved or all");
    const res = await ctx.db.query(
      `SELECT id, kind, severity, subject, message, data, opened_at, last_seen_at, resolved_at
       FROM alerts
       WHERE ($1 = 'all') OR ($1 = 'open' AND resolved_at IS NULL) OR ($1 = 'resolved' AND resolved_at IS NOT NULL)
       ORDER BY resolved_at IS NULL DESC,
                CASE severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END,
                last_seen_at DESC
       LIMIT $2`,
      [status, parseLimit(req.query.limit, 100, 1000)],
    );
    return { alerts: res.rows };
  });

  /** Market risk evaluated live (same rules as the monitor). */
  app.get("/risk/markets", async () => {
    const inputs = await marketRiskInputs(ctx);
    return {
      markets: inputs.map((i) => ({
        asset: i.reserve,
        symbol: i.symbol,
        utilization: Number(i.utilizationRay) / 1e27,
        priceStatus: i.priceStatus,
        priceAgeSeconds: i.priceAgeSeconds ?? null,
        heartbeatSeconds: i.heartbeatSeconds ?? null,
        findings: evaluateMarket(i),
      })),
    };
  });
}

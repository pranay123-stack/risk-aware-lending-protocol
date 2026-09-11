import {
  DEFAULT_ACCOUNT_RISK_CONFIG,
  DEFAULT_MARKET_RISK_CONFIG,
  evaluateAccount,
  evaluateMarket,
  usdValue,
  wadToNumber,
  type AccountRiskConfig,
  type Finding,
  type MarketRiskConfig,
  type RiskLevel,
} from "@lending/shared";
import { withTransaction } from "@lending/shared/node";
import { getAddress, type Address } from "viem";
import type { AppContext } from "../context.js";
import { priceStatusName } from "../dto.js";
import { marketRiskInputs } from "./inputs.js";

export interface MonitorOptions {
  marketSnapshotEveryMs: number;
  accountRisk: AccountRiskConfig;
  marketRisk: MarketRiskConfig;
  notifyChannel: string;
}

export const DEFAULT_MONITOR_OPTIONS: MonitorOptions = {
  marketSnapshotEveryMs: 30_000,
  accountRisk: DEFAULT_ACCOUNT_RISK_CONFIG,
  marketRisk: DEFAULT_MARKET_RISK_CONFIG,
  notifyChannel: "risk_alerts",
};

export interface SweepReport {
  blockNumber: number;
  accounts: number;
  levels: Record<RiskLevel, number>;
  findings: number;
  opened: number;
  resolved: number;
  marketSnapshot: boolean;
}

/**
 * Periodic risk sweep:
 *  1. market findings (utilization, liquidity, oracle health, bad debt), snapshots for history
 *  2. every account ever seen by the indexer, valued live via PoolLens.getAccountsHealth
 *     (one call per 100 accounts; an unpriceable account is reported, not fatal)
 *  3. alert reconciliation: open new findings, refresh persisting ones, resolve cleared ones.
 *     Changes are published on `risk_alerts` for the API's WebSocket clients.
 */
export class RiskMonitor {
  private lastMarketSnapshot = 0;
  private previousUtilization = new Map<string, bigint>();

  constructor(
    private readonly ctx: AppContext,
    private readonly opts: MonitorOptions = DEFAULT_MONITOR_OPTIONS,
  ) {}

  async sweep(now = Date.now()): Promise<SweepReport> {
    const { db, reader } = this.ctx;
    const [head, markets] = await Promise.all([reader.head(), reader.markets()]);
    const blockNumber = Number(head.number);

    // ---------------------------------------------------------------- markets
    const inputs = await marketRiskInputs(this.ctx, this.previousUtilization);
    const findings: Finding[] = inputs.flatMap((i) => evaluateMarket(i, this.opts.marketRisk));
    const protocolBorrowsUsd = markets.reduce((s, m) => s + usdValue(m.totalBorrowed, Number(m.decimals), m.price), 0);

    const takeSnapshot = now - this.lastMarketSnapshot >= this.opts.marketSnapshotEveryMs;
    if (takeSnapshot) {
      const takenAt = new Date(now).toISOString();
      for (const m of markets) {
        const d = Number(m.decimals);
        await db.query(
          `INSERT INTO market_snapshots (taken_at, block_number, reserve, symbol, decimals, price, price_status,
             total_supplied, total_borrowed, cash, utilization, liquidity_rate, borrow_rate, treasury, deficit,
             supplied_usd, borrowed_usd)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17)`,
          [
            takenAt, blockNumber, m.asset.toLowerCase(), m.symbol, d, m.price.toString(), priceStatusName(m.priceStatus),
            m.totalSupplied.toString(), m.totalBorrowed.toString(), m.cash.toString(), m.utilization.toString(),
            m.liquidityRate.toString(), m.borrowRate.toString(), m.treasury.toString(), m.deficit.toString(),
            usdValue(m.totalSupplied, d, m.price), usdValue(m.totalBorrowed, d, m.price),
          ],
        );
      }
      this.lastMarketSnapshot = now;
      // Utilization jumps are measured between snapshots, not between sweeps.
      this.previousUtilization = new Map(markets.map((m) => [m.asset.toLowerCase(), m.utilization]));
    }

    // ---------------------------------------------------------------- accounts
    const accounts = (await db.query<{ address: string }>("SELECT address FROM accounts")).rows.map(
      (r) => getAddress(r.address) as Address,
    );
    const health = accounts.length ? await reader.accountsHealth(accounts) : [];
    const levels = { SAFE: 0, WARNING: 0, DANGER: 0, LIQUIDATABLE: 0, UNKNOWN: 0 } as Record<RiskLevel, number>;
    const rows: unknown[][] = [[], [], [], [], [], [], [], []];
    for (const h of health) {
      const collateralUsd = wadToNumber(h.totalCollateralValue);
      const debtUsd = wadToNumber(h.totalDebtValue);
      const r = evaluateAccount(
        { account: h.user.toLowerCase(), priced: h.ok, healthFactor: h.healthFactor, collateralUsd, debtUsd },
        protocolBorrowsUsd,
        this.opts.accountRisk,
      );
      levels[r.level]++;
      findings.push(...r.findings);
      const noDebt = h.ok && h.totalDebtValue === 0n;
      rows[0]!.push(h.user.toLowerCase());
      rows[1]!.push(h.ok);
      // NULL health factor = no debt (infinite) or unpriceable; `level` disambiguates.
      rows[2]!.push(h.ok && !noDebt ? h.healthFactor.toString() : null);
      rows[3]!.push(collateralUsd);
      rows[4]!.push(debtUsd);
      rows[5]!.push(wadToNumber(h.borrowCapacityValue));
      rows[6]!.push(r.level);
      rows[7]!.push(blockNumber);
    }

    // ---------------------------------------------------------------- persist + alerts
    const { opened, resolved } = await withTransaction(db, async (client) => {
      if (rows[0]!.length) {
        await client.query(
          `INSERT INTO risk_snapshots (account, priced, health_factor, collateral_usd, debt_usd, borrow_capacity_usd, level, block_number)
           SELECT * FROM unnest($1::text[], $2::bool[], $3::numeric[], $4::float8[], $5::float8[], $6::float8[], $7::text[], $8::bigint[])`,
          rows,
        );
      }

      const openedAlerts: unknown[] = [];
      for (const f of findings) {
        const res = await client.query(
          `INSERT INTO alerts (kind, severity, subject, message, data)
           VALUES ($1, $2, $3, $4, $5)
           ON CONFLICT (kind, subject) WHERE resolved_at IS NULL
           DO UPDATE SET severity = EXCLUDED.severity, message = EXCLUDED.message, data = EXCLUDED.data, last_seen_at = now()
           RETURNING id, (xmax = 0) AS inserted`,
          [f.kind, f.severity, f.subject.toLowerCase(), f.message, JSON.stringify(f.data)],
        );
        if (res.rows[0]?.inserted) openedAlerts.push({ id: res.rows[0].id, ...f });
      }

      const keys = findings.map((f) => `${f.kind}|${f.subject.toLowerCase()}`);
      const resolvedRes = await client.query(
        `UPDATE alerts SET resolved_at = now()
         WHERE resolved_at IS NULL AND NOT ((kind || '|' || subject) = ANY($1::text[]))
         RETURNING id, kind, subject, message`,
        [keys],
      );

      if (openedAlerts.length || resolvedRes.rowCount) {
        const payload = JSON.stringify({
          type: "alerts",
          opened: openedAlerts.slice(0, 20),
          resolved: resolvedRes.rows.slice(0, 20),
          levels,
        });
        await client.query("SELECT pg_notify($1, $2)", [this.opts.notifyChannel, payload.slice(0, 7_900)]);
      }
      return { opened: openedAlerts.length, resolved: resolvedRes.rowCount ?? 0 };
    });

    return { blockNumber, accounts: health.length, levels, findings: findings.length, opened, resolved, marketSnapshot: takeSnapshot };
  }
}

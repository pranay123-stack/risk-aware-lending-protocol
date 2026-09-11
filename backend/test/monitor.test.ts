import { MAX_UINT256, RAY, WAD } from "@lending/shared";
import type { Db } from "@lending/shared/node";
import pg from "pg";
import type { Address } from "viem";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import type { AccountHealth, MarketData, OracleView } from "../src/chain/reader.js";
import { DEFAULT_MONITOR_OPTIONS, RiskMonitor } from "../src/monitor/monitor.js";
import { TEST_DB_URL, addr, fakeDeployment, freshDb, stubContext } from "./fixtures.js";

const deployment = fakeDeployment();
const USDC = deployment.markets[1]!.token;
const bob = addr("bob");

/** Scripted chain state the monitor will observe. */
class ScriptedReader {
  now = 1_700_000_000n;
  utilization = (60n * RAY) / 100n;
  cash = 400_000n * 10n ** 6n;
  deficit = 0n;
  bobHf = (15n * WAD) / 10n;
  bobCollateral = 18_000n * WAD;
  bobDebt = 12_000n * WAD;

  async head() {
    return { number: 100n, timestamp: this.now };
  }
  async effectiveNow() {
    return Number(this.now);
  }
  async markets(): Promise<readonly MarketData[]> {
    return [
      {
        asset: USDC,
        symbol: "USDC",
        decimals: 6,
        price: WAD,
        priceStatus: 0,
        totalSupplied: 1_000_000n * 10n ** 6n,
        totalBorrowed: 600_000n * 10n ** 6n,
        cash: this.cash,
        utilization: this.utilization,
        liquidityRate: 0n,
        borrowRate: 0n,
        treasury: 0n,
        deficit: this.deficit,
      } as unknown as MarketData,
    ];
  }
  async oracles(): Promise<OracleView[]> {
    return [
      {
        asset: USDC,
        symbol: "USDC",
        state: { primaryUpdatedAt: this.now - 60n } as OracleView["state"],
        config: { primaryHeartbeat: 86_400 } as unknown as OracleView["config"],
      },
    ];
  }
  async accountsHealth(users: Address[]): Promise<AccountHealth[]> {
    return users.map((u) => ({
      user: u,
      ok: true,
      totalCollateralValue: u === bob ? this.bobCollateral : 0n,
      totalDebtValue: u === bob ? this.bobDebt : 0n,
      borrowCapacityValue: 0n,
      liquidationValue: 0n,
      healthFactor: u === bob ? this.bobHf : MAX_UINT256,
    }));
  }
}

let db: Db;

beforeEach(async () => {
  db = await freshDb();
  // The monitor sweeps accounts derived from indexed events: seed one Supply by bob.
  await db.query(`INSERT INTO blocks VALUES (1, '0x01', '0x00', now())`);
  await db.query(
    `INSERT INTO supplies VALUES ('0xaa', 0, 1, now(), $1, $2, $2, 1)`,
    [USDC.toLowerCase(), bob.toLowerCase()],
  );
});

afterAll(async () => {
  await db?.end();
});

async function openAlerts() {
  return (await db.query(`SELECT kind, severity, subject FROM alerts WHERE resolved_at IS NULL ORDER BY kind`)).rows;
}

describe("risk monitor", () => {
  it("snapshots markets and accounts, opens alerts once, resolves them when cleared", async () => {
    const reader = new ScriptedReader();
    const monitor = new RiskMonitor(stubContext(db, reader as never, deployment), { ...DEFAULT_MONITOR_OPTIONS, marketSnapshotEveryMs: 0 });

    // healthy
    let r = await monitor.sweep(1);
    expect(r.levels.SAFE).toBe(1);
    expect(await openAlerts()).toEqual([]);
    expect(Number((await db.query("SELECT count(*) FROM market_snapshots")).rows[0].count)).toBe(1);

    // bob drifts to HF 0.95 with collateral < debt; USDC utilization spikes to 98%
    reader.bobHf = (95n * WAD) / 100n;
    reader.bobCollateral = 11_000n * WAD;
    reader.utilization = (98n * RAY) / 100n;
    reader.cash = 20_000n * 10n ** 6n;
    r = await monitor.sweep(2);
    expect(r.levels.LIQUIDATABLE).toBe(1);
    const kinds = (await openAlerts()).map((a) => a.kind);
    expect(kinds).toEqual(["ABNORMAL_UTILIZATION", "HIGH_UTILIZATION", "LIQUIDATABLE", "LOW_LIQUIDITY", "POTENTIAL_BAD_DEBT"]);

    // same state again: alerts are refreshed, not duplicated
    r = await monitor.sweep(3);
    expect(r.opened).toBe(0);
    expect((await db.query("SELECT count(*)::int AS n FROM alerts")).rows[0].n).toBe(5);

    // conditions clear: every alert resolves
    reader.bobHf = 2n * WAD;
    reader.bobCollateral = 30_000n * WAD;
    reader.utilization = (60n * RAY) / 100n;
    reader.cash = 400_000n * 10n ** 6n;
    await monitor.sweep(4); // utilization jump back is itself abnormal
    await monitor.sweep(5);
    expect(await openAlerts()).toEqual([]);
    expect((await db.query("SELECT count(*)::int AS n FROM alerts WHERE resolved_at IS NOT NULL")).rows[0].n).toBeGreaterThanOrEqual(5);
  });

  it("stores health factors exactly and NULL for debt-free accounts", async () => {
    const reader = new ScriptedReader();
    await db.query(`INSERT INTO supplies VALUES ('0xbb', 0, 1, now(), $1, $2, $2, 1)`, [USDC.toLowerCase(), addr("alice").toLowerCase()]);
    const monitor = new RiskMonitor(stubContext(db, reader as never, deployment));
    await monitor.sweep(1);
    const rows = (await db.query(`SELECT account, health_factor::text AS hf, level FROM account_risk_latest ORDER BY account`)).rows;
    const byAccount = Object.fromEntries(rows.map((x) => [x.account, x]));
    expect(byAccount[bob.toLowerCase()]).toMatchObject({ hf: "1500000000000000000", level: "SAFE" });
    expect(byAccount[addr("alice").toLowerCase()]).toMatchObject({ hf: null, level: "SAFE" });
  });

  it("publishes alert changes on the risk_alerts channel", async () => {
    const listener = new pg.Client({ connectionString: TEST_DB_URL });
    await listener.connect();
    const got: unknown[] = [];
    listener.on("notification", (n) => got.push(JSON.parse(n.payload ?? "{}")));
    await listener.query("LISTEN risk_alerts");

    const reader = new ScriptedReader();
    reader.deficit = 5n;
    await new RiskMonitor(stubContext(db, reader as never, deployment)).sweep(1);
    await new Promise((r) => setTimeout(r, 100));
    await listener.end();
    expect(got).toHaveLength(1);
    expect(got[0]).toMatchObject({ type: "alerts", opened: [{ kind: "BAD_DEBT", severity: "critical" }] });
  });
});

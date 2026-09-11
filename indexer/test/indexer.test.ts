import {
  lendingPoolAbi,
  mockAggregatorAbi,
  parseDeployment,
  timelockAbi,
  type Deployment,
} from "@lending/shared";
import { createDb, createLogger, migrate, type Db } from "@lending/shared/node";
import { getEventListeners } from "node:events";
import pg from "pg";
import { getAddress, keccak256, toHex, type Address } from "viem";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { Indexer, type IndexerOptions } from "../src/indexer.js";
import { FakeChain } from "./fakeChain.js";

const DB_URL = process.env.DATABASE_URL_TEST ?? "postgres://lending:lending@127.0.0.1:5475/lending_test";
const addr = (label: string) => getAddress(keccak256(toHex(label)).slice(0, 42)) as Address;

function makeDeployment(label = "v1"): Deployment {
  const m = (sym: string, secondary = false) => ({
    symbol: sym,
    token: addr(`${label}:${sym}:token`),
    primaryFeed: addr(`${label}:${sym}:feed`),
    secondaryFeed: secondary ? addr(`${label}:${sym}:feed2`) : "0x0000000000000000000000000000000000000000",
    interestRateModel: addr(`${label}:${sym}:irm`),
    vault: "0x0000000000000000000000000000000000000000",
  });
  return parseDeployment({
    chainId: 31337,
    startBlock: 1,
    deployer: addr("deployer"),
    guardian: addr("deployer"),
    timelockProposer: addr("deployer"),
    timelockDelay: 60,
    contracts: {
      aclManager: addr(`${label}:acl`),
      oracleManager: addr(`${label}:oracle`),
      lendingPool: addr(`${label}:pool`),
      poolConfigurator: addr(`${label}:configurator`),
      poolLens: addr(`${label}:lens`),
      timelock: addr(`${label}:timelock`),
    },
    markets: [m("WETH", true), m("USDC")],
  });
}

const deployment = makeDeployment();
const POOL = deployment.contracts.lendingPool;
const WETH = deployment.markets[0]!.token;
const USDC = deployment.markets[1]!.token;
const alice = addr("alice");
const bob = addr("bob");
const log = createLogger("indexer-test", "silent");
const opts = (o: Partial<IndexerOptions> = {}): IndexerOptions => ({
  confirmations: 0,
  batchSize: 1000,
  reorgWindow: 64,
  notifyChannel: "lending_events_test",
  ...o,
});

const supply = (user: Address, amount: bigint) => ({
  address: POOL,
  abi: lendingPoolAbi,
  eventName: "Supply",
  args: { reserve: USDC, onBehalfOf: user, caller: user, amount },
});
const borrow = (user: Address, amount: bigint) => ({
  address: POOL,
  abi: lendingPoolAbi,
  eventName: "Borrow",
  args: { reserve: USDC, user, amount, borrowRate: 42n },
});

let db: Db;

beforeEach(async () => {
  db ??= createDb(DB_URL, 4);
  await db.query("DROP SCHEMA public CASCADE; CREATE SCHEMA public;");
  await migrate(db);
});

afterAll(async () => {
  await db?.end();
});

async function count(table: string): Promise<number> {
  return Number((await db.query(`SELECT count(*) AS n FROM ${table}`)).rows[0].n);
}

async function drain(indexer: Indexer, max = 50) {
  const results = [];
  for (let i = 0; i < max; i++) {
    const r = await indexer.tick();
    results.push(r);
    if (r.kind === "idle") break;
  }
  return results;
}

describe("indexing", () => {
  it("decodes pool events into raw and typed tables and advances the cursor", async () => {
    const chain = new FakeChain();
    chain.mine([supply(alice, 1_000n)]);
    chain.mine([borrow(alice, 400n)]);
    chain.mine([
      {
        address: POOL,
        abi: lendingPoolAbi,
        eventName: "LiquidationCall",
        args: { collateralAsset: WETH, debtAsset: USDC, borrower: alice, liquidator: bob, debtRepaid: 200n, collateralSeized: 1n, receiveSupply: false },
      },
    ]);
    const indexer = new Indexer(db, chain, deployment, log, opts());
    await indexer.init();
    await drain(indexer);

    expect(await count("events")).toBe(3);
    expect(await count("supplies")).toBe(1);
    expect(await count("borrows")).toBe(1);
    const liq = (await db.query("SELECT * FROM liquidations")).rows[0];
    expect(liq).toMatchObject({ borrower: alice.toLowerCase(), liquidator: bob.toLowerCase(), debt_repaid: "200" });
    const cursor = (await db.query("SELECT block_number, block_hash FROM indexer_cursor")).rows[0];
    expect(cursor.block_number).toBe(3);
    expect(cursor.block_hash).toBe(chain.blocks[3]!.header.hash);
    // accounts view derives participants from events
    const accounts = (await db.query("SELECT address FROM accounts ORDER BY address")).rows.map((r) => r.address);
    expect(accounts).toEqual([alice.toLowerCase(), bob.toLowerCase()].sort());
  });

  it("stores amounts exactly (uint256 never passes through a float)", async () => {
    const chain = new FakeChain();
    const huge = 2n ** 200n + 12345n;
    chain.mine([supply(alice, huge)]);
    const indexer = new Indexer(db, chain, deployment, log, opts());
    await indexer.init();
    await drain(indexer);
    expect((await db.query("SELECT amount FROM supplies")).rows[0].amount).toBe(huge.toString());
  });

  it("is idempotent: replaying an already-committed batch inserts nothing twice", async () => {
    const chain = new FakeChain();
    chain.mine([supply(alice, 1n)]);
    chain.mine([supply(bob, 2n)]);
    const indexer = new Indexer(db, chain, deployment, log, opts());
    await indexer.init();
    await drain(indexer);
    // Simulate a crash after commit but before the process noticed: rewind the cursor.
    await db.query("UPDATE indexer_cursor SET block_number = 0, block_hash = $1", [chain.blocks[0]!.header.hash]);
    await drain(indexer);
    expect(await count("supplies")).toBe(2);
    expect(await count("events")).toBe(2);
  });

  it("respects the confirmation depth", async () => {
    const chain = new FakeChain();
    chain.mine([supply(alice, 1n)]); // block 1
    const indexer = new Indexer(db, chain, deployment, log, opts({ confirmations: 2 }));
    await indexer.init();
    await drain(indexer);
    expect(await count("supplies")).toBe(0); // head 1, confirmed up to -1
    chain.mineEmpty(2); // head 3: block 1 now has 2 confirmations
    await drain(indexer);
    expect(await count("supplies")).toBe(1);
  });

  it("indexes in multiple batches", async () => {
    const chain = new FakeChain();
    for (let i = 0; i < 10; i++) chain.mine([supply(alice, BigInt(i + 1))]);
    const indexer = new Indexer(db, chain, deployment, log, opts({ batchSize: 3 }));
    await indexer.init();
    const results = await drain(indexer);
    expect(results.filter((r) => r.kind === "indexed")).toHaveLength(4); // 3+3+3+1 blocks
    expect(await count("supplies")).toBe(10);
  });

  it("attributes price-feed events to their market and role", async () => {
    const chain = new FakeChain();
    const weth = deployment.markets[0]!;
    chain.mine([
      { address: weth.primaryFeed, abi: mockAggregatorAbi, eventName: "AnswerUpdated", args: { current: 1_800n * 10n ** 8n, roundId: 2n, updatedAt: 1_700_000_100n } },
      { address: weth.secondaryFeed, abi: mockAggregatorAbi, eventName: "AnswerUpdated", args: { current: 1_800n * 10n ** 18n, roundId: 2n, updatedAt: 1_700_000_100n } },
    ]);
    const indexer = new Indexer(db, chain, deployment, log, opts());
    await indexer.init();
    await drain(indexer);
    const rows = (await db.query("SELECT asset, feed_role, answer FROM price_updates ORDER BY log_index")).rows;
    expect(rows).toEqual([
      { asset: WETH.toLowerCase(), feed_role: "primary", answer: "180000000000" },
      { asset: WETH.toLowerCase(), feed_role: "secondary", answer: "1800000000000000000000" },
    ]);
  });

  it("tracks timelock operations from schedule to execution", async () => {
    const chain = new FakeChain();
    const id = keccak256(toHex("op1"));
    const tl = deployment.contracts.timelock;
    chain.mine([
      {
        address: tl,
        abi: timelockAbi,
        eventName: "CallScheduled",
        args: { id, index: 0n, target: deployment.contracts.poolConfigurator, value: 0n, data: "0x1234", predecessor: `0x${"0".repeat(64)}`, delay: 60n },
      },
    ]);
    chain.mine([
      { address: tl, abi: timelockAbi, eventName: "CallExecuted", args: { id, index: 0n, target: deployment.contracts.poolConfigurator, value: 0n, data: "0x1234" } },
    ]);
    const indexer = new Indexer(db, chain, deployment, log, opts());
    await indexer.init();
    await drain(indexer);
    expect((await db.query("SELECT op_id, delay_seconds FROM timelock_calls")).rows).toEqual([{ op_id: id, delay_seconds: 60 }]);
    expect((await db.query("SELECT outcome FROM timelock_outcomes")).rows).toEqual([{ outcome: "executed" }]);
  });

  it("publishes a NOTIFY payload on commit", async () => {
    const listener = new pg.Client({ connectionString: DB_URL });
    await listener.connect();
    const received: string[] = [];
    listener.on("notification", (n) => received.push(n.payload ?? ""));
    await listener.query("LISTEN lending_events_test");

    const chain = new FakeChain();
    chain.mine([supply(alice, 5n)]);
    const indexer = new Indexer(db, chain, deployment, log, opts());
    await indexer.init();
    await drain(indexer);
    await new Promise((r) => setTimeout(r, 100));
    await listener.end();
    expect(received).toHaveLength(1);
    expect(JSON.parse(received[0]!)).toMatchObject({ type: "events", counts: { Supply: 1 } });
  });
});

describe("reorgs", () => {
  it("rolls back a shallow reorg to the common ancestor and re-indexes the new fork", async () => {
    const chain = new FakeChain();
    chain.mine([supply(alice, 1n)]); // 1
    chain.mine([supply(alice, 2n)]); // 2
    chain.mine([supply(bob, 3n)]); //   3  <- will be orphaned
    chain.mineEmpty(1); //              4  <- will be orphaned
    const indexer = new Indexer(db, chain, deployment, log, opts());
    await indexer.init();
    await drain(indexer);
    expect(await count("supplies")).toBe(3);

    chain.reorg(2, "fork-b"); // drop 3 and 4
    chain.mine([borrow(bob, 7n)]); // new 3
    chain.mineEmpty(1); //            new 4

    const r = await indexer.tick();
    expect(r).toEqual({ kind: "reorg", rolledBackTo: 2n, depth: 2 });
    await drain(indexer);

    const supplies = (await db.query("SELECT amount FROM supplies ORDER BY block_number")).rows.map((x) => x.amount);
    expect(supplies).toEqual(["1", "2"]); // bob's orphaned supply is gone
    expect(await count("borrows")).toBe(1); // the new fork's event is in
    const cursor = (await db.query("SELECT block_number, block_hash FROM indexer_cursor")).rows[0];
    expect(cursor.block_hash).toBe(chain.blocks[4]!.header.hash);
  });

  it("drops monitor snapshots that describe rolled-back blocks", async () => {
    const chain = new FakeChain();
    chain.mine([supply(alice, 1n)]); // 1
    chain.mine([supply(alice, 2n)]); // 2
    chain.mine([supply(bob, 3n)]); //   3  <- will be orphaned
    chain.mineEmpty(1); //              4  <- will be orphaned
    const indexer = new Indexer(db, chain, deployment, log, opts());
    await indexer.init();
    await drain(indexer);

    // The risk monitor writes snapshots keyed by block number, in its own process.
    for (const n of [2, 3]) {
      await db.query(
        `INSERT INTO risk_snapshots (block_number, account, priced, health_factor, collateral_usd, debt_usd, borrow_capacity_usd, level)
         VALUES ($1, $2, true, 1, 1, 1, 1, 'SAFE')`,
        [n, alice],
      );
      await db.query(
        `INSERT INTO market_snapshots (block_number, reserve, symbol, decimals, price, price_status, total_supplied,
           total_borrowed, cash, utilization, liquidity_rate, borrow_rate, treasury, deficit, supplied_usd, borrowed_usd)
         VALUES ($1, $2, 'WETH', 18, 1, 'OK', 1, 0, 1, 0, 0, 0, 0, 0, 1, 0)`,
        [n, deployment.markets[0]!.token],
      );
    }

    chain.reorg(2, "fork-b"); // drop 3 and 4
    chain.mineEmpty(2);
    expect(await indexer.tick()).toMatchObject({ kind: "reorg", rolledBackTo: 2n });

    // Snapshots for the orphaned block are gone; the one at the surviving height stays.
    const risk = (await db.query("SELECT block_number FROM risk_snapshots")).rows.map((r) => Number(r.block_number));
    const markets = (await db.query("SELECT block_number FROM market_snapshots")).rows.map((r) => Number(r.block_number));
    expect(risk).toEqual([2]);
    expect(markets).toEqual([2]);
  });

  it("recovers from a reset chain (restarted Anvil) by re-indexing from the start block", async () => {
    const chain = new FakeChain();
    chain.mine([supply(alice, 1n)]);
    chain.mine([supply(alice, 2n)]);
    const indexer = new Indexer(db, chain, deployment, log, opts());
    await indexer.init();
    await drain(indexer);

    chain.reset("fresh-anvil");
    chain.mine([supply(bob, 99n)]);

    const r = await indexer.tick();
    expect(r).toMatchObject({ kind: "reorg", rolledBackTo: 0n });
    await drain(indexer);
    const rows = (await db.query("SELECT user_address, amount FROM supplies")).rows;
    expect(rows).toEqual([{ user_address: bob.toLowerCase(), amount: "99" }]);
  });

  it("discards a batch whose logs belong to a block replaced mid-batch", async () => {
    const chain = new FakeChain();
    chain.mine([supply(alice, 1n)]);
    const indexer = new Indexer(db, chain, deployment, log, opts());
    await indexer.init();
    chain.onGetLogs = (logs) => logs.map((l) => ({ ...l, blockHash: keccak256(toHex("stale")) }));
    expect((await indexer.tick()).kind).toBe("retry");
    expect(await count("events")).toBe(0);
    chain.onGetLogs = undefined;
    await drain(indexer);
    expect(await count("events")).toBe(1);
  });

  it("wipes chain-derived data when the deployment changes", async () => {
    const chain = new FakeChain();
    chain.mine([supply(alice, 1n)]);
    const first = new Indexer(db, chain, deployment, log, opts());
    await first.init();
    await drain(first);
    expect(await count("supplies")).toBe(1);

    const redeployed = new Indexer(db, chain, makeDeployment("v2"), log, opts());
    await redeployed.init();
    expect(await count("supplies")).toBe(0);
    expect(await count("indexer_cursor")).toBe(0);
  });
});

describe("long-running loop", () => {
  it("does not leak abort listeners while idle (regression: MaxListenersExceededWarning in Docker)", async () => {
    const chain = new FakeChain();
    const indexer = new Indexer(db, chain, deployment, log, opts());
    const controller = new AbortController();
    const running = indexer.run(controller.signal, 1);
    await new Promise((r) => setTimeout(r, 150)); // dozens of idle polls
    const listeners = getEventListeners(controller.signal, "abort").length;
    controller.abort();
    await running;
    expect(listeners).toBeLessThanOrEqual(1);
  });
});

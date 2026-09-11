/**
 * End-to-end: real Anvil + real Foundry deploy and demo scripts + real indexer + real API + real
 * risk monitor, over a real Postgres. Nothing mocked between the EVM and the HTTP response.
 *
 *   1. deploy + the brief's demo scenario (supply, borrow, ETH to $1,800, liquidation)
 *   2. index it and check every API view against the known outcome
 *   3. crash ETH to $1,000: the monitor flags LIQUIDATABLE + potential bad debt, the API proposes a
 *      liquidation, executing it writes off bad debt, and the market raises a BAD_DEBT alert
 *   4. a real chain reorg (evm_snapshot / evm_revert) is detected and rolled back
 *   5. a timelocked parameter change moves from pending to ready to executed
 *
 * Skipped automatically when `anvil` / `forge` are not installed.
 */
import { lendingPoolAbi, mockAggregatorAbi, mockErc20Abi, poolConfiguratorAbi, timelockAbi, type Deployment } from "@lending/shared";
import { createLogger, loadDeploymentFile, type Db } from "@lending/shared/node";
import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, createWalletClient, encodeFunctionData, http, keccak256, toHex, zeroHash, type Address, type PublicClient } from "viem";
import { mnemonicToAccount } from "viem/accounts";
import { foundry } from "viem/chains";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { viemChainSource } from "../../indexer/src/chain.js";
import { Indexer } from "../../indexer/src/indexer.js";
import { buildApp } from "../src/app.js";
import { ProtocolReader } from "../src/chain/reader.js";
import type { AppContext } from "../src/context.js";
import { RiskMonitor } from "../src/monitor/monitor.js";
import { TEST_DB_URL, freshDb } from "./fixtures.js";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const PORT = 8547;
const RPC = `http://127.0.0.1:${PORT}`;
const DEPLOYMENT = join(ROOT, "test-results", "e2e-deployment.json");
const MNEMONIC = "test test test test test test test test test test test junk"; // Anvil's PUBLIC dev mnemonic

const hasFoundry = (() => {
  try {
    execFileSync("anvil", ["--version"], { stdio: "ignore" });
    execFileSync("forge", ["--version"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
})();

const account = (i: number) => mnemonicToAccount(MNEMONIC, { addressIndex: i });
const deployer = account(0);
const bob = account(2).address;
const liquidator = account(4);

let anvil: ChildProcess;
let db: Db;
let deployment: Deployment;
let client: PublicClient;
let ctx: AppContext;
let indexer: Indexer;
let app: Awaited<ReturnType<typeof buildApp>>;

function forgeScript(script: string) {
  execFileSync("forge", ["script", script, "--rpc-url", RPC, "--broadcast", "--slow"], {
    cwd: ROOT,
    env: { ...process.env, DEPLOYMENT_OUT: DEPLOYMENT, DEPLOYMENT_FILE: DEPLOYMENT },
    stdio: "pipe",
  });
}

async function indexAll() {
  for (let i = 0; i < 100; i++) {
    const r = await indexer.tick();
    if (r.kind === "idle") return;
  }
}

const get = async (url: string) => {
  const res = await app.inject({ method: "GET", url });
  expect(res.statusCode, `${url}: ${res.body}`).toBe(200);
  return res.json();
};

const wallet = (acct: ReturnType<typeof account>) => createWalletClient({ account: acct, chain: foundry, transport: http(RPC) });

async function send(acct: ReturnType<typeof account>, tx: Parameters<ReturnType<typeof wallet>["writeContract"]>[0]) {
  const hash = await wallet(acct).writeContract(tx as never);
  const receipt = await client.waitForTransactionReceipt({ hash });
  expect(receipt.status).toBe("success");
  return receipt;
}

async function setEthPrice(usd: bigint) {
  const weth = deployment.markets[0]!;
  await send(deployer, { address: weth.primaryFeed, abi: mockAggregatorAbi, functionName: "setAnswer", args: [usd * 10n ** 8n] } as never);
  await send(deployer, { address: weth.secondaryFeed, abi: mockAggregatorAbi, functionName: "setAnswer", args: [usd * 10n ** 18n] } as never);
}

describe.skipIf(!hasFoundry)("end-to-end", () => {
  beforeAll(async () => {
    mkdirSync(dirname(DEPLOYMENT), { recursive: true });
    anvil = spawn("anvil", ["--port", String(PORT), "--chain-id", "31337", "--silent"], { stdio: "ignore" });
    client = createPublicClient({ chain: foundry, transport: http(RPC) }) as PublicClient;
    for (let i = 0; i < 50; i++) {
      try {
        await client.getBlockNumber();
        break;
      } catch {
        await new Promise((r) => setTimeout(r, 200));
      }
    }
    forgeScript("script/Deploy.s.sol");
    forgeScript("script/Demo.s.sol");
    deployment = loadDeploymentFile(DEPLOYMENT);

    db = await freshDb();
    const log = createLogger("e2e", "silent");
    indexer = new Indexer(db, viemChainSource(client), deployment, log, { confirmations: 0, batchSize: 500, reorgWindow: 128, notifyChannel: "e2e_events" });
    await indexer.init();
    ctx = {
      db,
      client,
      deployment,
      reader: new ProtocolReader(client, deployment, 0),
      log,
      config: { port: 0, host: "127.0.0.1", corsOrigins: [], rpcUrl: RPC, databaseUrl: TEST_DB_URL },
    };
    app = await buildApp(ctx);
    await indexAll();
  }, 180_000);

  afterAll(async () => {
    await app?.close();
    await db?.end();
    anvil?.kill();
  });

  it("indexes the demo and serves it through the API", async () => {
    const health = await get("/health");
    expect(health).toMatchObject({ status: "ok", indexerLagBlocks: 0 });

    const { markets } = await get("/markets");
    expect(markets.map((m: { symbol: string }) => m.symbol)).toEqual(["WETH", "WBTC", "USDC"]);
    const usdc = markets[2];
    expect(usdc.totalBorrowed.amount).toBeCloseTo(157_500, 0);
    expect(usdc.utilization).toBeCloseTo(0.6058, 3);
    expect(usdc.borrowApy).toBeGreaterThan(usdc.supplyApy);

    const acct = await get(`/accounts/${bob}`);
    expect(acct.healthFactor).toBeCloseTo(1.11375, 4);
    expect(acct.riskLevel).toBe("DANGER");
    expect(acct.positions.map((p: { symbol: string }) => p.symbol).sort()).toEqual(["USDC", "WETH"]);

    const liq = await get("/liquidations");
    expect(liq.total).toBe(1);
    expect(liq.liquidations[0]).toMatchObject({ borrower: bob.toLowerCase(), debt: { amount: 7500, usd: 7500 }, collateral: { amount: 4.375, usd: 7875 } });
    expect(liq.liquidations[0].liquidatorProfitUsd).toBeCloseTo(375, 6);

    const history = await get(`/accounts/${bob}/history`);
    expect(history.events.map((e: { name: string }) => e.name)).toContain("LiquidationCall");

    const tvl = await get("/protocol/tvl");
    expect(tvl.tvlUsd).toBeCloseTo(750_125, 0);
  });

  it("monitors risk, previews and executes a bad-debt liquidation, and books the deficit", async () => {
    const monitor = new RiskMonitor(ctx);
    await monitor.sweep(Date.now());
    let summary = await get("/risk/summary");
    expect(summary.levels.DANGER.accounts).toBe(1);

    // ETH gaps down to $1,000: bob's 5.625 WETH ($5,625) no longer covers 7,500 USDC of debt.
    await setEthPrice(1_000n);
    await monitor.sweep(Date.now() + 60_000);
    summary = await get("/risk/summary");
    expect(summary.levels.LIQUIDATABLE.accounts).toBe(1);
    expect(summary.potentialBadDebtUsd).toBeGreaterThan(1_800);
    const alerts = (await get("/risk/alerts")).alerts.map((a: { kind: string }) => a.kind);
    expect(alerts).toEqual(expect.arrayContaining(["LIQUIDATABLE", "POTENTIAL_BAD_DEBT"]));

    const { candidates } = await get("/liquidations/candidates");
    const best = candidates.find((c: { address: string }) => c.address === bob).bestLiquidation;
    expect(best).toMatchObject({ collateralSymbol: "WETH", debtSymbol: "USDC", closeFactor: 1 });

    // Execute exactly what the API proposed.
    const usdc = deployment.markets[2]!.token;
    const weth = deployment.markets[0]!.token;
    await send(liquidator, { address: usdc, abi: mockErc20Abi, functionName: "approve", args: [deployment.contracts.lendingPool, 2n ** 256n - 1n] } as never);
    await send(liquidator, {
      address: deployment.contracts.lendingPool,
      abi: lendingPoolAbi,
      functionName: "liquidate",
      args: [weth, usdc, bob, BigInt(best.debtToCoverRaw), false],
    } as never);
    await indexAll();

    const acct = await get(`/accounts/${bob}`);
    expect(acct.totalDebtUsd).toBe(0); // remaining debt written off
    const usdcMarket = (await get("/markets")).markets[2];
    expect(usdcMarket.deficit.amount).toBeGreaterThan(2_000);
    const analytics = await get("/analytics");
    expect(analytics.badDebt).toHaveLength(1);
    expect(analytics.liquidations.n).toBe(2);

    await monitor.sweep(Date.now() + 120_000);
    const open = (await get("/risk/alerts")).alerts.map((a: { kind: string }) => a.kind);
    expect(open).toContain("BAD_DEBT");
    expect(open).not.toContain("LIQUIDATABLE"); // bob's account is closed
  });

  it("detects and rolls back a real reorg", async () => {
    const snapshot = await client.request({ method: "evm_snapshot" as never, params: [] as never });
    await setEthPrice(1_100n); // two feed updates on the soon-to-be-orphaned branch
    await indexAll();
    const before = Number((await db.query(`SELECT count(*) FROM price_updates WHERE answer = '110000000000'`)).rows[0].count);
    expect(before).toBe(1);

    await client.request({ method: "evm_revert" as never, params: [snapshot] as never });
    await setEthPrice(1_200n); // same heights, different blocks
    const r = await indexer.tick();
    expect(r.kind).toBe("reorg");
    await indexAll();

    const orphaned = Number((await db.query(`SELECT count(*) FROM price_updates WHERE answer = '110000000000'`)).rows[0].count);
    const canonical = Number((await db.query(`SELECT count(*) FROM price_updates WHERE answer = '120000000000'`)).rows[0].count);
    expect(orphaned).toBe(0);
    expect(canonical).toBe(1);
  });

  it("tracks a timelocked risk change from pending to executed", async () => {
    const data = encodeFunctionData({ abi: poolConfiguratorAbi, functionName: "setReserveFactor", args: [deployment.markets[2]!.token, 2_000] });
    const salt = keccak256(toHex("e2e-rf"));
    const tl = deployment.contracts.timelock;
    await send(deployer, { address: tl, abi: timelockAbi, functionName: "schedule", args: [deployment.contracts.poolConfigurator, 0n, data, zeroHash, salt, 60n] } as never);
    await indexAll();

    let ops = (await get("/governance/timelock")).operations;
    expect(ops[0]).toMatchObject({ status: "pending", salt, call: { contract: "PoolConfigurator", function: "setReserveFactor" } });

    await client.request({ method: "evm_increaseTime" as never, params: [61] as never });
    await client.request({ method: "evm_mine" as never, params: [] as never });
    await send(deployer, { address: tl, abi: timelockAbi, functionName: "execute", args: [deployment.contracts.poolConfigurator, 0n, data, zeroHash, salt] } as never);
    await indexAll();

    ops = (await get("/governance/timelock")).operations;
    expect(ops[0].status).toBe("executed");
    const usdc = (await get("/markets")).markets[2];
    expect(usdc.config.reserveFactor).toBe(0.2);
  });
});

export type { Address };

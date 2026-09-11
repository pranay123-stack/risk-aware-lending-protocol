import { envBool, envInt, migrate } from "@lending/shared/node";
import type { Hex } from "viem";
import { createContext } from "./context.js";
import { DEFAULT_MONITOR_OPTIONS, RiskMonitor } from "./monitor/monitor.js";
import { MockPriceKeeper } from "./monitor/priceKeeper.js";

/** Anvil account #0: a PUBLIC test key, owner of the local mock feeds. Refused on any other chain. */
const ANVIL_KEY_0: Hex = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

const ctx = createContext("monitor");
await migrate(ctx.db);

const monitor = new RiskMonitor(ctx, {
  ...DEFAULT_MONITOR_OPTIONS,
  marketSnapshotEveryMs: envInt("MARKET_SNAPSHOT_EVERY_MS", DEFAULT_MONITOR_OPTIONS.marketSnapshotEveryMs),
});
const sweepEvery = envInt("MONITOR_INTERVAL_MS", 10_000);

const local = ctx.deployment.chainId === 31337;
const keeperEnabled = envBool("PRICE_KEEPER_ENABLED", local);
const keeper = keeperEnabled && local ? new MockPriceKeeper(ctx, (process.env.KEEPER_PRIVATE_KEY as Hex | undefined) ?? ANVIL_KEY_0) : null;
const keeperEvery = envInt("PRICE_KEEPER_INTERVAL_MS", 60_000);

let stopping = false;
for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    stopping = true;
  });
}

ctx.log.info({ sweepEvery, keeper: Boolean(keeper), keeperEvery }, "risk monitor starting");
let lastKeeper = 0;
while (!stopping) {
  const started = Date.now();
  try {
    if (keeper && started - lastKeeper >= keeperEvery) {
      await keeper.tick();
      lastKeeper = started;
    }
    const r = await monitor.sweep(started);
    if (r.opened || r.resolved) ctx.log.info(r, "risk sweep: alerts changed");
    else ctx.log.debug(r, "risk sweep");
  } catch (err) {
    ctx.log.error({ err }, "risk sweep failed");
  }
  const wait = Math.max(0, sweepEvery - (Date.now() - started));
  await new Promise((r) => setTimeout(r, wait));
}
await ctx.db.end();

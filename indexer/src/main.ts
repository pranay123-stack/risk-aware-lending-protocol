import { createDb, createLogger, env, envInt, loadDeploymentFile, migrate, DEFAULT_DATABASE_URL } from "@lending/shared/node";
import { createPublicClient, http } from "viem";
import { viemChainSource } from "./chain.js";
import { DEFAULT_OPTIONS, Indexer } from "./indexer.js";

const log = createLogger("indexer");

const deployment = loadDeploymentFile(env("DEPLOYMENT_FILE", "../deployments/31337.json"));
const rpcUrl = env("RPC_URL", "http://127.0.0.1:8545");
const db = createDb(env("DATABASE_URL", DEFAULT_DATABASE_URL));
const isLocal = deployment.chainId === 31337;

const options = {
  ...DEFAULT_OPTIONS,
  // Anvil cannot reorg on its own, and with auto-mining a confirmation depth would hold back the
  // newest events until more blocks arrive. Public chains default to 3 confirmations.
  confirmations: envInt("CONFIRMATIONS", isLocal ? 0 : 3),
  batchSize: envInt("BATCH_SIZE", DEFAULT_OPTIONS.batchSize),
  reorgWindow: envInt("REORG_WINDOW", DEFAULT_OPTIONS.reorgWindow),
};

const applied = await migrate(db);
if (applied.length) log.info({ applied }, "migrations applied");

const client = createPublicClient({ transport: http(rpcUrl, { retryCount: 3 }) });
const chainId = await client.getChainId();
if (chainId !== deployment.chainId) {
  throw new Error(`RPC chain id ${chainId} does not match deployment chain id ${deployment.chainId}`);
}

const indexer = new Indexer(db, viemChainSource(client), deployment, log, options);
const controller = new AbortController();
for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    log.info({ sig }, "shutting down");
    controller.abort();
  });
}

log.info({ rpcUrl, chainId, startBlock: deployment.startBlock, ...options }, "indexer starting");
await indexer.run(controller.signal, envInt("POLL_INTERVAL_MS", 1_000));
await db.end();

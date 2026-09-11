import type { Deployment } from "@lending/shared";
import { createDb, createLogger, env, envInt, loadDeploymentFile, type Db, type Logger, DEFAULT_DATABASE_URL } from "@lending/shared/node";
import { createPublicClient, http, type PublicClient } from "viem";
import { ProtocolReader } from "./chain/reader.js";

export interface AppContext {
  db: Db;
  client: PublicClient;
  deployment: Deployment;
  reader: ProtocolReader;
  log: Logger;
  config: {
    port: number;
    host: string;
    corsOrigins: string[];
    rpcUrl: string;
    databaseUrl: string;
  };
}

export function createContext(name: string): AppContext {
  const log = createLogger(name);
  const deployment = loadDeploymentFile(env("DEPLOYMENT_FILE", "../deployments/31337.json"));
  const rpcUrl = env("RPC_URL", "http://127.0.0.1:8545");
  const databaseUrl = env("DATABASE_URL", DEFAULT_DATABASE_URL);
  const client = createPublicClient({ transport: http(rpcUrl, { retryCount: 2 }) }) as PublicClient;
  return {
    db: createDb(databaseUrl),
    client,
    deployment,
    reader: new ProtocolReader(client, deployment, envInt("CHAIN_CACHE_MS", 2_000)),
    log,
    config: {
      port: envInt("API_PORT", 4400),
      host: env("API_HOST", "0.0.0.0"),
      corsOrigins: env("CORS_ORIGINS", "http://localhost:3400,http://127.0.0.1:3400").split(","),
      rpcUrl,
      databaseUrl,
    },
  };
}

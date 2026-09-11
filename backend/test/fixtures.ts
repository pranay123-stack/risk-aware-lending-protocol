import { parseDeployment, type Deployment } from "@lending/shared";
import { createDb, createLogger, migrate, type Db } from "@lending/shared/node";
import { getAddress, keccak256, toHex, type Address } from "viem";
import type { AppContext } from "../src/context.js";

export const TEST_DB_URL = process.env.DATABASE_URL_TEST ?? "postgres://lending:lending@127.0.0.1:5475/lending_test";

export const addr = (label: string) => getAddress(keccak256(toHex(label)).slice(0, 42)) as Address;

export function fakeDeployment(): Deployment {
  const zero = "0x0000000000000000000000000000000000000000";
  return parseDeployment({
    chainId: 31337,
    startBlock: 0,
    deployer: addr("deployer"),
    guardian: addr("deployer"),
    timelockProposer: addr("deployer"),
    timelockDelay: 60,
    contracts: {
      aclManager: addr("acl"),
      oracleManager: addr("oracle"),
      lendingPool: addr("pool"),
      poolConfigurator: addr("configurator"),
      poolLens: addr("lens"),
      timelock: addr("timelock"),
    },
    markets: [
      { symbol: "WETH", token: addr("weth"), primaryFeed: addr("f1"), secondaryFeed: zero, interestRateModel: addr("i1"), vault: zero },
      { symbol: "USDC", token: addr("usdc"), primaryFeed: addr("f2"), secondaryFeed: zero, interestRateModel: addr("i2"), vault: zero },
    ],
  });
}

export async function freshDb(): Promise<Db> {
  const db = createDb(TEST_DB_URL, 4);
  await db.query("DROP SCHEMA public CASCADE; CREATE SCHEMA public;");
  await migrate(db);
  return db;
}

/** A context whose reader is replaced by `reader` (only the methods a test needs). */
export function stubContext(db: Db, reader: Partial<AppContext["reader"]>, deployment = fakeDeployment()): AppContext {
  return {
    db,
    client: {} as AppContext["client"],
    deployment,
    reader: reader as AppContext["reader"],
    log: createLogger("test", "silent"),
    config: { port: 0, host: "127.0.0.1", corsOrigins: [], rpcUrl: "", databaseUrl: TEST_DB_URL },
  };
}

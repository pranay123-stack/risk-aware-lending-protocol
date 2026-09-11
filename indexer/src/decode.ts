import {
  aclManagerAbi,
  feedIndex,
  lendingPoolAbi,
  lendingVaultAbi,
  mockAggregatorAbi,
  oracleManagerAbi,
  poolConfiguratorAbi,
  timelockAbi,
  vaults,
  type Deployment,
} from "@lending/shared";
import { decodeEventLog, getAddress, type Abi, type Address, type Log } from "viem";

export type Source = "pool" | "configurator" | "oracle" | "feed" | "timelock" | "vault" | "acl";

export interface DecodedEvent {
  source: Source;
  contract: Address;
  name: string;
  /** Decoded arguments; bigints are kept as bigints until persistence. */
  args: Record<string, unknown>;
  blockNumber: bigint;
  blockHash: `0x${string}`;
  txHash: `0x${string}`;
  logIndex: number;
  /** Feed events only: the market the feed prices and whether it is the primary or secondary. */
  feed?: { asset: Address; role: "primary" | "secondary" };
}

interface Registered {
  source: Source;
  abi: Abi;
}

/** Routes each log to the ABI of the contract that emitted it. Built once from the deployment file. */
export class EventDecoder {
  private readonly registry = new Map<Address, Registered>();
  private readonly feeds: ReturnType<typeof feedIndex>;

  constructor(deployment: Deployment) {
    const c = deployment.contracts;
    this.register(c.lendingPool, "pool", lendingPoolAbi);
    this.register(c.poolConfigurator, "configurator", poolConfiguratorAbi);
    this.register(c.oracleManager, "oracle", oracleManagerAbi);
    this.register(c.timelock, "timelock", timelockAbi);
    this.register(c.aclManager, "acl", aclManagerAbi);
    for (const v of vaults(deployment)) this.register(v, "vault", lendingVaultAbi);
    this.feeds = feedIndex(deployment);
    for (const feed of this.feeds.keys()) this.register(feed, "feed", mockAggregatorAbi);
  }

  private register(address: Address, source: Source, abi: Abi) {
    this.registry.set(getAddress(address), { source, abi });
  }

  /** Every address the indexer subscribes to. */
  addresses(): Address[] {
    return [...this.registry.keys()];
  }

  /** Returns null for logs we do not model (e.g. ERC-20 Transfer events of vault shares). */
  decode(log: Log): DecodedEvent | null {
    if (log.blockNumber === null || log.blockHash === null || log.transactionHash === null || log.logIndex === null) {
      return null; // pending logs are never indexed
    }
    const contract = getAddress(log.address);
    const reg = this.registry.get(contract);
    if (!reg) return null;
    let decoded: { eventName: string; args: unknown };
    try {
      decoded = decodeEventLog({ abi: reg.abi, data: log.data, topics: log.topics, strict: true }) as {
        eventName: string;
        args: unknown;
      };
    } catch {
      return null;
    }
    if (reg.source === "vault" && (decoded.eventName === "Transfer" || decoded.eventName === "Approval")) return null;
    const feed = reg.source === "feed" ? this.feeds.get(contract) : undefined;
    return {
      source: reg.source,
      contract,
      name: decoded.eventName,
      args: (decoded.args ?? {}) as Record<string, unknown>,
      blockNumber: log.blockNumber,
      blockHash: log.blockHash,
      txHash: log.transactionHash,
      logIndex: log.logIndex,
      ...(feed ? { feed: { asset: feed.asset, role: feed.role } } : {}),
    };
  }
}

/** JSON-safe copy of decoded args: bigint -> decimal string, addresses lowercased. */
export function toJsonArgs(value: unknown): unknown {
  if (typeof value === "bigint") return value.toString();
  if (typeof value === "string" && /^0x[0-9a-fA-F]{40}$/.test(value)) return value.toLowerCase();
  if (Array.isArray(value)) return value.map(toJsonArgs);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, toJsonArgs(v)]));
  }
  return value;
}

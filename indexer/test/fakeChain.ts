import {
  encodeAbiParameters,
  encodeEventTopics,
  getAddress,
  keccak256,
  toHex,
  type Abi,
  type AbiEvent,
  type Address,
  type Hex,
  type Log,
} from "viem";
import type { BlockHeader, ChainSource } from "../src/chain.js";

export interface LogSpec {
  address: Address;
  abi: Abi;
  eventName: string;
  args: Record<string, unknown>;
}

interface FakeBlock {
  header: BlockHeader;
  logs: Log[];
}

/**
 * In-memory chain with deterministic hashes. `fork` salts the hashes, so a block re-mined on a
 * different fork gets a different hash, exactly like a real reorg.
 */
export class FakeChain implements ChainSource {
  blocks: FakeBlock[] = [];
  /** Test hook: mutate logs after they are produced (simulate a mid-batch reorg). */
  onGetLogs?: (logs: Log[]) => Log[];
  private txCounter = 0;

  constructor(private fork = "main") {
    this.mine([]); // genesis
  }

  get head(): bigint {
    return BigInt(this.blocks.length - 1);
  }

  mine(specs: LogSpec[]): BlockHeader {
    const number = BigInt(this.blocks.length);
    const parentHash = number === 0n ? (`0x${"0".repeat(64)}` as Hex) : this.blocks[Number(number) - 1]!.header.hash;
    const hash = keccak256(toHex(`${this.fork}:${number}:${parentHash}`));
    const header: BlockHeader = { number, hash, parentHash, timestamp: 1_700_000_000n + number * 12n };
    const logs = specs.map((s, i) => this.encode(s, header, i));
    this.blocks.push({ header, logs });
    return header;
  }

  mineEmpty(n: number) {
    for (let i = 0; i < n; i++) this.mine([]);
  }

  /** Drop the last `depth` blocks and continue on a new fork. */
  reorg(depth: number, fork: string) {
    this.blocks.splice(this.blocks.length - depth, depth);
    this.fork = fork;
  }

  /** Replace the whole chain (a restarted Anvil). */
  reset(fork: string) {
    this.blocks = [];
    this.fork = fork;
    this.mine([]);
  }

  async getBlockNumber() {
    return this.head;
  }

  async getBlock(number: bigint) {
    return this.blocks[Number(number)]?.header ?? null;
  }

  async getLogs({ addresses, fromBlock, toBlock }: { addresses: Address[]; fromBlock: bigint; toBlock: bigint }) {
    const set = new Set(addresses.map((a) => getAddress(a)));
    const out: Log[] = [];
    for (let n = Number(fromBlock); n <= Number(toBlock) && n < this.blocks.length; n++) {
      for (const l of this.blocks[n]!.logs) if (set.has(getAddress(l.address))) out.push(l);
    }
    return this.onGetLogs ? this.onGetLogs(out) : out;
  }

  private encode(spec: LogSpec, header: BlockHeader, logIndex: number): Log {
    const event = spec.abi.find((x) => x.type === "event" && x.name === spec.eventName) as AbiEvent | undefined;
    if (!event) throw new Error(`unknown event ${spec.eventName}`);
    const topics = encodeEventTopics({ abi: [event], eventName: event.name, args: spec.args } as never) as Hex[];
    const nonIndexed = event.inputs.filter((i) => !i.indexed);
    const data = encodeAbiParameters(nonIndexed, nonIndexed.map((i) => spec.args[i.name!]) as never);
    this.txCounter++;
    return {
      address: spec.address,
      topics: topics as [Hex, ...Hex[]],
      data,
      blockNumber: header.number,
      blockHash: header.hash,
      transactionHash: keccak256(toHex(`tx:${this.txCounter}`)),
      transactionIndex: 0,
      logIndex,
      removed: false,
    } as Log;
  }
}

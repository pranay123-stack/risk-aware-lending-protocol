import type { Address, Hex, Log, PublicClient } from "viem";

export interface BlockHeader {
  number: bigint;
  hash: Hex;
  parentHash: Hex;
  timestamp: bigint;
}

/**
 * The indexer's only view of the chain. Production uses viem over JSON-RPC; tests use an in-memory
 * chain that can be reorganised at will (test/fakeChain.ts).
 */
export interface ChainSource {
  getBlockNumber(): Promise<bigint>;
  /** Returns null when the block does not exist (e.g. the chain was reset below that height). */
  getBlock(number: bigint): Promise<BlockHeader | null>;
  getLogs(params: { addresses: Address[]; fromBlock: bigint; toBlock: bigint }): Promise<Log[]>;
}

export function viemChainSource(client: PublicClient): ChainSource {
  return {
    getBlockNumber: () => client.getBlockNumber({ cacheTime: 0 }),
    async getBlock(number) {
      try {
        const b = await client.getBlock({ blockNumber: number });
        return { number: b.number, hash: b.hash, parentHash: b.parentHash, timestamp: b.timestamp };
      } catch {
        return null;
      }
    },
    getLogs: ({ addresses, fromBlock, toBlock }) => client.getLogs({ address: addresses, fromBlock, toBlock }),
  };
}

import type { Deployment } from "@lending/shared";
import { withTransaction, type Db, type DbClient, type Logger } from "@lending/shared/node";
import type { BlockHeader, ChainSource } from "./chain.js";
import { EventDecoder, type DecodedEvent } from "./decode.js";
import { persistBlocks, persistEvents } from "./persist.js";

export interface IndexerOptions {
  /** Blocks behind head that must exist before a block is indexed. */
  confirmations: number;
  /** Max blocks per getLogs call / DB transaction. */
  batchSize: number;
  /** How far back (in stored blocks) to search for a common ancestor after a reorg. */
  reorgWindow: number;
  /** Postgres NOTIFY channel for live consumers (the API's WebSocket hub). */
  notifyChannel: string;
}

export const DEFAULT_OPTIONS: IndexerOptions = {
  confirmations: 2,
  batchSize: 500,
  reorgWindow: 128,
  notifyChannel: "lending_events",
};

export type TickResult =
  | { kind: "idle"; head: bigint; cursor: bigint }
  | { kind: "indexed"; fromBlock: bigint; toBlock: bigint; events: number }
  | { kind: "reorg"; rolledBackTo: bigint; depth: number }
  | { kind: "retry"; reason: string };

interface Cursor {
  blockNumber: bigint;
  blockHash: string; // "" = nothing indexed yet
}

const CURSOR_ID = "main";

/**
 * Event-driven indexer.
 *
 * Guarantees:
 *  - Exactly-once: a batch's rows and the cursor advance commit in ONE transaction, and every
 *    row is unique on (tx_hash, log_index). A crash anywhere replays the batch harmlessly.
 *  - Confirmation depth: only blocks at head - confirmations are indexed.
 *  - Reorg-safe: the cursor block's hash is re-verified every tick. Because block hashes chain, a
 *    matching hash at height N proves nothing <= N changed. On mismatch we walk stored blocks back
 *    to the highest one the chain still agrees with, delete everything above it (FK cascade), and
 *    re-index from there.
 *  - Consistent batches: every log's blockHash must match the header fetched for that block,
 *    otherwise the chain moved mid-batch and the batch is discarded and retried.
 */
export class Indexer {
  private readonly decoder: EventDecoder;
  private readonly deploymentKey: string;
  private readonly startBlock: bigint;

  constructor(
    private readonly db: Db,
    private readonly chain: ChainSource,
    deployment: Deployment,
    private readonly log: Logger,
    private readonly opts: IndexerOptions = DEFAULT_OPTIONS,
  ) {
    this.decoder = new EventDecoder(deployment);
    this.deploymentKey = `${deployment.chainId}:${deployment.contracts.lendingPool.toLowerCase()}`;
    this.startBlock = BigInt(deployment.startBlock);
  }

  /** Called once at startup: wipes chain-derived data that belongs to a different deployment. */
  async init(): Promise<void> {
    const res = await this.db.query<{ deployment_key: string }>(
      "SELECT deployment_key FROM indexer_cursor WHERE id = $1",
      [CURSOR_ID],
    );
    const existing = res.rows[0]?.deployment_key;
    if (existing !== undefined && existing !== this.deploymentKey) {
      this.log.warn({ existing, current: this.deploymentKey }, "deployment changed: resetting chain-derived data");
      await withTransaction(this.db, async (c) => {
        await c.query("DELETE FROM blocks");
        await dropSnapshotsAbove(c, -1n);
        await c.query("DELETE FROM indexer_cursor WHERE id = $1", [CURSOR_ID]);
      });
    }
  }

  async tick(): Promise<TickResult> {
    const cursor = await this.readCursor();

    // 1. Reorg check on the cursor block.
    if (cursor.blockHash !== "") {
      const onChain = await this.chain.getBlock(cursor.blockNumber);
      if (!onChain || onChain.hash !== cursor.blockHash) return this.handleReorg(cursor);
    }

    // 2. Next batch within the confirmed range.
    const head = await this.chain.getBlockNumber();
    const target = head - BigInt(this.opts.confirmations);
    const from = cursor.blockNumber + 1n;
    if (target < from) return { kind: "idle", head, cursor: cursor.blockNumber };
    const to = from + BigInt(this.opts.batchSize) - 1n < target ? from + BigInt(this.opts.batchSize) - 1n : target;

    // 3. Fetch and decode.
    const logs = await this.chain.getLogs({ addresses: this.decoder.addresses(), fromBlock: from, toBlock: to });
    const events: DecodedEvent[] = [];
    for (const l of logs) {
      const e = this.decoder.decode(l);
      if (e) events.push(e);
    }

    // 4. Headers for every block with events plus the batch end (the new cursor).
    const numbers = new Set<bigint>(events.map((e) => e.blockNumber));
    numbers.add(to);
    const headers = new Map<bigint, BlockHeader>();
    for (const n of numbers) {
      const h = await this.chain.getBlock(n);
      if (!h) return { kind: "retry", reason: `block ${n} disappeared mid-batch` };
      headers.set(n, h);
    }
    for (const e of events) {
      if (headers.get(e.blockNumber)?.hash !== e.blockHash) {
        return { kind: "retry", reason: `log in block ${e.blockNumber} belongs to a replaced block` };
      }
    }
    // The batch must extend the chain we already stored. If the cursor block itself was replaced
    // after step 1, these headers come from a fork we never verified: retry, and the next tick's
    // cursor check rolls back. A reorg after this point replaces `to` as well, so the next tick
    // catches it too.
    if (cursor.blockHash !== "") {
      const still = await this.chain.getBlock(cursor.blockNumber);
      if (!still || still.hash !== cursor.blockHash) return { kind: "retry", reason: "cursor block replaced mid-batch" };
    }

    // 5. Commit everything atomically, then notify listeners (delivered on commit).
    const end = headers.get(to)!;
    const summary = await withTransaction(this.db, async (client) => {
      await persistBlocks(client, [...headers.values()].sort((a, b) => Number(a.number - b.number)));
      const s = await persistEvents(client, events, (n) => new Date(Number(headers.get(n)!.timestamp) * 1000));
      await this.writeCursor(client, to, end.hash);
      if (s.events > 0) {
        const payload = JSON.stringify({
          type: "events",
          fromBlock: from.toString(),
          toBlock: to.toString(),
          counts: s.byName,
          liquidations: s.liquidations.slice(0, 10),
        });
        await client.query("SELECT pg_notify($1, $2)", [this.opts.notifyChannel, payload.slice(0, 7_900)]);
      }
      return s;
    });

    if (summary.events > 0) {
      this.log.info({ from: from.toString(), to: to.toString(), events: summary.byName }, "indexed batch");
    }
    return { kind: "indexed", fromBlock: from, toBlock: to, events: summary.events };
  }

  /** Run until the signal aborts. Sleeps only when caught up. */
  async run(signal: AbortSignal, pollIntervalMs: number): Promise<void> {
    await this.init();
    while (!signal.aborted) {
      try {
        const r = await this.tick();
        if (r.kind === "idle") await sleep(pollIntervalMs, signal);
        else if (r.kind === "retry") {
          this.log.warn({ reason: r.reason }, "batch discarded, retrying");
          await sleep(pollIntervalMs, signal);
        }
      } catch (err) {
        this.log.error({ err }, "indexer tick failed");
        await sleep(pollIntervalMs * 2, signal);
      }
    }
  }

  // ------------------------------------------------------------------ reorg handling

  private async handleReorg(cursor: Cursor): Promise<TickResult> {
    const stored = await this.db.query<{ number: number; hash: string }>(
      "SELECT number, hash FROM blocks WHERE number <= $1 ORDER BY number DESC LIMIT $2",
      [cursor.blockNumber.toString(), this.opts.reorgWindow],
    );

    let ancestor: { number: bigint; hash: string } | null = null;
    for (const row of stored.rows) {
      const onChain = await this.chain.getBlock(BigInt(row.number));
      if (onChain && onChain.hash === row.hash) {
        ancestor = { number: BigInt(row.number), hash: row.hash };
        break;
      }
    }

    // No agreeing block inside the window (deep reorg, or a reset chain): re-index from scratch.
    const rollbackTo = ancestor ?? { number: this.startBlock - 1n, hash: "" };
    const depth = Number(cursor.blockNumber - rollbackTo.number);

    await withTransaction(this.db, async (client) => {
      await client.query("DELETE FROM blocks WHERE number > $1", [rollbackTo.number.toString()]);
      await dropSnapshotsAbove(client, rollbackTo.number);
      await this.writeCursor(client, rollbackTo.number, rollbackTo.hash);
      await client.query("SELECT pg_notify($1, $2)", [
        this.opts.notifyChannel,
        JSON.stringify({ type: "reorg", rolledBackTo: rollbackTo.number.toString(), depth }),
      ]);
    });

    this.log.warn({ rolledBackTo: rollbackTo.number.toString(), depth, fullReset: ancestor === null }, "reorg detected");
    return { kind: "reorg", rolledBackTo: rollbackTo.number, depth };
  }

  // ------------------------------------------------------------------ cursor

  private async readCursor(): Promise<Cursor> {
    const res = await this.db.query<{ block_number: number; block_hash: string }>(
      "SELECT block_number, block_hash FROM indexer_cursor WHERE id = $1",
      [CURSOR_ID],
    );
    const row = res.rows[0];
    if (!row) return { blockNumber: this.startBlock - 1n, blockHash: "" };
    return { blockNumber: BigInt(row.block_number), blockHash: row.block_hash };
  }

  private async writeCursor(client: DbClient, blockNumber: bigint, blockHash: string) {
    await client.query(
      `INSERT INTO indexer_cursor (id, deployment_key, block_number, block_hash, updated_at)
       VALUES ($1, $2, $3, $4, now())
       ON CONFLICT (id) DO UPDATE SET deployment_key = EXCLUDED.deployment_key,
         block_number = EXCLUDED.block_number, block_hash = EXCLUDED.block_hash, updated_at = now()`,
      [CURSOR_ID, this.deploymentKey, blockNumber.toString(), blockHash],
    );
  }
}

/**
 * Monitor snapshots are chain-derived but written by a different process, so they carry a block number
 * instead of a foreign key to `blocks` (the monitor reads the head before the indexer has stored it).
 * Nothing else would delete them, so a reorg or a restarted chain would leave rows describing blocks
 * that no longer exist, and the risk API would report a "latest" sweep from a chain that is gone.
 */
async function dropSnapshotsAbove(client: DbClient, blockNumber: bigint): Promise<void> {
  const n = blockNumber.toString();
  await client.query("DELETE FROM risk_snapshots WHERE block_number > $1", [n]);
  await client.query("DELETE FROM market_snapshots WHERE block_number > $1", [n]);
}

/**
 * Abortable sleep. The abort listener is removed when the timer fires. Leaving it attached leaks
 * one listener per idle poll for the life of the process (caught in Docker by Node's
 * MaxListenersExceededWarning).
 */
function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (signal.aborted) return resolve();
    const onAbort = () => {
      clearTimeout(timer);
      resolve();
    };
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    signal.addEventListener("abort", onAbort, { once: true });
  });
}

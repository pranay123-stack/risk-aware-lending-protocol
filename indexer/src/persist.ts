import type { DbClient } from "@lending/shared/node";
import type { BlockHeader } from "./chain.js";
import { toJsonArgs, type DecodedEvent } from "./decode.js";

const lc = (a: unknown) => String(a).toLowerCase();
const num = (v: unknown) => (typeof v === "bigint" ? v.toString() : String(v));

type Row = Record<string, string | number | boolean | null>;

/** Idempotent insert: replaying a batch after a crash is a no-op, never a duplicate. */
async function insert(client: DbClient, table: string, row: Row, conflict = "(tx_hash, log_index)") {
  const cols = Object.keys(row);
  const params = cols.map((_, i) => `$${i + 1}`).join(", ");
  await client.query(
    `INSERT INTO ${table} (${cols.join(", ")}) VALUES (${params}) ON CONFLICT ${conflict} DO NOTHING`,
    cols.map((c) => row[c] ?? null),
  );
}

/**
 * Store block headers. A block number already stored with a DIFFERENT hash means a reorg slipped
 * between our reorg check and this write; throwing aborts the transaction, and the next tick's
 * reorg check repairs it.
 */
export async function persistBlocks(client: DbClient, blocks: BlockHeader[]) {
  for (const b of blocks) {
    const res = await client.query<{ hash: string }>(
      `INSERT INTO blocks (number, hash, parent_hash, timestamp)
       VALUES ($1, $2, $3, to_timestamp($4))
       ON CONFLICT (number) DO UPDATE SET number = EXCLUDED.number
       RETURNING hash`,
      [b.number.toString(), b.hash, b.parentHash, Number(b.timestamp)],
    );
    if (res.rows[0]?.hash !== b.hash) {
      throw new Error(`block ${b.number} stored with hash ${res.rows[0]?.hash}, chain now says ${b.hash}`);
    }
  }
}

export interface PersistSummary {
  events: number;
  byName: Record<string, number>;
  liquidations: Array<Record<string, string | boolean>>;
}

export async function persistEvents(
  client: DbClient,
  events: DecodedEvent[],
  blockTime: (block: bigint) => Date,
): Promise<PersistSummary> {
  const summary: PersistSummary = { events: 0, byName: {}, liquidations: [] };
  for (const e of events) {
    const time = blockTime(e.blockNumber).toISOString();
    const base = { tx_hash: e.txHash, log_index: e.logIndex, block_number: e.blockNumber.toString(), block_time: time };
    const a = e.args;

    await insert(client, "events", {
      ...base,
      contract: lc(e.contract),
      source: e.source,
      name: e.name,
      args: JSON.stringify(toJsonArgs(a)),
    });
    summary.events++;
    summary.byName[e.name] = (summary.byName[e.name] ?? 0) + 1;

    if (e.source === "pool") {
      switch (e.name) {
        case "Supply":
          await insert(client, "supplies", { ...base, reserve: lc(a.reserve), user_address: lc(a.onBehalfOf), caller: lc(a.caller), amount: num(a.amount) });
          break;
        case "Withdraw":
          await insert(client, "withdrawals", { ...base, reserve: lc(a.reserve), user_address: lc(a.user), to_address: lc(a.to), amount: num(a.amount) });
          break;
        case "Borrow":
          await insert(client, "borrows", { ...base, reserve: lc(a.reserve), user_address: lc(a.user), amount: num(a.amount), borrow_rate: num(a.borrowRate) });
          break;
        case "Repay":
          await insert(client, "repays", { ...base, reserve: lc(a.reserve), user_address: lc(a.user), repayer: lc(a.repayer), amount: num(a.amount) });
          break;
        case "ReserveUsedAsCollateral":
          await insert(client, "collateral_toggles", { ...base, reserve: lc(a.reserve), user_address: lc(a.user), enabled: Boolean(a.enabled) });
          break;
        case "LiquidationCall": {
          const row = {
            collateral_asset: lc(a.collateralAsset),
            debt_asset: lc(a.debtAsset),
            borrower: lc(a.borrower),
            liquidator: lc(a.liquidator),
            debt_repaid: num(a.debtRepaid),
            collateral_seized: num(a.collateralSeized),
            receive_supply: Boolean(a.receiveSupply),
          };
          await insert(client, "liquidations", { ...base, ...row });
          summary.liquidations.push({ txHash: e.txHash, ...row });
          break;
        }
        case "BadDebtRecognized":
          await insert(client, "bad_debt_events", { ...base, reserve: lc(a.reserve), borrower: lc(a.borrower), amount: num(a.amount), covered_by_treasury: num(a.coveredByTreasury), deficit_added: num(a.deficitAdded) });
          break;
        case "ReserveDataUpdated":
          await insert(client, "reserve_updates", { ...base, reserve: lc(a.reserve), liquidity_rate: num(a.liquidityRate), borrow_rate: num(a.borrowRate), liquidity_index: num(a.liquidityIndex), borrow_index: num(a.borrowIndex) });
          break;
      }
    } else if (e.source === "feed" && e.name === "AnswerUpdated" && e.feed) {
      await insert(client, "price_updates", {
        ...base,
        feed: lc(e.contract),
        asset: lc(e.feed.asset),
        feed_role: e.feed.role,
        answer: num(a.current),
        round_id: num(a.roundId),
        updated_at: new Date(Number(a.updatedAt) * 1000).toISOString(),
      });
    } else if (e.source === "timelock") {
      if (e.name === "CallScheduled") {
        await insert(
          client,
          "timelock_calls",
          {
            op_id: String(a.id),
            call_index: Number(a.index),
            target: lc(a.target),
            value: num(a.value),
            data: String(a.data),
            predecessor: String(a.predecessor),
            delay_seconds: Number(a.delay),
            scheduled_tx: e.txHash,
            scheduled_block: e.blockNumber.toString(),
            scheduled_time: time,
          },
          "(op_id, call_index)",
        );
      } else if (e.name === "CallSalt") {
        await client.query("UPDATE timelock_calls SET salt = $2 WHERE op_id = $1", [String(a.id), String(a.salt)]);
      } else if (e.name === "CallExecuted" || e.name === "Cancelled") {
        await insert(client, "timelock_outcomes", { ...base, op_id: String(a.id), outcome: e.name === "Cancelled" ? "cancelled" : "executed" });
      }
    }
  }
  return summary;
}

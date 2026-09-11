import { aclManagerAbi, oracleManagerAbi, poolConfiguratorAbi } from "@lending/shared";
import type { FastifyInstance } from "fastify";
import { decodeFunctionData, getAddress, type Abi, type Hex } from "viem";
import type { AppContext } from "../context.js";
import { jsonSafe } from "../dto.js";

export function registerGovernanceRoutes(app: FastifyInstance, ctx: AppContext) {
  const c = ctx.deployment.contracts;
  const abis = new Map<string, { name: string; abi: Abi }>([
    [c.poolConfigurator.toLowerCase(), { name: "PoolConfigurator", abi: poolConfiguratorAbi as Abi }],
    [c.oracleManager.toLowerCase(), { name: "OracleManager", abi: oracleManagerAbi as Abi }],
    [c.aclManager.toLowerCase(), { name: "ACLManager", abi: aclManagerAbi as Abi }],
  ]);

  /**
   * Every timelocked operation with its decoded call, status and ETA. Pending changes are public
   * for the whole delay, which is the point: users can see a risk change coming and exit.
   */
  app.get("/governance/timelock", async () => {
    const [calls, outcomes, head, delay] = await Promise.all([
      ctx.db.query(
        `SELECT op_id, call_index, target, value::text, data, predecessor, salt, delay_seconds, scheduled_tx,
                scheduled_block, extract(epoch FROM scheduled_time)::bigint AS scheduled_at
         FROM timelock_calls ORDER BY scheduled_block DESC, call_index`,
      ),
      ctx.db.query(`SELECT op_id, outcome, tx_hash, block_time FROM timelock_outcomes`),
      ctx.reader.head(),
      ctx.reader.timelockDelay(),
    ]);
    const outcomeByOp = new Map<string, { outcome: string; txHash: string; at: Date }>();
    for (const o of outcomes.rows) outcomeByOp.set(o.op_id, { outcome: o.outcome, txHash: o.tx_hash, at: o.block_time });

    const now = Number(head.timestamp);
    const ops = calls.rows.map((r) => {
      const readyAt = Number(r.scheduled_at) + Number(r.delay_seconds);
      const outcome = outcomeByOp.get(r.op_id);
      const status = outcome?.outcome ?? (now >= readyAt ? "ready" : "pending");
      const target = abis.get(r.target);
      let call: { contract: string; function: string; args: unknown } | null = null;
      if (target) {
        try {
          const d = decodeFunctionData({ abi: target.abi, data: r.data as Hex });
          call = { contract: target.name, function: d.functionName, args: jsonSafe(d.args ?? []) };
        } catch {
          call = null;
        }
      }
      return {
        id: r.op_id,
        index: r.call_index,
        target: getAddress(r.target),
        value: r.value,
        data: r.data,
        predecessor: r.predecessor,
        salt: r.salt,
        delaySeconds: Number(r.delay_seconds),
        scheduledTx: r.scheduled_tx,
        scheduledAt: Number(r.scheduled_at),
        readyAt,
        secondsUntilReady: Math.max(0, readyAt - now),
        status,
        outcome: outcome ?? null,
        call,
      };
    });
    return { minDelaySeconds: Number(delay), blockTimestamp: now, timelock: c.timelock, operations: ops };
  });
}

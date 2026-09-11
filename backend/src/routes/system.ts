import type { FastifyInstance } from "fastify";
import type { AppContext } from "../context.js";
import { parseLimit } from "../http.js";

export function registerSystemRoutes(app: FastifyInstance, ctx: AppContext) {
  /** Liveness plus indexer lag: how far the database trails the chain head. */
  app.get("/health", async (_req, reply) => {
    const out: Record<string, unknown> = { status: "ok" };
    try {
      await ctx.db.query("SELECT 1");
      out.database = "ok";
    } catch {
      out.database = "down";
      out.status = "degraded";
    }
    try {
      const head = await ctx.reader.head();
      out.chainHead = Number(head.number);
      const cursor = await ctx.db.query(`SELECT block_number FROM indexer_cursor WHERE id = 'main'`).catch(() => ({ rows: [] }));
      const indexed = cursor.rows[0]?.block_number ?? null;
      out.indexedBlock = indexed;
      out.indexerLagBlocks = indexed === null ? null : Number(head.number) - Number(indexed);
      out.chain = "ok";
    } catch {
      out.chain = "down";
      out.status = "degraded";
    }
    return reply.status(out.status === "ok" ? 200 : 503).send(out);
  });

  /** Contract addresses and chain id for clients (no secrets: this is the deployment file). */
  app.get("/config", async () => ({
    chainId: ctx.deployment.chainId,
    contracts: ctx.deployment.contracts,
    markets: ctx.deployment.markets,
    guardian: ctx.deployment.guardian,
    timelockProposer: ctx.deployment.timelockProposer,
  }));

  app.get<{ Querystring: { limit?: string; name?: string } }>("/events", async (req) => {
    const res = await ctx.db.query(
      `SELECT tx_hash, log_index, block_number, block_time, contract, source, name, args
       FROM events WHERE ($1::text IS NULL OR name = $1) AND name <> 'ReserveDataUpdated'
       ORDER BY block_number DESC, log_index DESC LIMIT $2`,
      [req.query.name ?? null, parseLimit(req.query.limit)],
    );
    return { events: res.rows };
  });
}

import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

/** Local development default, shared by every service and the migrate CLI. */
export const DEFAULT_DATABASE_URL = "postgres://lending:lending@127.0.0.1:5475/lending";

export type Db = pg.Pool;
export type DbClient = pg.PoolClient;

// NUMERIC(78,0) columns come back as strings (never floats). BIGINT (int8) block numbers fit in a
// JS number for any realistic chain height, so parse those for convenience.
pg.types.setTypeParser(pg.types.builtins.INT8, (v) => Number(v));

export function createDb(connectionString: string, max = 10): Db {
  return new pg.Pool({ connectionString, max });
}

/** Run `fn` in a transaction: all of its writes commit together or none do. */
export async function withTransaction<T>(db: Db, fn: (client: DbClient) => Promise<T>): Promise<T> {
  const client = await db.connect();
  try {
    await client.query("BEGIN");
    const result = await fn(client);
    await client.query("COMMIT");
    return result;
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  } finally {
    client.release();
  }
}

const MIGRATIONS_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "migrations");

/**
 * Apply every migrations/NNN_*.sql not yet recorded, in order, each in its own transaction.
 * A Postgres advisory lock stops the indexer and API from migrating concurrently at startup.
 */
export async function migrate(db: Db, dir = MIGRATIONS_DIR): Promise<string[]> {
  const applied: string[] = [];
  const client = await db.connect();
  try {
    await client.query("SELECT pg_advisory_lock(727274)");
    await client.query(
      "CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())",
    );
    const done = new Set((await client.query<{ name: string }>("SELECT name FROM schema_migrations")).rows.map((r) => r.name));
    for (const file of readdirSync(dir).filter((f) => f.endsWith(".sql")).sort()) {
      if (done.has(file)) continue;
      await client.query("BEGIN");
      try {
        await client.query(readFileSync(join(dir, file), "utf8"));
        await client.query("INSERT INTO schema_migrations (name) VALUES ($1)", [file]);
        await client.query("COMMIT");
        applied.push(file);
      } catch (err) {
        await client.query("ROLLBACK");
        throw new Error(`migration ${file} failed: ${(err as Error).message}`);
      }
    }
  } finally {
    await client.query("SELECT pg_advisory_unlock(727274)").catch(() => undefined);
    client.release();
  }
  return applied;
}

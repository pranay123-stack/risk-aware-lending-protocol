import { createDb, migrate, DEFAULT_DATABASE_URL } from "./db.js";
import { env } from "./index.js";

const db = createDb(env("DATABASE_URL", DEFAULT_DATABASE_URL));
try {
  const applied = await migrate(db);
  console.log(applied.length ? `applied: ${applied.join(", ")}` : "database up to date");
} finally {
  await db.end();
}

import { migrate } from "@lending/shared/node";
import { buildApp } from "./app.js";
import { createContext } from "./context.js";
import { LiveHub } from "./ws.js";

const ctx = createContext("api");
await migrate(ctx.db);

const hub = new LiveHub(ctx.config.databaseUrl, ctx.log);
await hub.start();
const app = await buildApp(ctx, hub);

await app.listen({ port: ctx.config.port, host: ctx.config.host });
ctx.log.info({ port: ctx.config.port, docs: `http://localhost:${ctx.config.port}/docs` }, "api listening");

for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, async () => {
    ctx.log.info({ sig }, "shutting down");
    await app.close();
    await hub.stop();
    await ctx.db.end();
    process.exit(0);
  });
}

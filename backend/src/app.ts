import cors from "@fastify/cors";
import swagger from "@fastify/swagger";
import swaggerUi from "@fastify/swagger-ui";
import websocket from "@fastify/websocket";
import Fastify, { type FastifyInstance } from "fastify";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { AppContext } from "./context.js";
import { sendError } from "./http.js";
import { registerAccountRoutes } from "./routes/accounts.js";
import { registerAnalyticsRoutes } from "./routes/analytics.js";
import { registerGovernanceRoutes } from "./routes/governance.js";
import { registerLiquidationRoutes } from "./routes/liquidations.js";
import { registerMarketRoutes } from "./routes/markets.js";
import { registerOracleRoutes } from "./routes/oracle.js";
import { registerProtocolRoutes } from "./routes/protocol.js";
import { registerRiskRoutes } from "./routes/risk.js";
import { registerSystemRoutes } from "./routes/system.js";
import type { LiveHub } from "./ws.js";

export const OPENAPI_PATH = join(dirname(fileURLToPath(import.meta.url)), "..", "openapi.yaml");

export async function buildApp(
  ctx: AppContext,
  hub?: LiveHub,
  onRoute?: (route: { method: string | string[]; url: string }) => void,
): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });
  if (onRoute) app.addHook("onRoute", (r) => onRoute({ method: r.method, url: r.url }));

  await app.register(cors, { origin: ctx.config.corsOrigins, methods: ["GET"] });

  // The OpenAPI document is hand-written (openapi.yaml) and served as-is; a contract test
  // (test/openapi.test.ts) fails if a route and the spec disagree.
  await app.register(swagger, { mode: "static", specification: { path: OPENAPI_PATH, baseDir: dirname(OPENAPI_PATH) } });
  await app.register(swaggerUi, { routePrefix: "/docs" });
  app.get("/openapi.json", async () => app.swagger());

  app.setErrorHandler((err, _req, reply) => sendError(reply, err));
  app.setNotFoundHandler((_req, reply) => reply.status(404).send({ error: { code: "NOT_FOUND", message: "no such route" } }));

  // Everything the chain or the database returns may contain bigints.
  app.setReplySerializer((payload) => JSON.stringify(payload, (_k, v) => (typeof v === "bigint" ? v.toString() : v)));

  registerSystemRoutes(app, ctx);
  registerMarketRoutes(app, ctx);
  registerAccountRoutes(app, ctx);
  registerProtocolRoutes(app, ctx);
  registerLiquidationRoutes(app, ctx);
  registerAnalyticsRoutes(app, ctx);
  registerRiskRoutes(app, ctx);
  registerOracleRoutes(app, ctx);
  registerGovernanceRoutes(app, ctx);

  if (hub) {
    await app.register(websocket);
    app.get("/ws", { websocket: true }, (socket) => hub.add(socket));
  }
  return app;
}

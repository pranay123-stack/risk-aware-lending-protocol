import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { parse } from "yaml";
import { OPENAPI_PATH, buildApp } from "../src/app.js";
import { LiveHub } from "../src/ws.js";
import { stubContext } from "./fixtures.js";

/**
 * Contract test: the hand-written OpenAPI document and the registered routes must match exactly.
 * Adding an endpoint without documenting it (or documenting one that does not exist) fails here.
 */
describe("OpenAPI contract", () => {
  it("documents every route and nothing else", async () => {
    const routes = new Set<string>();
    const ctx = stubContext({} as never, {});
    const app = await buildApp(ctx, new LiveHub("postgres://unused", ctx.log), (r) => {
      const methods = Array.isArray(r.method) ? r.method : [r.method];
      if (!methods.includes("GET")) return;
      if (r.url.startsWith("/docs") || r.url === "/openapi.json") return; // tooling, not API surface
      routes.add(r.url.replace(/:(\w+)/g, "{$1}"));
    });
    await app.ready();

    const spec = parse(readFileSync(OPENAPI_PATH, "utf8")) as { paths: Record<string, Record<string, unknown>> };
    const documented = new Set(Object.entries(spec.paths).filter(([, ops]) => "get" in ops).map(([p]) => p));

    expect([...routes].sort()).toEqual([...documented].sort());
    await app.close();
  });

  it("serves the document at /openapi.json", async () => {
    const app = await buildApp(stubContext({} as never, {}));
    const res = await app.inject({ method: "GET", url: "/openapi.json" });
    expect(res.statusCode).toBe(200);
    expect(res.json().openapi).toBe("3.0.3");
    await app.close();
  });

  it("returns a typed error envelope for bad input", async () => {
    const app = await buildApp(stubContext({} as never, {}));
    const res = await app.inject({ method: "GET", url: "/accounts/not-an-address" });
    expect(res.statusCode).toBe(400);
    expect(res.json()).toEqual({ error: { code: "INVALID_ADDRESS", message: "address must be a 20-byte hex address" } });
    const missing = await app.inject({ method: "GET", url: "/nope" });
    expect(missing.statusCode).toBe(404);
    await app.close();
  });
});

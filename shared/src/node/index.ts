// Node-only entry point (fs, pg, pino). Never import from the browser.
import { readFileSync } from "node:fs";
import { pino, type Logger } from "pino";
import { parseDeployment, type Deployment } from "../deployment.js";

export * from "./db.js";

export function loadDeploymentFile(path: string): Deployment {
  return parseDeployment(JSON.parse(readFileSync(path, "utf8")));
}

export function createLogger(name: string, level = process.env.LOG_LEVEL ?? "info"): Logger {
  return pino({ name, level });
}

export type { Logger };

/** Required env var, with an optional default. Fails fast at startup instead of mid-request. */
export function env(name: string, fallback?: string): string {
  const v = process.env[name] ?? fallback;
  if (v === undefined || v === "") throw new Error(`missing required environment variable ${name}`);
  return v;
}

export function envInt(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n)) throw new Error(`${name} must be an integer, got ${raw}`);
  return n;
}

export function envBool(name: string, fallback: boolean): boolean {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  return raw === "1" || raw.toLowerCase() === "true";
}

import type { FastifyReply } from "fastify";
import { getAddress, isAddress, type Address } from "viem";

/** Uniform error envelope: { error: { code, message } }. */
export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

export function parseAddress(value: unknown, field = "address"): Address {
  if (typeof value !== "string" || !isAddress(value, { strict: false })) {
    throw new HttpError(400, "INVALID_ADDRESS", `${field} must be a 20-byte hex address`);
  }
  return getAddress(value);
}

export function parseLimit(value: unknown, fallback = 50, max = 500): number {
  if (value === undefined) return fallback;
  const n = Number(value);
  if (!Number.isInteger(n) || n < 1) throw new HttpError(400, "INVALID_LIMIT", "limit must be a positive integer");
  return Math.min(n, max);
}

export function parseOffset(value: unknown): number {
  if (value === undefined) return 0;
  const n = Number(value);
  if (!Number.isInteger(n) || n < 0) throw new HttpError(400, "INVALID_OFFSET", "offset must be a non-negative integer");
  return n;
}

export function sendError(reply: FastifyReply, err: unknown) {
  if (err instanceof HttpError) {
    return reply.status(err.status).send({ error: { code: err.code, message: err.message } });
  }
  const e = err as { statusCode?: number; code?: string; message?: string };
  if (e.statusCode && e.statusCode < 500) {
    return reply.status(e.statusCode).send({ error: { code: e.code ?? "BAD_REQUEST", message: e.message ?? "bad request" } });
  }
  return reply.status(502).send({ error: { code: "UPSTREAM_ERROR", message: "chain or database unavailable" } });
}

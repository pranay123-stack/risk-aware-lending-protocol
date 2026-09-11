import type { Logger } from "@lending/shared/node";
import pg from "pg";
import type { WebSocket } from "ws";

export const CHANNELS = ["lending_events", "risk_alerts"] as const;

/**
 * Bridges Postgres LISTEN/NOTIFY to WebSocket clients. The indexer and the monitor publish with
 * pg_notify inside their own transactions, so a message is only ever sent for committed data. The
 * API process relays it without knowing anything about how it was produced.
 */
export class LiveHub {
  private readonly clients = new Set<WebSocket>();
  private listener: pg.Client | null = null;
  private stopped = false;

  constructor(
    private readonly databaseUrl: string,
    private readonly log: Logger,
  ) {}

  get clientCount(): number {
    return this.clients.size;
  }

  add(socket: WebSocket) {
    this.clients.add(socket);
    socket.on("close", () => this.clients.delete(socket));
    socket.on("error", () => this.clients.delete(socket));
    socket.send(JSON.stringify({ type: "hello", channels: CHANNELS }));
  }

  broadcast(message: unknown) {
    const data = JSON.stringify(message);
    for (const c of this.clients) {
      if (c.readyState === c.OPEN) c.send(data);
    }
  }

  async start(): Promise<void> {
    if (this.stopped) return;
    const client = new pg.Client({ connectionString: this.databaseUrl });
    client.on("notification", (n) => {
      let payload: unknown = n.payload;
      try {
        payload = JSON.parse(n.payload ?? "null");
      } catch {
        /* forward raw */
      }
      this.broadcast({ channel: n.channel, ...(typeof payload === "object" && payload ? payload : { payload }) });
    });
    client.on("error", (err) => {
      this.log.warn({ err }, "LISTEN connection lost; reconnecting");
      this.listener = null;
      setTimeout(() => void this.start().catch(() => undefined), 2_000);
    });
    try {
      await client.connect();
      for (const ch of CHANNELS) await client.query(`LISTEN ${ch}`);
      this.listener = client;
    } catch (err) {
      this.log.warn({ err }, "LISTEN connect failed; retrying");
      setTimeout(() => void this.start().catch(() => undefined), 2_000);
    }
  }

  async stop(): Promise<void> {
    this.stopped = true;
    for (const c of this.clients) c.close();
    await this.listener?.end().catch(() => undefined);
  }
}

"use client";

import { useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { WS_URL } from "./api";

export type LiveStatus = "connecting" | "live" | "offline";

/**
 * Subscribes to the API's WebSocket (Postgres NOTIFY relayed from the indexer and risk monitor)
 * and invalidates exactly the queries each message affects. Reconnects with backoff.
 */
export function useLiveUpdates(): { status: LiveStatus; lastEventAt: number | null } {
  const queryClient = useQueryClient();
  const [status, setStatus] = useState<LiveStatus>("connecting");
  const [lastEventAt, setLastEventAt] = useState<number | null>(null);

  useEffect(() => {
    let socket: WebSocket | null = null;
    let retry = 0;
    let closed = false;
    let timer: ReturnType<typeof setTimeout> | undefined;

    const connect = () => {
      setStatus("connecting");
      socket = new WebSocket(WS_URL);
      socket.onopen = () => {
        retry = 0;
        setStatus("live");
      };
      socket.onmessage = (msg) => {
        let data: { channel?: string; type?: string } = {};
        try {
          data = JSON.parse(msg.data);
        } catch {
          return;
        }
        if (data.type === "hello") return;
        setLastEventAt(Date.now());
        if (data.channel === "risk_alerts") {
          void queryClient.invalidateQueries({ queryKey: ["risk"] });
          void queryClient.invalidateQueries({ queryKey: ["liquidations", "candidates"] });
          return;
        }
        // New indexed batch or reorg: anything derived from chain state may have changed.
        for (const key of ["markets", "account", "protocol", "liquidations", "events", "analytics", "timelock", "oracle"]) {
          void queryClient.invalidateQueries({ queryKey: [key] });
        }
      };
      socket.onclose = () => {
        if (closed) return;
        setStatus("offline");
        timer = setTimeout(connect, Math.min(15_000, 1_000 * 2 ** retry++));
      };
      socket.onerror = () => socket?.close();
    };
    connect();
    return () => {
      closed = true;
      clearTimeout(timer);
      socket?.close();
    };
  }, [queryClient]);

  return { status, lastEventAt };
}

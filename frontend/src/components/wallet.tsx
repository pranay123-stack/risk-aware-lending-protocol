"use client";

import clsx from "clsx";
import { ChevronDown, LogOut, Wallet } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { useAccount, useConnect, useDisconnect } from "wagmi";
import { shortAddress } from "@/lib/format";
import { DEV_ACCOUNTS } from "@/lib/wagmi";
import { Button } from "./ui";

export function WalletButton() {
  const { address, connector, isConnected } = useAccount();
  const { connectors, connect, isPending } = useConnect();
  const { disconnect, disconnectAsync } = useDisconnect();
  const [open, setOpen] = useState(false);
  const [mounted, setMounted] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => setMounted(true), []);
  useEffect(() => {
    const close = (e: MouseEvent) => ref.current && !ref.current.contains(e.target as Node) && setOpen(false);
    document.addEventListener("mousedown", close);
    return () => document.removeEventListener("mousedown", close);
  }, []);

  if (!mounted) return <Button variant="secondary" size="sm" disabled>Wallet</Button>;

  const dev = DEV_ACCOUNTS.find((a) => a.address.toLowerCase() === address?.toLowerCase());
  const injected = connectors.find((c) => c.type === "injected");
  const devConnectors = connectors.filter((c) => c.type === "anvil-dev");

  return (
    <div className="relative" ref={ref}>
      {isConnected ? (
        <Button variant="secondary" size="sm" onClick={() => setOpen((o) => !o)}>
          <span className="h-2 w-2 rounded-full bg-good" />
          {dev ? dev.label : shortAddress(address)}
          <span className="num text-fg-3">{dev ? shortAddress(address) : connector?.name}</span>
          <ChevronDown size={14} />
        </Button>
      ) : (
        <Button size="sm" onClick={() => setOpen((o) => !o)} disabled={isPending}>
          <Wallet size={14} /> {isPending ? "Connecting…" : "Connect wallet"}
        </Button>
      )}

      {open && (
        <div className="absolute right-0 z-50 mt-2 w-80 rounded-xl border border-line bg-surface p-2 shadow-2xl">
          {injected && (
            <button
              className="flex w-full items-center gap-3 rounded-lg px-3 py-2 text-left text-sm hover:bg-surface-2"
              onClick={() => {
                connect({ connector: injected });
                setOpen(false);
              }}
            >
              <Wallet size={16} className="text-fg-2" />
              <span>
                <span className="block font-medium text-fg">Browser wallet</span>
                <span className="block text-xs text-fg-3">MetaMask or any injected wallet (add the Anvil network)</span>
              </span>
            </button>
          )}
          {devConnectors.length > 0 && (
            <>
              <div className="mt-2 border-t border-line px-3 pb-1 pt-3 text-[11px] font-medium uppercase tracking-wide text-fg-3">
                Local demo accounts · Anvil unlocked, no keys in browser
              </div>
              {devConnectors.map((c) => {
                const acct = DEV_ACCOUNTS.find((a) => c.id === `anvil-${a.index}`)!;
                const active = acct.address.toLowerCase() === address?.toLowerCase();
                return (
                  <button
                    key={c.id}
                    className={clsx("flex w-full items-center justify-between rounded-lg px-3 py-2 text-left text-sm hover:bg-surface-2", active && "bg-surface-2")}
                    onClick={async () => {
                      setOpen(false);
                      if (active) return;
                      // Finish tearing down the old connection before opening the new one.
                      if (isConnected) await disconnectAsync();
                      connect({ connector: c });
                    }}
                  >
                    <span>
                      <span className="block font-medium text-fg">{acct.label}</span>
                      <span className="block text-xs text-fg-3">{acct.role}</span>
                    </span>
                    <span className="num text-xs text-fg-3">{shortAddress(acct.address)}</span>
                  </button>
                );
              })}
            </>
          )}
          {isConnected && (
            <button
              className="mt-2 flex w-full items-center gap-2 rounded-lg border-t border-line px-3 py-2 text-left text-sm text-fg-2 hover:bg-surface-2"
              onClick={() => {
                disconnect();
                setOpen(false);
              }}
            >
              <LogOut size={14} /> Disconnect
            </button>
          )}
        </div>
      )}
    </div>
  );
}

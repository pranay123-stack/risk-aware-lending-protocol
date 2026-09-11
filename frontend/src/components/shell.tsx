"use client";

import clsx from "clsx";
import {
  Activity,
  ArrowDownToLine,
  ArrowUpFromLine,
  BarChart3,
  Gavel,
  LayoutDashboard,
  Moon,
  Settings2,
  ShieldAlert,
  Store,
  Sun,
  Wallet,
  X,
} from "lucide-react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState, type ReactNode } from "react";
import { useProtocolStatus, useSystemHealth } from "@/lib/hooks";
import { useLiveUpdates } from "@/lib/live";
import { useToasts } from "@/lib/tx";
import { StatusBadge, toneColor } from "./ui";
import { WalletButton } from "./wallet";

const NAV = [
  { href: "/", label: "Dashboard", icon: LayoutDashboard },
  { href: "/markets", label: "Markets", icon: Store },
  { href: "/supply", label: "Supply", icon: ArrowDownToLine },
  { href: "/borrow", label: "Borrow", icon: ArrowUpFromLine },
  { href: "/portfolio", label: "Portfolio", icon: Wallet },
  { href: "/risk", label: "Risk", icon: ShieldAlert },
  { href: "/liquidations", label: "Liquidations", icon: Gavel },
  { href: "/analytics", label: "Analytics", icon: BarChart3 },
  { href: "/admin", label: "Admin", icon: Settings2 },
];

function ThemeToggle() {
  const [theme, setTheme] = useState<"dark" | "light">("dark");
  useEffect(() => {
    setTheme((document.documentElement.getAttribute("data-theme") as "dark" | "light") ?? "dark");
  }, []);
  const toggle = () => {
    const next = theme === "dark" ? "light" : "dark";
    setTheme(next);
    document.documentElement.setAttribute("data-theme", next);
    try {
      localStorage.setItem("theme", next);
    } catch {
      /* storage blocked: theme still applies for this session */
    }
  };
  return (
    <button onClick={toggle} className="rounded-lg p-2 text-fg-2 hover:bg-surface-2 hover:text-fg" aria-label="Toggle theme">
      {theme === "dark" ? <Sun size={16} /> : <Moon size={16} />}
    </button>
  );
}

function SystemStatus() {
  const { data: health, isError } = useSystemHealth();
  const { data: status } = useProtocolStatus();
  const live = useLiveUpdates();
  const lag = health?.indexerLagBlocks;
  return (
    <div className="hidden items-center gap-4 text-xs text-fg-3 md:flex">
      {isError || !health ? (
        <StatusBadge tone="critical">API offline</StatusBadge>
      ) : (
        <>
          <span className="num">block {health.chainHead ?? "–"}</span>
          <span className="inline-flex items-center gap-1.5" title="Blocks between chain head and the indexed database">
            <span className="h-1.5 w-1.5 rounded-full" style={{ background: toneColor(lag !== null && lag !== undefined && lag <= 2 ? "good" : "warning") }} />
            indexer {lag === null || lag === undefined ? "starting" : lag === 0 ? "in sync" : `${lag} behind`}
          </span>
          <span className="inline-flex items-center gap-1.5" title="WebSocket push from the indexer and risk monitor">
            <Activity size={12} style={{ color: toneColor(live.status === "live" ? "good" : live.status === "connecting" ? "warning" : "critical") }} />
            {live.status}
          </span>
        </>
      )}
      {status?.paused && <StatusBadge tone="critical">Protocol paused</StatusBadge>}
      {status?.liquidationsBlockedByGrace && <StatusBadge tone="warning">Liquidation grace period</StatusBadge>}
    </div>
  );
}

function Toasts() {
  const { toasts, dismiss } = useToasts();
  return (
    <div className="fixed bottom-4 right-4 z-50 flex w-96 max-w-[calc(100vw-2rem)] flex-col gap-2">
      {toasts.map((t) => (
        <div
          key={t.id}
          role="status"
          className="flex gap-3 rounded-xl border bg-surface p-3 shadow-2xl"
          style={{ borderColor: toneColor(t.tone === "success" ? "good" : t.tone === "error" ? "critical" : "info") }}
        >
          <div className="min-w-0 flex-1">
            <div className="text-sm font-medium text-fg">{t.title}</div>
            {t.body && <div className="mt-0.5 text-xs text-fg-2">{t.body}</div>}
          </div>
          <button onClick={() => dismiss(t.id)} className="text-fg-3 hover:text-fg" aria-label="Dismiss">
            <X size={14} />
          </button>
        </div>
      ))}
    </div>
  );
}

export function AppShell({ children }: { children: ReactNode }) {
  const path = usePathname();
  return (
    <div className="flex min-h-screen">
      <aside className="sticky top-0 hidden h-screen w-60 shrink-0 flex-col border-r border-line bg-surface lg:flex">
        <div className="px-5 py-5">
          <div className="flex items-center gap-2">
            <span className="flex h-7 w-7 items-center justify-center rounded-lg bg-accent text-sm font-bold text-white">R</span>
            <div className="leading-tight">
              <div className="text-sm font-semibold text-fg">Risk-Aware Lending</div>
              <div className="text-[11px] text-fg-3">local demo · mock assets</div>
            </div>
          </div>
        </div>
        <nav className="flex-1 space-y-0.5 px-3">
          {NAV.map(({ href, label, icon: Icon }) => {
            const active = href === "/" ? path === "/" : path.startsWith(href);
            return (
              <Link
                key={href}
                href={href}
                className={clsx(
                  "flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition-colors",
                  active ? "bg-accent-soft font-medium text-fg" : "text-fg-2 hover:bg-surface-2 hover:text-fg",
                )}
              >
                <Icon size={16} className={active ? "text-accent" : undefined} />
                {label}
              </Link>
            );
          })}
        </nav>
        <div className="border-t border-line px-5 py-4 text-[11px] leading-relaxed text-fg-3">
          Portfolio demo on a local Anvil chain. No real funds, keys or assets are ever involved.
        </div>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="sticky top-0 z-40 flex h-14 items-center justify-between gap-4 border-b border-line bg-bg/85 px-4 backdrop-blur sm:px-6">
          <nav className="flex gap-1 overflow-x-auto lg:hidden">
            {NAV.map(({ href, label }) => (
              <Link key={href} href={href} className={clsx("whitespace-nowrap rounded-md px-2 py-1 text-xs", path === href ? "bg-surface-2 text-fg" : "text-fg-3")}>
                {label}
              </Link>
            ))}
          </nav>
          <SystemStatus />
          <div className="flex items-center gap-2">
            <ThemeToggle />
            <WalletButton />
          </div>
        </header>
        <main className="mx-auto w-full max-w-7xl flex-1 px-4 py-8 sm:px-6">{children}</main>
      </div>
      <Toasts />
    </div>
  );
}

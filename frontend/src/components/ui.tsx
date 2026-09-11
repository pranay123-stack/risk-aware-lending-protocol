"use client";

import clsx from "clsx";
import { AlertOctagon, AlertTriangle, CheckCircle2, CircleHelp, Info, ShieldAlert } from "lucide-react";
import type { ButtonHTMLAttributes, ReactNode } from "react";
import type { PriceStatus, RiskLevel } from "@/lib/api";
import { assetColor } from "@/lib/colors";
import { healthFactor as fmtHf } from "@/lib/format";
import { LEVEL_META, levelFor } from "@/lib/risk";

export function Card({ children, className }: { children: ReactNode; className?: string }) {
  return <section className={clsx("rounded-xl border border-line bg-surface", className)}>{children}</section>;
}

export function CardHeader({ title, subtitle, right }: { title: ReactNode; subtitle?: ReactNode; right?: ReactNode }) {
  return (
    <header className="flex flex-wrap items-start justify-between gap-3 border-b border-line px-5 py-4">
      <div className="min-w-0">
        <h2 className="text-sm font-semibold text-fg">{title}</h2>
        {subtitle && <p className="mt-0.5 text-xs text-fg-3">{subtitle}</p>}
      </div>
      {right}
    </header>
  );
}

export function PageHeader({ title, subtitle, right }: { title: string; subtitle?: ReactNode; right?: ReactNode }) {
  return (
    <div className="mb-6 flex flex-wrap items-end justify-between gap-4">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight text-fg">{title}</h1>
        {subtitle && <p className="mt-1 max-w-3xl text-sm text-fg-2">{subtitle}</p>}
      </div>
      {right}
    </div>
  );
}

/** KPI tile. The figure is proportional (not tabular) and in the text color, never a series color. */
export function Stat({ label, value, sub, tone }: { label: string; value: ReactNode; sub?: ReactNode; tone?: Tone }) {
  return (
    <div className="rounded-xl border border-line bg-surface px-5 py-4">
      <div className="flex items-center gap-2 text-xs font-medium uppercase tracking-wide text-fg-3">
        {tone && <span className="h-1.5 w-1.5 rounded-full" style={{ background: toneColor(tone) }} />}
        {label}
      </div>
      <div className="mt-2 text-2xl font-semibold text-fg">{value}</div>
      {sub && <div className="mt-1 text-xs text-fg-2">{sub}</div>}
    </div>
  );
}

export type Tone = "good" | "warning" | "serious" | "critical" | "neutral" | "info";

export function toneColor(tone: Tone): string {
  return tone === "info" ? "var(--accent)" : `var(--${tone})`;
}

const TONE_ICON: Record<Tone, typeof Info> = {
  good: CheckCircle2,
  warning: AlertTriangle,
  serious: ShieldAlert,
  critical: AlertOctagon,
  neutral: CircleHelp,
  info: Info,
};

/** Status is never color alone: icon + label + color. */
export function StatusBadge({ tone, children, title }: { tone: Tone; children: ReactNode; title?: string }) {
  const Icon = TONE_ICON[tone];
  const color = toneColor(tone);
  return (
    <span
      title={title}
      className="inline-flex items-center gap-1 whitespace-nowrap rounded-md border px-1.5 py-0.5 text-xs font-medium"
      style={{ color, borderColor: `color-mix(in srgb, ${color} 35%, transparent)`, background: `color-mix(in srgb, ${color} 10%, transparent)` }}
    >
      <Icon size={12} strokeWidth={2.25} aria-hidden />
      {children}
    </span>
  );
}

export function RiskBadge({ level }: { level: RiskLevel }) {
  const meta = LEVEL_META[level];
  return (
    <StatusBadge tone={meta.tone} title={meta.hint}>
      {meta.label}
    </StatusBadge>
  );
}

export function HealthFactor({ value, priced = true, size = "md" }: { value: number | null; priced?: boolean; size?: "md" | "lg" }) {
  if (!priced) return <StatusBadge tone="neutral">Unpriceable</StatusBadge>;
  const level = levelFor(value);
  const color = toneColor(LEVEL_META[level].tone);
  return (
    <span className="inline-flex items-center gap-2">
      <span className={clsx("font-semibold", size === "lg" ? "text-3xl" : "text-sm num")} style={{ color }}>
        {fmtHf(value)}
      </span>
      <RiskBadge level={level} />
    </span>
  );
}

export function TokenIcon({ symbol, size = 22 }: { symbol: string; size?: number }) {
  return (
    <span
      className="inline-flex shrink-0 items-center justify-center rounded-full font-bold text-white"
      style={{ width: size, height: size, background: assetColor(symbol), fontSize: size * 0.42 }}
      aria-hidden
    >
      {symbol.slice(0, 1)}
    </span>
  );
}

export function Asset({ symbol, sub }: { symbol: string; sub?: ReactNode }) {
  return (
    <span className="inline-flex items-center gap-2.5">
      <TokenIcon symbol={symbol} />
      <span className="leading-tight">
        <span className="block font-medium text-fg">{symbol}</span>
        {sub && <span className="block text-xs text-fg-3">{sub}</span>}
      </span>
    </span>
  );
}

/** Utilization bar with the kink marked: the rate curve steepens past it. */
export function UtilBar({ value, kink }: { value: number; kink?: number }) {
  const tone: Tone = value >= 0.97 ? "critical" : kink !== undefined && value >= kink ? "warning" : "good";
  return (
    <div className="flex items-center gap-2">
      <div className="relative h-1.5 w-20 overflow-hidden rounded-full bg-surface-3">
        <div className="absolute inset-y-0 left-0 rounded-full" style={{ width: `${Math.min(100, value * 100)}%`, background: toneColor(tone) }} />
        {kink !== undefined && <div className="absolute inset-y-0 w-px bg-fg-3" style={{ left: `${kink * 100}%` }} title={`kink ${Math.round(kink * 100)}%`} />}
      </div>
      <span className="num text-xs text-fg-2">{(value * 100).toFixed(1)}%</span>
    </div>
  );
}

export function Button({
  variant = "primary",
  size = "md",
  className,
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: "primary" | "secondary" | "ghost" | "danger"; size?: "sm" | "md" }) {
  return (
    <button
      {...props}
      className={clsx(
        "inline-flex items-center justify-center gap-1.5 rounded-lg font-medium transition-colors disabled:cursor-not-allowed disabled:opacity-45",
        size === "sm" ? "h-8 px-3 text-xs" : "h-10 px-4 text-sm",
        variant === "primary" && "bg-accent text-white hover:bg-accent-hover",
        variant === "secondary" && "border border-line-strong bg-surface-2 text-fg hover:bg-surface-3",
        variant === "ghost" && "text-fg-2 hover:bg-surface-2 hover:text-fg",
        variant === "danger" && "bg-critical text-white hover:opacity-90",
        className,
      )}
    />
  );
}

export function Segmented<T extends string | number>({
  value,
  options,
  onChange,
}: {
  value: T;
  options: { value: T; label: string }[];
  onChange: (v: T) => void;
}) {
  return (
    <div className="inline-flex rounded-lg border border-line bg-surface-2 p-0.5" role="tablist">
      {options.map((o) => (
        <button
          key={String(o.value)}
          role="tab"
          aria-selected={o.value === value}
          onClick={() => onChange(o.value)}
          className={clsx(
            "rounded-md px-3 py-1 text-xs font-medium transition-colors",
            o.value === value ? "bg-surface-3 text-fg" : "text-fg-3 hover:text-fg-2",
          )}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

export function Callout({ tone, title, children }: { tone: Tone; title: string; children?: ReactNode }) {
  const Icon = TONE_ICON[tone];
  const color = toneColor(tone);
  return (
    <div
      className="flex gap-3 rounded-lg border px-4 py-3 text-sm"
      style={{ borderColor: `color-mix(in srgb, ${color} 35%, transparent)`, background: `color-mix(in srgb, ${color} 8%, transparent)` }}
    >
      <Icon size={16} className="mt-0.5 shrink-0" style={{ color }} aria-hidden />
      <div>
        <div className="font-medium text-fg">{title}</div>
        {children && <div className="mt-0.5 text-fg-2">{children}</div>}
      </div>
    </div>
  );
}

export function Empty({ children }: { children: ReactNode }) {
  return <div className="px-5 py-10 text-center text-sm text-fg-3">{children}</div>;
}

/** Only for the very first load; refetches keep previous data on screen. */
export function Skeleton({ className }: { className?: string }) {
  return <div className={clsx("animate-pulse rounded-md bg-surface-2", className)} />;
}

export function Th({ children, right }: { children?: ReactNode; right?: boolean }) {
  return <th className={clsx("px-5 py-2.5 text-xs font-medium text-fg-3", right ? "text-right" : "text-left")}>{children}</th>;
}

export function Td({ children, right, className }: { children?: ReactNode; right?: boolean; className?: string }) {
  return <td className={clsx("px-5 py-3 text-sm", right && "num text-right", className)}>{children}</td>;
}

export function Table({ children }: { children: ReactNode }) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full border-collapse">{children}</table>
    </div>
  );
}

export function Row({ children, onClick }: { children: ReactNode; onClick?: () => void }) {
  return (
    <tr onClick={onClick} className={clsx("border-t border-line", onClick && "cursor-pointer hover:bg-surface-2")}>
      {children}
    </tr>
  );
}

export function KeyValue({ items }: { items: [ReactNode, ReactNode][] }) {
  return (
    <dl className="divide-y divide-line">
      {items.map(([k, v], i) => (
        <div key={i} className="flex items-center justify-between gap-4 px-5 py-2.5 text-sm">
          <dt className="text-fg-3">{k}</dt>
          <dd className="num text-right text-fg">{v}</dd>
        </div>
      ))}
    </dl>
  );
}

export function PriceBadge({ status }: { status: PriceStatus }) {
  if (status === "OK") return <StatusBadge tone="good">Live</StatusBadge>;
  if (status === "OK_PRIMARY_ONLY" || status === "OK_FALLBACK") return <StatusBadge tone="warning">Degraded</StatusBadge>;
  const label = status === "PAUSED" ? "Paused" : status === "DEVIATION" ? "Deviation" : status === "NOT_CONFIGURED" ? "No oracle" : "Unavailable";
  return <StatusBadge tone="critical">{label}</StatusBadge>;
}

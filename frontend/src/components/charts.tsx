"use client";

import { useState, type ReactNode } from "react";
import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  Line,
  LineChart,
  ReferenceDot,
  ReferenceLine,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
  type TooltipContentProps,
} from "recharts";
import { Card, CardHeader, Empty, Segmented, Table, Td, Th } from "./ui";

/**
 * Chart conventions (dataviz skill): one y-axis per chart, 2px lines, 8px active markers with a
 * 2px surface ring, solid hairline grid, crosshair tooltip, legend for >= 2 series, a 2px surface
 * gap between stacked segments, and a table view for every chart (values never color-only).
 */
export interface Series {
  key: string;
  label: string;
  color: string;
}

type Fmt = (v: number) => string;

function Legend({ series }: { series: Series[] }) {
  if (series.length < 2) return null;
  return (
    <div className="flex flex-wrap items-center gap-4 px-5 pt-3 text-xs text-fg-2">
      {series.map((s) => (
        <span key={s.key} className="inline-flex items-center gap-1.5">
          <span className="h-2 w-3 rounded-sm" style={{ background: s.color }} />
          {s.label}
        </span>
      ))}
    </div>
  );
}

function TooltipBox({ active, payload, label, series, yFormat, xFormat }: TooltipContentProps<number, string> & { series: Series[]; yFormat: Fmt; xFormat?: (v: unknown) => string }) {
  if (!active || !payload?.length) return null;
  return (
    <div className="rounded-lg border border-line-strong bg-surface px-3 py-2 text-xs shadow-xl">
      <div className="mb-1 text-fg-3">{xFormat ? xFormat(label) : String(label)}</div>
      {series.map((s) => {
        const p = payload.find((x) => x.dataKey === s.key);
        if (!p || p.value === undefined || p.value === null) return null;
        return (
          <div key={s.key} className="flex items-center justify-between gap-6">
            <span className="inline-flex items-center gap-1.5 text-fg-2">
              <span className="h-2 w-2 rounded-full" style={{ background: s.color }} />
              {s.label}
            </span>
            <span className="num font-medium text-fg">{yFormat(Number(p.value))}</span>
          </div>
        );
      })}
    </div>
  );
}

export function ChartCard({
  title,
  subtitle,
  series,
  table,
  children,
  height = 260,
  empty,
}: {
  title: string;
  subtitle?: string;
  series: Series[];
  table: { columns: string[]; rows: ReactNode[][] };
  children: ReactNode;
  height?: number;
  empty?: boolean;
}) {
  const [view, setView] = useState<"chart" | "table">("chart");
  return (
    <Card>
      <CardHeader
        title={title}
        subtitle={subtitle}
        right={<Segmented value={view} onChange={setView} options={[{ value: "chart", label: "Chart" }, { value: "table", label: "Table" }]} />}
      />
      {empty ? (
        <Empty>No data in this window yet. The monitor records a snapshot every 30 seconds.</Empty>
      ) : view === "chart" ? (
        <>
          <Legend series={series} />
          {/* Height includes the x-axis band: the container never clips tick labels. */}
          <div className="px-2 pb-3 pt-2" style={{ height }}>
            {children}
          </div>
        </>
      ) : (
        <div className="max-h-80 overflow-y-auto">
          <Table>
            <thead>
              <tr>
                {table.columns.map((c, i) => (
                  <Th key={c} right={i > 0}>
                    {c}
                  </Th>
                ))}
              </tr>
            </thead>
            <tbody>
              {table.rows.map((r, i) => (
                <tr key={i} className="border-t border-line">
                  {r.map((cell, j) => (
                    <Td key={j} right={j > 0}>
                      {cell}
                    </Td>
                  ))}
                </tr>
              ))}
            </tbody>
          </Table>
        </div>
      )}
    </Card>
  );
}

const axis = { stroke: "var(--grid)", tickLine: false, axisLine: false } as const;
const activeDot = (color: string) => ({ r: 4, fill: color, stroke: "var(--surface-1)", strokeWidth: 2 });

export function TimeSeries({
  data,
  xKey,
  series,
  yFormat,
  xFormat,
  area = false,
  yDomain,
  curve = "linear",
}: {
  data: Record<string, unknown>[];
  xKey: string;
  series: Series[];
  yFormat: Fmt;
  xFormat: (v: unknown) => string;
  area?: boolean;
  yDomain?: [number | "auto", number | "auto"];
  /** "stepAfter" for piecewise-constant series (rates between updates); never smoothed. */
  curve?: "linear" | "stepAfter";
}) {
  const Chart = area ? AreaChart : LineChart;
  return (
    <ResponsiveContainer width="100%" height="100%">
      <Chart data={data} margin={{ top: 8, right: 16, bottom: 0, left: 8 }}>
        <CartesianGrid vertical={false} />
        <XAxis dataKey={xKey} tickFormatter={xFormat} minTickGap={40} {...axis} />
        <YAxis tickFormatter={yFormat} width={64} domain={yDomain ?? ["auto", "auto"]} {...axis} />
        <Tooltip
          cursor={{ stroke: "var(--border-strong)", strokeWidth: 1 }}
          content={(p) => <TooltipBox {...(p as TooltipContentProps<number, string>)} series={series} yFormat={yFormat} xFormat={xFormat} />}
        />
        {series.map((s) =>
          area ? (
            <Area key={s.key} type={curve} dataKey={s.key} stroke={s.color} strokeWidth={2} fill={s.color} fillOpacity={0.12} dot={false} activeDot={activeDot(s.color)} isAnimationActive={false} />
          ) : (
            <Line key={s.key} type={curve} dataKey={s.key} stroke={s.color} strokeWidth={2} dot={false} activeDot={activeDot(s.color)} connectNulls isAnimationActive={false} />
          ),
        )}
      </Chart>
    </ResponsiveContainer>
  );
}

/** Kinked rate curve with the market's current utilization marked on both curves. */
export function RateCurve({
  curve,
  utilization,
  kink,
  series,
}: {
  curve: { utilization: number; borrowApr: number; supplyApr: number }[];
  utilization: number;
  kink: number;
  series: Series[];
}) {
  const at = (key: "borrowApr" | "supplyApr") => {
    // interpolate on the 5%-step curve for the current marker
    const i = Math.min(curve.length - 2, Math.floor(utilization * 20));
    const a = curve[i]!;
    const b = curve[i + 1]!;
    const t = (utilization - a.utilization) / (b.utilization - a.utilization || 1);
    return a[key] + (b[key] - a[key]) * t;
  };
  const pctFmt = (v: number) => `${(v * 100).toFixed(0)}%`;
  return (
    <ResponsiveContainer width="100%" height="100%">
      <LineChart data={curve} margin={{ top: 8, right: 16, bottom: 0, left: 8 }}>
        <CartesianGrid vertical={false} />
        <XAxis dataKey="utilization" type="number" domain={[0, 1]} ticks={[0, 0.2, 0.4, 0.6, 0.8, 1]} tickFormatter={pctFmt} {...axis} />
        <YAxis tickFormatter={pctFmt} width={48} {...axis} />
        <Tooltip
          cursor={{ stroke: "var(--border-strong)", strokeWidth: 1 }}
          content={(p) => (
            <TooltipBox {...(p as TooltipContentProps<number, string>)} series={series} yFormat={(v) => `${(v * 100).toFixed(2)}%`} xFormat={(v) => `utilization ${pctFmt(Number(v))}`} />
          )}
        />
        <ReferenceLine x={kink} stroke="var(--border-strong)" label={{ value: "kink", position: "insideTopRight", fill: "var(--text-muted)", fontSize: 11 }} />
        <ReferenceLine x={utilization} stroke="var(--text-muted)" label={{ value: "now", position: "insideTopLeft", fill: "var(--text-secondary)", fontSize: 11 }} />
        {series.map((s) => (
          <Line key={s.key} dataKey={s.key} stroke={s.color} strokeWidth={2} dot={false} activeDot={activeDot(s.color)} isAnimationActive={false} />
        ))}
        {series.map((s) => (
          <ReferenceDot key={`dot-${s.key}`} x={utilization} y={at(s.key as "borrowApr" | "supplyApr")} r={4} fill={s.color} stroke="var(--surface-1)" strokeWidth={2} />
        ))}
      </LineChart>
    </ResponsiveContainer>
  );
}

export function StackedBars({
  data,
  xKey,
  series,
  xFormat,
}: {
  data: Record<string, unknown>[];
  xKey: string;
  series: Series[];
  xFormat: (v: unknown) => string;
}) {
  return (
    <ResponsiveContainer width="100%" height="100%">
      <BarChart data={data} margin={{ top: 8, right: 16, bottom: 0, left: 8 }} maxBarSize={24}>
        <CartesianGrid vertical={false} />
        <XAxis dataKey={xKey} tickFormatter={xFormat} minTickGap={24} {...axis} />
        <YAxis allowDecimals={false} width={40} {...axis} />
        <Tooltip
          cursor={{ fill: "var(--surface-2)" }}
          content={(p) => <TooltipBox {...(p as TooltipContentProps<number, string>)} series={series} yFormat={(v) => String(v)} xFormat={xFormat} />}
        />
        {series.map((s, i) => (
          <Bar
            key={s.key}
            dataKey={s.key}
            stackId="a"
            fill={s.color}
            // 2px surface-colored gap between stacked segments; rounded data-end on the top segment only
            stroke="var(--surface-1)"
            strokeWidth={2}
            radius={i === series.length - 1 ? [4, 4, 0, 0] : 0}
            isAnimationActive={false}
          />
        ))}
      </BarChart>
    </ResponsiveContainer>
  );
}

"use client";

import { useMemo, useState } from "react";
import { ChartCard, StackedBars, TimeSeries, type Series } from "@/components/charts";
import { Asset, Card, CardHeader, Empty, PageHeader, Row, Segmented, Stat, Table, Td, Th } from "@/components/ui";
import { SERIES, assetColor } from "@/lib/colors";
import { pct, tokenAmount, usd } from "@/lib/format";
import { useAnalytics, useMarkets } from "@/lib/hooks";

const WINDOWS = [
  { value: 1, label: "1h" },
  { value: 24, label: "24h" },
  { value: 168, label: "7d" },
  { value: 720, label: "30d" },
];

const ACTIVITY: Series[] = [
  { key: "Supply", label: "Supply", color: SERIES[0] },
  { key: "Withdraw", label: "Withdraw", color: SERIES[1] },
  { key: "Borrow", label: "Borrow", color: SERIES[2] },
  { key: "Repay", label: "Repay", color: SERIES[3] },
  { key: "LiquidationCall", label: "Liquidation", color: SERIES[4] },
];

const time = (v: unknown) => new Date(String(v)).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
const dateTime = (v: unknown) => new Date(String(v)).toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });

export default function AnalyticsPage() {
  const [hours, setHours] = useState(24);
  const { data: a } = useAnalytics(hours);
  const { data: markets } = useMarkets();
  const xFmt = hours <= 24 ? time : dateTime;
  const symbolOf = (reserve: string) => markets?.find((m) => m.asset.toLowerCase() === reserve.toLowerCase())?.symbol ?? reserve.slice(0, 6);

  // Color follows the asset (fixed slots), never its rank in this window.
  const assetSeries: Series[] = (markets ?? []).map((m) => ({ key: m.symbol, label: m.symbol, color: assetColor(m.symbol) }));

  const utilization = useMemo(() => {
    const rows = new Map<string, Record<string, unknown>>();
    for (const u of a?.utilizationHistory ?? []) {
      const row = rows.get(u.t) ?? { t: u.t };
      row[u.symbol] = u.utilization;
      rows.set(u.t, row);
    }
    return [...rows.values()];
  }, [a]);

  const rates = useMemo(() => {
    const rows: Record<string, unknown>[] = [];
    for (const r of a?.rateHistory ?? []) rows.push({ t: r.block_time, [symbolOf(r.reserve)]: r.borrow_apr });
    return rows;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [a, markets]);

  const activity = useMemo(() => {
    const rows = new Map<string, Record<string, unknown>>();
    for (const x of a?.activity ?? []) {
      const row = rows.get(x.bucket) ?? { bucket: x.bucket };
      row[x.name] = x.n;
      rows.set(x.bucket, row);
    }
    return [...rows.values()];
  }, [a]);

  const tvl = a?.tvlHistory ?? [];

  return (
    <>
      <PageHeader
        title="Analytics"
        subtitle="Snapshots from the risk monitor (every 30 s) and history from indexed events."
        right={<Segmented value={hours} onChange={setHours} options={WINDOWS} />}
      />

      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Stat label="Total supplied" value={usd(a?.totals.totalSuppliedUsd, { compact: true })} sub={`${a?.users ?? "–"} accounts have interacted`} />
        <Stat label="Total borrowed" value={usd(a?.totals.totalBorrowedUsd, { compact: true })} sub={`${pct(a?.totals.utilization, 1)} utilization`} />
        <Stat label="Liquidations" value={a?.liquidations.n ?? "–"} sub={a ? `${a.liquidations.borrowers} borrowers · ${a.liquidations.liquidators} liquidators` : ""} />
        <Stat label="Treasury (reserve factor)" value={usd(a?.totals.treasuryUsd)} sub={`deficit ${usd(a?.totals.deficitUsd)}`} tone={a?.totals.deficitUsd ? "critical" : undefined} />
      </div>

      <div className="mt-6 grid gap-6 lg:grid-cols-2">
        <ChartCard
          title="Supplied vs borrowed (USD)"
          series={[
            { key: "suppliedUsd", label: "Supplied", color: SERIES[0] },
            { key: "borrowedUsd", label: "Borrowed", color: SERIES[1] },
          ]}
          empty={tvl.length < 2}
          table={{ columns: ["Time", "Supplied", "Borrowed"], rows: tvl.slice().reverse().map((r) => [dateTime(r.t), usd(r.suppliedUsd), usd(r.borrowedUsd)]) }}
        >
          <TimeSeries
            data={tvl}
            xKey="t"
            area
            series={[
              { key: "suppliedUsd", label: "Supplied", color: SERIES[0] },
              { key: "borrowedUsd", label: "Borrowed", color: SERIES[1] },
            ]}
            yFormat={(v) => usd(v, { compact: true })}
            xFormat={xFmt}
            yDomain={[0, "auto"]}
          />
        </ChartCard>

        <ChartCard
          title="Utilization by market"
          subtitle="Past each market's kink, rates climb steeply"
          series={assetSeries}
          empty={utilization.length < 2}
          table={{ columns: ["Time", ...assetSeries.map((s) => s.label)], rows: utilization.slice().reverse().map((r) => [dateTime(r.t), ...assetSeries.map((s) => pct(r[s.key] as number, 1))]) }}
        >
          <TimeSeries data={utilization} xKey="t" series={assetSeries} yFormat={(v) => `${Math.round(v * 100)}%`} xFormat={xFmt} yDomain={[0, 1]} />
        </ChartCard>

        <ChartCard
          title="Borrow APR by market"
          subtitle="Every rate recomputation (indexed ReserveDataUpdated), last 100 per market"
          series={assetSeries}
          empty={rates.length < 2}
          table={{
            columns: ["Time", "Market", "Borrow APR"],
            rows: (a?.rateHistory ?? []).slice().reverse().map((r) => [dateTime(r.block_time), symbolOf(r.reserve), pct(r.borrow_apr)]),
          }}
        >
          <TimeSeries data={rates} xKey="t" curve="stepAfter" series={assetSeries} yFormat={(v) => `${(v * 100).toFixed(1)}%`} xFormat={xFmt} />
        </ChartCard>

        <ChartCard
          title="Activity per hour"
          subtitle="User actions by type"
          series={ACTIVITY}
          empty={activity.length === 0}
          table={{ columns: ["Hour", ...ACTIVITY.map((s) => s.label)], rows: activity.slice().reverse().map((r) => [dateTime(r.bucket), ...ACTIVITY.map((s) => String(r[s.key] ?? 0))]) }}
        >
          <StackedBars data={activity} xKey="bucket" series={ACTIVITY} xFormat={xFmt} />
        </ChartCard>
      </div>

      <div className="mt-6 grid gap-6 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <CardHeader title="Markets" />
          <Table>
            <thead>
              <tr>
                <Th>Asset</Th>
                <Th right>Supplied</Th>
                <Th right>Borrowed</Th>
                <Th right>Utilization</Th>
                <Th right>Supply APY</Th>
                <Th right>Borrow APY</Th>
              </tr>
            </thead>
            <tbody>
              {a?.markets.map((m) => (
                <Row key={m.asset}>
                  <Td>
                    <Asset symbol={m.symbol} />
                  </Td>
                  <Td right>{usd(m.suppliedUsd)}</Td>
                  <Td right>{usd(m.borrowedUsd)}</Td>
                  <Td right>{pct(m.utilization, 1)}</Td>
                  <Td right className={m.supplyApy > 0 ? "text-good" : "text-fg-3"}>{pct(m.supplyApy)}</Td>
                  <Td right>{pct(m.borrowApy)}</Td>
                </Row>
              ))}
            </tbody>
          </Table>
        </Card>
        <Card>
          <CardHeader title="Bad debt" subtitle="Write-offs after collateral ran out" />
          {!a?.badDebt.length ? (
            <Empty>No bad debt recognised.</Empty>
          ) : (
            <Table>
              <thead>
                <tr>
                  <Th>Market</Th>
                  <Th right>Written off</Th>
                  <Th right>Treasury covered</Th>
                </tr>
              </thead>
              <tbody>
                {a.badDebt.map((b) => {
                  const m = markets?.find((x) => x.asset.toLowerCase() === b.reserve.toLowerCase());
                  const d = m?.decimals ?? 18;
                  return (
                    <Row key={b.reserve}>
                      <Td>{symbolOf(b.reserve)}</Td>
                      <Td right>{tokenAmount(Number(b.amount) / 10 ** d, m?.symbol)}</Td>
                      <Td right>{tokenAmount(Number(b.covered) / 10 ** d, m?.symbol)}</Td>
                    </Row>
                  );
                })}
              </tbody>
            </Table>
          )}
        </Card>
      </div>
    </>
  );
}

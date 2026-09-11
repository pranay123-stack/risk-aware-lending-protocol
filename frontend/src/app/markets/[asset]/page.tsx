"use client";

import Link from "next/link";
import { use } from "react";
import { ChartCard, RateCurve, TimeSeries } from "@/components/charts";
import { Asset, Card, CardHeader, KeyValue, PageHeader, PriceBadge, Skeleton, Stat, StatusBadge } from "@/components/ui";
import { SERIES } from "@/lib/colors";
import { duration, pct, shortAddress, tokenAmount, usd } from "@/lib/format";
import { useMarket, useOracle } from "@/lib/hooks";

export default function MarketPage({ params }: { params: Promise<{ asset: string }> }) {
  const { asset } = use(params);
  const { data, isLoading, error } = useMarket(asset);
  const { data: oracle } = useOracle();
  if (error) return <PageHeader title="Market not found" subtitle={(error as Error).message} />;
  if (isLoading || !data) return <Skeleton className="h-96" />;
  const m = data.market;
  const o = oracle?.assets.find((a) => a.asset.toLowerCase() === m.asset.toLowerCase());
  const curveSeries = [
    { key: "borrowApr", label: "Borrow APR", color: SERIES[0] },
    { key: "supplyApr", label: "Supply APR", color: SERIES[2] },
  ];
  const history = data.rateHistory.map((r) => ({ t: r.block_time, borrowApr: r.borrow_apr, supplyApr: r.supply_apr }));

  return (
    <>
      <div className="mb-2 text-xs text-fg-3">
        <Link href="/markets" className="hover:text-fg">Markets</Link> / {m.symbol}
      </div>
      <PageHeader
        title={`${m.symbol} market`}
        subtitle={<span className="inline-flex items-center gap-2">{usd(m.price.usd)} <PriceBadge status={m.price.status} /> {m.config.frozen && <StatusBadge tone="warning">Frozen</StatusBadge>} {m.config.paused && <StatusBadge tone="critical">Paused</StatusBadge>}</span>}
        right={<div className="flex gap-2"><Link className="rounded-lg bg-accent px-4 py-2 text-sm font-medium text-white" href={`/supply?asset=${m.symbol}`}>Supply</Link><Link className="rounded-lg border border-line-strong px-4 py-2 text-sm font-medium text-fg" href={`/borrow?asset=${m.symbol}`}>Borrow</Link></div>}
      />

      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Stat label="Total supplied" value={usd(m.totalSupplied.usd, { compact: true })} sub={tokenAmount(m.totalSupplied.amount, m.symbol)} />
        <Stat label="Total borrowed" value={usd(m.totalBorrowed.usd, { compact: true })} sub={tokenAmount(m.totalBorrowed.amount, m.symbol)} />
        <Stat label="Utilization" value={pct(m.utilization, 1)} sub={`kink at ${pct(m.interestRateModel.optimalUtilization, 0)}`} />
        <Stat label="Supply / borrow APY" value={`${pct(m.supplyApy)} / ${pct(m.borrowApy)}`} sub={`reserve factor ${pct(m.config.reserveFactor, 0)}`} />
      </div>

      <div className="mt-6 grid gap-6 lg:grid-cols-2">
        <ChartCard
          title="Interest rate model"
          subtitle="Rates as a function of utilization; the marker is the market now"
          series={curveSeries}
          table={{ columns: ["Utilization", "Borrow APR", "Supply APR"], rows: data.rateCurve.map((c) => [pct(c.utilization, 0), pct(c.borrowApr), pct(c.supplyApr)]) }}
        >
          <RateCurve curve={data.rateCurve} utilization={m.utilization} kink={m.interestRateModel.optimalUtilization} series={curveSeries} />
        </ChartCard>
        <ChartCard
          title="Rate history"
          subtitle="Recomputed on every interaction (indexed ReserveDataUpdated events)"
          series={curveSeries}
          empty={history.length < 2}
          table={{ columns: ["Time", "Borrow APR", "Supply APR"], rows: history.slice().reverse().map((h) => [new Date(h.t).toLocaleString(), pct(h.borrowApr), pct(h.supplyApr)]) }}
        >
          <TimeSeries data={history} xKey="t" curve="stepAfter" series={curveSeries} yFormat={(v) => `${(v * 100).toFixed(1)}%`} xFormat={(v) => new Date(String(v)).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })} />
        </ChartCard>
      </div>

      <div className="mt-6 grid gap-6 lg:grid-cols-3">
        <Card>
          <CardHeader title="Risk parameters" subtitle="Changed only through the timelock" />
          <KeyValue
            items={[
              ["Max LTV", pct(m.config.ltv, 1)],
              ["Liquidation threshold", pct(m.config.liquidationThreshold, 1)],
              ["Liquidation bonus", pct(m.config.liquidationBonus, 2)],
              ["LT × (1 + bonus)", `${pct(m.config.liquidationThreshold * (1 + m.config.liquidationBonus), 1)} (must stay < 100%)`],
              ["Reserve factor", pct(m.config.reserveFactor, 0)],
              ["Supply cap", Number(m.config.supplyCap) ? `${Number(m.config.supplyCap).toLocaleString()} ${m.symbol}` : "none"],
              ["Borrow cap", Number(m.config.borrowCap) ? `${Number(m.config.borrowCap).toLocaleString()} ${m.symbol}` : "none"],
              ["Borrowing", m.config.borrowingEnabled ? "enabled" : "disabled"],
              ["Collateral", m.config.collateralEnabled ? "enabled" : "disabled"],
            ]}
          />
        </Card>
        <Card>
          <CardHeader title="Rate model" subtitle={shortAddress(m.interestRateModel.address)} />
          <KeyValue
            items={[
              ["Base rate", pct(m.interestRateModel.baseRate)],
              ["Slope 1 (below kink)", pct(m.interestRateModel.slope1)],
              ["Slope 2 (above kink)", pct(m.interestRateModel.slope2)],
              ["Optimal utilization", pct(m.interestRateModel.optimalUtilization, 0)],
              ["Max borrow APR", pct(m.interestRateModel.baseRate + m.interestRateModel.slope1 + m.interestRateModel.slope2)],
              ["Treasury accrued", tokenAmount(m.treasury.amount, m.symbol)],
              ["Unrecovered bad debt", m.deficit.amount > 0 ? <span className="text-critical">{tokenAmount(m.deficit.amount, m.symbol)}</span> : "none"],
            ]}
          />
        </Card>
        <Card>
          <CardHeader title="Oracle" subtitle={o ? `${o.secondary ? `two sources, deviation limit ${(o.maxDeviationBps / 100).toFixed(1)}%` : "single source"} · bounds ${usd(o.bounds.min)}–${usd(o.bounds.max, { compact: true })}` : ""} />
          {o ? (
            <KeyValue
              items={[
                ["Resolved price", <span key="p" className="inline-flex items-center gap-2">{usd(o.price)} <PriceBadge status={o.status} /></span>],
                ["Primary feed", o.primary ? `${usd(o.primary.price)} · ${o.primary.status}` : "–"],
                ["Primary age / heartbeat", o.primary ? `${duration(o.primary.ageSeconds ?? 0)} / ${duration(o.primary.heartbeatSeconds)}` : "–"],
                ["Secondary feed", o.secondary ? `${usd(o.secondary.price)} · ${o.secondary.status}` : "not configured"],
                ["Guardian pause", o.paused ? <StatusBadge key="x" tone="critical">Paused</StatusBadge> : "no"],
              ]}
            />
          ) : (
            <Skeleton className="m-5 h-24" />
          )}
        </Card>
      </div>
      <div className="mt-4 text-xs text-fg-3">
        <Asset symbol={m.symbol} sub={m.asset} />
      </div>
    </>
  );
}

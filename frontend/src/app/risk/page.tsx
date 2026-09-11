"use client";

import Link from "next/link";
import { Asset, Card, CardHeader, Empty, PageHeader, PriceBadge, RiskBadge, Row, Stat, StatusBadge, Table, Td, Th, UtilBar, type Tone } from "@/components/ui";
import type { RiskLevel } from "@/lib/api";
import { duration, healthFactor, shortAddress, timeAgo, usd } from "@/lib/format";
import { useAlerts, useMarketRisk, useMarkets, useOracle, useRiskAccounts, useRiskSummary } from "@/lib/hooks";
import { LEVEL_META } from "@/lib/risk";

const SEVERITY_TONE: Record<string, Tone> = { info: "info", warning: "warning", critical: "critical" };
const LEVELS: RiskLevel[] = ["SAFE", "WARNING", "DANGER", "LIQUIDATABLE"];

function FeedAge({ age, heartbeat }: { age: number | null; heartbeat: number }) {
  if (age === null) return <span className="text-fg-3">–</span>;
  const share = age / heartbeat;
  const tone: Tone = share >= 1 ? "critical" : share >= 0.8 ? "warning" : "good";
  return (
    <div className="flex items-center justify-end gap-2">
      <div className="h-1.5 w-16 overflow-hidden rounded-full bg-surface-3">
        <div className="h-full rounded-full" style={{ width: `${Math.min(100, share * 100)}%`, background: `var(--${tone})` }} />
      </div>
      <span className="num text-xs text-fg-2">
        {duration(age)} / {duration(heartbeat)}
      </span>
    </div>
  );
}

export default function RiskPage() {
  const { data: summary } = useRiskSummary();
  const { data: alerts } = useAlerts();
  const { data: accounts } = useRiskAccounts();
  const { data: marketRisk } = useMarketRisk();
  const { data: oracle } = useOracle();
  const { data: markets } = useMarkets();
  const symbolFor = (subject: string) => markets?.find((m) => m.asset.toLowerCase() === subject.toLowerCase())?.symbol;

  return (
    <>
      <PageHeader
        title="Risk monitor"
        subtitle={
          summary?.lastSweep
            ? `Every account the indexer has seen, valued live through PoolLens. Last sweep ${timeAgo(summary.lastSweep)} at block ${summary.lastSweepBlock}.`
            : "Waiting for the first monitor sweep…"
        }
      />

      <div className="grid grid-cols-2 gap-4 lg:grid-cols-5">
        {LEVELS.map((l) => (
          <Stat
            key={l}
            tone={LEVEL_META[l].tone}
            label={LEVEL_META[l].label}
            value={summary?.levels[l].accounts ?? "–"}
            sub={summary ? `${usd(summary.levels[l].debtUsd, { compact: true })} debt · ${LEVEL_META[l].hint}` : ""}
          />
        ))}
        <Stat
          tone={summary?.potentialBadDebtUsd ? "critical" : "good"}
          label="Potential bad debt"
          value={summary ? usd(summary.potentialBadDebtUsd, { compact: true }) : "–"}
          sub={summary ? `${summary.insolventAccounts} accounts with collateral < debt` : ""}
        />
      </div>

      <div className="mt-6 grid gap-6 xl:grid-cols-2">
        <Card>
          <CardHeader title="Open alerts" subtitle="One alert per condition; refreshed while it persists, resolved when it clears" />
          {!alerts?.length ? (
            <Empty>No open alerts.</Empty>
          ) : (
            <ul className="divide-y divide-line">
              {alerts.map((a) => (
                <li key={a.id} className="flex items-start gap-3 px-5 py-3">
                  <StatusBadge tone={SEVERITY_TONE[a.severity] ?? "neutral"}>{a.severity}</StatusBadge>
                  <div className="min-w-0 flex-1">
                    <div className="text-sm text-fg">{a.message}</div>
                    <div className="mt-0.5 text-xs text-fg-3">
                      {a.kind} · {symbolFor(a.subject) ?? shortAddress(a.subject)} · since {timeAgo(a.opened_at)}
                    </div>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </Card>

        <Card>
          <CardHeader title="Indebted accounts" subtitle="Riskiest first" right={<Link href="/liquidations" className="text-xs text-accent hover:underline">Liquidations →</Link>} />
          {!accounts?.length ? (
            <Empty>No indebted accounts.</Empty>
          ) : (
            <Table>
              <thead>
                <tr>
                  <Th>Account</Th>
                  <Th>Level</Th>
                  <Th right>Health</Th>
                  <Th right>Collateral</Th>
                  <Th right>Debt</Th>
                </tr>
              </thead>
              <tbody>
                {accounts.map((a) => (
                  <Row key={a.account}>
                    <Td>
                      <Link href={`/portfolio?address=${a.account}`} className="num text-accent hover:underline">
                        {shortAddress(a.account)}
                      </Link>
                    </Td>
                    <Td>
                      <RiskBadge level={a.level} />
                    </Td>
                    <Td right>{a.priced ? healthFactor(a.health_factor) : "–"}</Td>
                    <Td right>{usd(a.collateral_usd)}</Td>
                    <Td right>{usd(a.debt_usd)}</Td>
                  </Row>
                ))}
              </tbody>
            </Table>
          )}
        </Card>
      </div>

      <Card className="mt-6">
        <CardHeader title="Market and oracle health" subtitle="Utilization against the kink, and each price feed's age against its heartbeat" />
        <Table>
          <thead>
            <tr>
              <Th>Market</Th>
              <Th>Utilization</Th>
              <Th>Price</Th>
              <Th right>Primary feed age</Th>
              <Th right>Secondary feed</Th>
              <Th>Findings</Th>
            </tr>
          </thead>
          <tbody>
            {marketRisk?.map((m) => {
              const o = oracle?.assets.find((x) => x.asset.toLowerCase() === m.asset.toLowerCase());
              const mk = markets?.find((x) => x.asset.toLowerCase() === m.asset.toLowerCase());
              return (
                <Row key={m.asset}>
                  <Td>
                    <Asset symbol={m.symbol} />
                  </Td>
                  <Td>
                    <UtilBar value={m.utilization} kink={mk?.interestRateModel.optimalUtilization} />
                  </Td>
                  <Td>
                    <span className="inline-flex items-center gap-2">
                      <span className="num text-fg">{usd(o?.price)}</span>
                      <PriceBadge status={m.priceStatus} />
                    </span>
                  </Td>
                  <Td right>{o?.primary ? <FeedAge age={o.primary.ageSeconds} heartbeat={o.primary.heartbeatSeconds} /> : "–"}</Td>
                  <Td right className="text-fg-2">{o?.secondary ? `${usd(o.secondary.price)} · ${o.secondary.status}` : "none"}</Td>
                  <Td>
                    {m.findings.length === 0 ? (
                      <StatusBadge tone="good">Healthy</StatusBadge>
                    ) : (
                      <div className="flex flex-wrap gap-1">
                        {m.findings.map((f) => (
                          <StatusBadge key={f.kind} tone={SEVERITY_TONE[f.severity] ?? "neutral"} title={f.message}>
                            {f.kind.replaceAll("_", " ").toLowerCase()}
                          </StatusBadge>
                        ))}
                      </div>
                    )}
                  </Td>
                </Row>
              );
            })}
          </tbody>
        </Table>
      </Card>
    </>
  );
}

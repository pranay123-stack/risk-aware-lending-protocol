"use client";

import { useRouter } from "next/navigation";
import { Asset, Card, CardHeader, PageHeader, PriceBadge, Row, Skeleton, StatusBadge, Table, Td, Th, UtilBar } from "@/components/ui";
import type { Market } from "@/lib/api";
import { pct, tokenAmount, usd } from "@/lib/format";
import { useMarkets } from "@/lib/hooks";

function capUsage(used: number, cap: string): string {
  const c = Number(cap);
  return c === 0 ? "uncapped" : `${pct(used / c, 1)} of ${Number(cap).toLocaleString("en-US")}`;
}

function StatusCell({ m }: { m: Market }) {
  if (!m.config.active) return <StatusBadge tone="neutral">Inactive</StatusBadge>;
  if (m.config.paused) return <StatusBadge tone="critical">Paused</StatusBadge>;
  if (m.config.frozen) return <StatusBadge tone="warning">Frozen</StatusBadge>;
  return <PriceBadge status={m.price.status} />;
}

export default function MarketsPage() {
  const { data: markets, isLoading } = useMarkets();
  const router = useRouter();
  return (
    <>
      <PageHeader
        title="Markets"
        subtitle="Each reserve has its own risk parameters and a kinked rate model: cheap to borrow below the kink, sharply more expensive above it to keep withdrawals and liquidations liquid."
      />
      <Card>
        <CardHeader title="Reserves" subtitle="Select a market for its rate curve, rate history and oracle health" />
        {isLoading ? (
          <div className="space-y-2 p-5">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-12" />)}</div>
        ) : (
          <Table>
            <thead>
              <tr>
                <Th>Asset</Th>
                <Th>Status</Th>
                <Th right>Total supplied</Th>
                <Th right>Total borrowed</Th>
                <Th>Utilization / kink</Th>
                <Th right>Supply APY</Th>
                <Th right>Borrow APY</Th>
                <Th right>LTV · LT · bonus</Th>
                <Th right>Supply cap</Th>
              </tr>
            </thead>
            <tbody>
              {markets?.map((m) => (
                <Row key={m.asset} onClick={() => router.push(`/markets/${m.asset}`)}>
                  <Td>
                    <Asset symbol={m.symbol} sub={usd(m.price.usd)} />
                  </Td>
                  <Td>
                    <StatusCell m={m} />
                  </Td>
                  <Td right>
                    <div>{usd(m.totalSupplied.usd, { compact: true })}</div>
                    <div className="text-xs text-fg-3">{tokenAmount(m.totalSupplied.amount, m.symbol)}</div>
                  </Td>
                  <Td right>
                    <div>{usd(m.totalBorrowed.usd, { compact: true })}</div>
                    <div className="text-xs text-fg-3">{tokenAmount(m.totalBorrowed.amount, m.symbol)}</div>
                  </Td>
                  <Td>
                    <UtilBar value={m.utilization} kink={m.interestRateModel.optimalUtilization} />
                  </Td>
                  <Td right className={m.supplyApy > 0 ? "text-good" : "text-fg-3"}>{pct(m.supplyApy)}</Td>
                  <Td right>{pct(m.borrowApy)}</Td>
                  <Td right className="text-fg-2">
                    {m.config.collateralEnabled ? `${pct(m.config.ltv, 0)} · ${pct(m.config.liquidationThreshold, 1)} · ${pct(m.config.liquidationBonus, 1)}` : "not collateral"}
                  </Td>
                  <Td right className="text-fg-2">{capUsage(m.totalSupplied.amount, m.config.supplyCap)}</Td>
                </Row>
              ))}
            </tbody>
          </Table>
        )}
      </Card>
    </>
  );
}

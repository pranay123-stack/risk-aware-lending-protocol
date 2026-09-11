"use client";

import { useSearchParams } from "next/navigation";
import { Suspense } from "react";
import { useAccount } from "wagmi";
import { ActionPanel } from "@/components/actions";
import { Asset, Callout, Card, CardHeader, Empty, HealthFactor, KeyValue, PageHeader, Row, Table, Td, Th } from "@/components/ui";
import { pct, tokenAmount, usd } from "@/lib/format";
import { useAccount as useAccountData } from "@/lib/hooks";

function BorrowingPower() {
  const { address } = useAccount();
  const { data: a } = useAccountData(address);
  if (!address) return null;
  const used = a && a.borrowCapacityUsd > 0 ? a.totalDebtUsd / a.borrowCapacityUsd : 0;
  return (
    <Card>
      <CardHeader title="Borrowing power" right={a && <HealthFactor value={a.healthFactor} priced={a.priced} />} />
      {a && !a.priced && (
        <div className="p-5">
          <Callout tone="neutral" title="Cannot be valued right now">
            A price feed for an asset in this account is unavailable. The protocol will not value (or liquidate) the account on a price it cannot trust.
          </Callout>
        </div>
      )}
      {a && a.priced && (
        <>
          <div className="px-5 pt-4">
            <div className="flex justify-between text-xs text-fg-3">
              <span>Capacity used</span>
              <span className="num">{pct(used, 1)}</span>
            </div>
            <div className="mt-1.5 h-2 overflow-hidden rounded-full bg-surface-3">
              <div className="h-full rounded-full" style={{ width: `${Math.min(100, used * 100)}%`, background: used > 0.9 ? "var(--critical)" : used > 0.75 ? "var(--warning)" : "var(--good)" }} />
            </div>
          </div>
          <KeyValue
            items={[
              ["Debt", usd(a.totalDebtUsd)],
              ["Borrow capacity (LTV-weighted)", usd(a.borrowCapacityUsd)],
              ["Available to borrow", usd(a.availableToBorrowUsd)],
              ["Liquidation value (LT-weighted)", usd(a.liquidationThresholdUsd)],
              ["Average LTV · liquidation threshold", `${pct(a.averageLtv, 1)} · ${pct(a.averageLiquidationThreshold, 1)}`],
            ]}
          />
        </>
      )}
    </Card>
  );
}

function Debts() {
  const { address } = useAccount();
  const { data } = useAccountData(address);
  const debts = data?.positions.filter((p) => p.borrowed.raw !== "0") ?? [];
  return (
    <Card>
      <CardHeader title="Your debt" subtitle="Variable rate: the balance compounds every second" />
      {!address ? (
        <Empty>Connect a wallet to see your debt.</Empty>
      ) : debts.length === 0 ? (
        <Empty>No outstanding debt.</Empty>
      ) : (
        <Table>
          <thead>
            <tr>
              <Th>Asset</Th>
              <Th right>Owed</Th>
              <Th right>Borrow APY</Th>
            </tr>
          </thead>
          <tbody>
            {debts.map((p) => (
              <Row key={p.asset}>
                <Td>
                  <Asset symbol={p.symbol} />
                </Td>
                <Td right>
                  <div>{tokenAmount(p.borrowed.amount, p.symbol)}</div>
                  <div className="text-xs text-fg-3">{usd(p.borrowed.usd)}</div>
                </Td>
                <Td right>{pct(p.borrowApy)}</Td>
              </Row>
            ))}
          </tbody>
        </Table>
      )}
    </Card>
  );
}

function BorrowContent() {
  const asset = useSearchParams().get("asset") ?? undefined;
  return (
    <div className="grid gap-6 lg:grid-cols-5">
      <div className="lg:col-span-2">
        <ActionPanel modes={["borrow", "repay"]} initialAsset={asset} />
      </div>
      <div className="space-y-6 lg:col-span-3">
        <BorrowingPower />
        <Debts />
        <Card>
          <CardHeader title="Two thresholds, on purpose" />
          <p className="px-5 py-4 text-sm leading-relaxed text-fg-2">
            You can borrow up to each collateral&apos;s <strong className="text-fg">LTV</strong>. You are liquidated only below its higher{" "}
            <strong className="text-fg">liquidation threshold</strong>. So a maximum borrow still leaves a buffer: with WETH (80% LTV, 82.5% LT) a
            fresh max borrow starts at health factor 1.03. Interest accrual and price moves erode that buffer over time.
            Repaying always works, even while the protocol is paused.
          </p>
        </Card>
      </div>
    </div>
  );
}

export default function BorrowPage() {
  return (
    <>
      <PageHeader title="Borrow" subtitle="Borrow against your enabled collateral at the market's variable rate." />
      <Suspense>
        <BorrowContent />
      </Suspense>
    </>
  );
}

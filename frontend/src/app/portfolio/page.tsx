"use client";

import { useRouter, useSearchParams } from "next/navigation";
import { Suspense, useState } from "react";
import { isAddress, type Address } from "viem";
import { useAccount } from "wagmi";
import { Asset, Button, Card, CardHeader, Empty, HealthFactor, KeyValue, PageHeader, Row, Skeleton, Stat, Table, Td, Th } from "@/components/ui";
import { pct, shortAddress, timeAgo, tokenAmount, usd } from "@/lib/format";
import { useAccount as useAccountData, useAccountHistory, useMarkets } from "@/lib/hooks";
import { DEV_ACCOUNTS } from "@/lib/wagmi";

const LABEL: Record<string, string> = {
  Supply: "Supply",
  Withdraw: "Withdraw",
  Borrow: "Borrow",
  Repay: "Repay",
  LiquidationCall: "Liquidation",
  ReserveUsedAsCollateral: "Collateral",
  BadDebtRecognized: "Bad debt write-off",
};

function PortfolioContent() {
  const router = useRouter();
  const { address: connected } = useAccount();
  const param = useSearchParams().get("address");
  const address = (param && isAddress(param) ? param : connected) as Address | undefined;
  const [lookup, setLookup] = useState("");
  const { data: a, isLoading } = useAccountData(address);
  const { data: history } = useAccountHistory(address);
  const { data: markets } = useMarkets();
  const bySymbol = (asset?: string) => markets?.find((m) => m.asset.toLowerCase() === asset?.toLowerCase());
  const dev = DEV_ACCOUNTS.find((d) => d.address.toLowerCase() === address?.toLowerCase());

  return (
    <>
      <PageHeader
        title="Portfolio"
        subtitle={address ? `${dev ? `${dev.label} · ` : ""}${address}` : "Connect a wallet or look up any address."}
        right={
          <form
            className="flex gap-2"
            onSubmit={(e) => {
              e.preventDefault();
              if (isAddress(lookup)) router.push(`/portfolio?address=${lookup}`);
            }}
          >
            <input
              value={lookup}
              onChange={(e) => setLookup(e.target.value)}
              placeholder="0x… any account"
              className="num h-8 w-64 rounded-lg border border-line bg-surface px-3 text-xs text-fg outline-none focus:border-accent"
            />
            <Button size="sm" variant="secondary" type="submit" disabled={!isAddress(lookup)}>
              View
            </Button>
          </form>
        }
      />

      {!address ? (
        <Card>
          <Empty>
            Pick a demo account from the wallet menu, or try{" "}
            {DEV_ACCOUNTS.slice(1, 4).map((d) => (
              <button key={d.address} className="mx-1 text-accent hover:underline" onClick={() => router.push(`/portfolio?address=${d.address}`)}>
                {d.label}
              </button>
            ))}
          </Empty>
        </Card>
      ) : isLoading || !a ? (
        <Skeleton className="h-64" />
      ) : (
        <>
          <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
            <Stat label="Health factor" value={<HealthFactor value={a.healthFactor} priced={a.priced} size="lg" />} sub={a.distanceToLiquidation !== null ? `${pct(a.distanceToLiquidation, 1)} collateral drop to liquidation` : "no debt"} />
            <Stat label="Collateral" value={usd(a.totalCollateralUsd, { compact: true })} sub={`avg LTV ${pct(a.averageLtv, 1)}`} />
            <Stat label="Debt" value={usd(a.totalDebtUsd, { compact: true })} sub={`${pct(a.borrowCapacityUsd ? a.totalDebtUsd / a.borrowCapacityUsd : 0, 1)} of capacity`} />
            <Stat label="Available to borrow" value={usd(a.availableToBorrowUsd, { compact: true })} sub={`liquidation value ${usd(a.liquidationThresholdUsd, { compact: true })}`} />
          </div>

          <div className="mt-6 grid gap-6 lg:grid-cols-3">
            <Card className="lg:col-span-2">
              <CardHeader title="Positions" subtitle={`as of block ${a.blockNumber}`} />
              {a.positions.length === 0 ? (
                <Empty>No open positions.</Empty>
              ) : (
                <Table>
                  <thead>
                    <tr>
                      <Th>Asset</Th>
                      <Th right>Supplied</Th>
                      <Th right>Borrowed</Th>
                      <Th right>Collateral</Th>
                      <Th right>APY (supply / borrow)</Th>
                    </tr>
                  </thead>
                  <tbody>
                    {a.positions.map((p) => (
                      <Row key={p.asset}>
                        <Td>
                          <Asset symbol={p.symbol} />
                        </Td>
                        <Td right>
                          <div>{tokenAmount(p.supplied.amount, p.symbol)}</div>
                          <div className="text-xs text-fg-3">{usd(p.supplied.usd)}</div>
                        </Td>
                        <Td right>
                          <div>{tokenAmount(p.borrowed.amount, p.symbol)}</div>
                          <div className="text-xs text-fg-3">{usd(p.borrowed.usd)}</div>
                        </Td>
                        <Td right className={p.collateralEnabled ? "text-fg" : "text-fg-3"}>{p.collateralEnabled ? "enabled" : "off"}</Td>
                        <Td right className="text-fg-2">
                          {pct(p.supplyApy)} / {pct(p.borrowApy)}
                        </Td>
                      </Row>
                    ))}
                  </tbody>
                </Table>
              )}
            </Card>
            <Card>
              <CardHeader title="Risk breakdown" />
              <KeyValue
                items={[
                  ["Risk level", a.riskLevel],
                  ["Weighted liquidation threshold", pct(a.averageLiquidationThreshold, 2)],
                  ["Debt / liquidation value", a.liquidationThresholdUsd ? pct(a.totalDebtUsd / a.liquidationThresholdUsd, 1) : "–"],
                  ["Priced by oracles", a.priced ? "yes" : "no: an exposed feed is down"],
                ]}
              />
            </Card>
          </div>

          <Card className="mt-6">
            <CardHeader title="History" subtitle="From the indexer; newest first" />
            {!history?.length ? (
              <Empty>No indexed activity for this account.</Empty>
            ) : (
              <Table>
                <thead>
                  <tr>
                    <Th>Action</Th>
                    <Th right>Amount</Th>
                    <Th>Counterparty</Th>
                    <Th right>Block</Th>
                    <Th right>When</Th>
                  </tr>
                </thead>
                <tbody>
                  {history.map((e) => {
                    const m = bySymbol((e.args.reserve ?? e.args.debtAsset) as string);
                    const raw = (e.args.amount ?? e.args.debtRepaid) as string | undefined;
                    const liq = e.name === "LiquidationCall";
                    const wasBorrower = liq && String(e.args.borrower).toLowerCase() === address.toLowerCase();
                    return (
                      <Row key={`${e.tx_hash}-${e.log_index}`}>
                        <Td className={liq ? "font-medium text-serious" : ""}>
                          {LABEL[e.name] ?? e.name}
                          {liq && <span className="ml-1 text-xs text-fg-3">({wasBorrower ? "liquidated" : "as liquidator"})</span>}
                          {e.name === "ReserveUsedAsCollateral" && <span className="ml-1 text-xs text-fg-3">{String(e.args.enabled) === "true" ? "enabled" : "disabled"} {bySymbol(e.args.reserve as string)?.symbol}</span>}
                        </Td>
                        <Td right>{m && raw ? tokenAmount(Number(raw) / 10 ** m.decimals, m.symbol) : "–"}</Td>
                        <Td className="num text-fg-3">{liq ? shortAddress((wasBorrower ? e.args.liquidator : e.args.borrower) as string) : ""}</Td>
                        <Td right className="text-fg-3">{e.block_number}</Td>
                        <Td right className="text-fg-3">{timeAgo(e.block_time)}</Td>
                      </Row>
                    );
                  })}
                </tbody>
              </Table>
            )}
          </Card>
        </>
      )}
    </>
  );
}

export default function PortfolioPage() {
  return (
    <Suspense>
      <PortfolioContent />
    </Suspense>
  );
}

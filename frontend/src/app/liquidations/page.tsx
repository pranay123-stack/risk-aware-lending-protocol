"use client";

import { lendingPoolAbi, mockErc20Abi } from "@lending/shared";
import Link from "next/link";
import { useState } from "react";
import { useAccount } from "wagmi";
import { Button, Callout, Card, CardHeader, Empty, HealthFactor, PageHeader, Row, Stat, StatusBadge, Table, Td, Th } from "@/components/ui";
import type { Candidate } from "@/lib/api";
import { duration, pct, shortAddress, timeAgo, tokenAmount, usd } from "@/lib/format";
import { useAccountPositions, useCandidates, useConfig, useLiquidations, useProtocolStatus } from "@/lib/hooks";
import { useTransactor } from "@/lib/tx";

function LiquidateButton({ c, receiveSupply }: { c: Candidate; receiveSupply: boolean }) {
  const { address, isConnected } = useAccount();
  const { data: config } = useConfig();
  const { data: mine } = useAccountPositions(address);
  const tx = useTransactor();
  const best = c.bestLiquidation!;
  const debtPos = mine?.positions.find((p) => p.asset.toLowerCase() === best.debtAsset.toLowerCase());
  const need = BigInt(best.debtToCoverRaw);
  const wallet = BigInt(debtPos?.walletBalance.raw ?? "0");
  const self = address?.toLowerCase() === c.address.toLowerCase();

  const run = () => {
    const pool = config!.contracts.lendingPool;
    const steps = [];
    // A 0.1% buffer covers interest accrued between the preview and inclusion.
    const approveAmount = (need * 1001n) / 1000n;
    if (wallet < approveAmount) {
      steps.push({ label: `Mint test ${best.debtSymbol}`, address: best.debtAsset, abi: mockErc20Abi, functionName: "mint", args: [address, approveAmount - wallet] });
    }
    if (BigInt(debtPos?.allowance ?? "0") < approveAmount) {
      steps.push({ label: `Approve ${best.debtSymbol}`, address: best.debtAsset, abi: mockErc20Abi, functionName: "approve", args: [pool, approveAmount] });
    }
    steps.push({ label: "Liquidate", address: pool, abi: lendingPoolAbi, functionName: "liquidate", args: [best.collateralAsset, best.debtAsset, c.address, need, receiveSupply] });
    return tx.run(steps as never, `Liquidated ${shortAddress(c.address)}: repaid ${tokenAmount(best.debtToCover, best.debtSymbol)}`);
  };

  return (
    <div className="flex flex-col items-end gap-1">
      <Button size="sm" variant="danger" disabled={!isConnected || tx.busy || self} onClick={run}>
        {tx.busy ? `${tx.step}…` : self ? "Your account" : "Liquidate"}
      </Button>
      {tx.error && <span className="max-w-64 text-right text-xs text-critical">{tx.error}</span>}
    </div>
  );
}

export default function LiquidationsPage() {
  const { data: candidates } = useCandidates();
  const { data: history } = useLiquidations();
  const { data: status } = useProtocolStatus();
  const { isConnected } = useAccount();
  const [receiveSupply, setReceiveSupply] = useState(false);
  const liquidatable = candidates?.filter((c) => c.riskLevel === "LIQUIDATABLE") ?? [];
  const near = candidates?.filter((c) => c.riskLevel !== "LIQUIDATABLE") ?? [];
  const totalProfit = history?.liquidations.reduce((s, l) => s + (l.liquidatorProfitUsd ?? 0), 0) ?? 0;

  return (
    <>
      <PageHeader
        title="Liquidations"
        subtitle="Permissionless. Anyone can repay part of an unhealthy account's debt and receive its collateral plus a bonus, which restores the account's health."
      />

      {status?.paused && <div className="mb-4"><Callout tone="critical" title="Protocol paused">Liquidations are halted while paused. Repayments remain open.</Callout></div>}
      {status?.liquidationsBlockedByGrace && (
        <div className="mb-4">
          <Callout tone="warning" title="Post-unpause grace period">
            Liquidations resume in {duration(status.liquidationGraceUntil - status.blockTimestamp)}, so borrowers can repay interest that accrued while paused.
          </Callout>
        </div>
      )}

      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Stat label="Liquidatable now" tone={liquidatable.length ? "critical" : "good"} value={liquidatable.length} sub={usd(liquidatable.reduce((s, c) => s + c.totalDebtUsd, 0), { compact: true }) + " of debt"} />
        <Stat label="Close to liquidation" tone={near.length ? "serious" : "good"} value={near.length} sub="health factor 1.0–1.2" />
        <Stat label="Executed" value={history?.total ?? "–"} sub="all time, from the indexer" />
        <Stat label="Liquidator bonus paid" value={usd(totalProfit)} sub="collateral value received minus debt repaid" />
      </div>

      <Card className="mt-6">
        <CardHeader
          title="Opportunities"
          subtitle="Re-checked live; the suggested amount is the pool's own preview (close factor, bonus and dust rule applied)"
          right={
            <label className="flex cursor-pointer items-center gap-2 text-xs text-fg-2">
              <input type="checkbox" checked={receiveSupply} onChange={(e) => setReceiveSupply(e.target.checked)} className="accent-[var(--accent)]" />
              Receive collateral as a supply position
            </label>
          }
        />
        {!candidates?.length ? (
          <Empty>No account is close to liquidation. Move a price on the Admin page to create one.</Empty>
        ) : (
          <Table>
            <thead>
              <tr>
                <Th>Borrower</Th>
                <Th>Health</Th>
                <Th right>Collateral / debt</Th>
                <Th>Best liquidation</Th>
                <Th right>Bonus</Th>
                <Th right> </Th>
              </tr>
            </thead>
            <tbody>
              {candidates.map((c) => (
                <Row key={c.address}>
                  <Td>
                    <Link href={`/portfolio?address=${c.address}`} className="num text-accent hover:underline">
                      {shortAddress(c.address)}
                    </Link>
                  </Td>
                  <Td>
                    <HealthFactor value={c.healthFactor} priced={c.priced} />
                  </Td>
                  <Td right>
                    {usd(c.totalCollateralUsd)} / {usd(c.totalDebtUsd)}
                  </Td>
                  <Td>
                    {c.bestLiquidation ? (
                      <span className="text-sm text-fg-2">
                        repay <span className="num text-fg">{tokenAmount(c.bestLiquidation.debtToCover, c.bestLiquidation.debtSymbol)}</span> → receive{" "}
                        <span className="num text-fg">{tokenAmount(c.bestLiquidation.collateralSeized, c.bestLiquidation.collateralSymbol)}</span>{" "}
                        <span className="text-xs text-fg-3">(close factor {pct(c.bestLiquidation.closeFactor, 0)})</span>
                      </span>
                    ) : (
                      <span className="text-xs text-fg-3">not liquidatable yet: {pct(c.distanceToLiquidation ?? 0, 1)} collateral drop away</span>
                    )}
                  </Td>
                  <Td right className="text-good">{c.bestLiquidation ? usd(c.bestLiquidation.profitUsd) : "–"}</Td>
                  <Td right>{c.bestLiquidation ? (isConnected ? <LiquidateButton c={c} receiveSupply={receiveSupply} /> : <span className="text-xs text-fg-3">connect wallet</span>) : null}</Td>
                </Row>
              ))}
            </tbody>
          </Table>
        )}
      </Card>

      <div className="mt-6 grid gap-6 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <CardHeader title="History" subtitle="Valued at each asset's oracle price in the liquidation's own block" />
          {!history?.liquidations.length ? (
            <Empty>No liquidations yet.</Empty>
          ) : (
            <Table>
              <thead>
                <tr>
                  <Th>Borrower</Th>
                  <Th right>Repaid</Th>
                  <Th right>Seized</Th>
                  <Th right>Bonus</Th>
                  <Th right>When</Th>
                </tr>
              </thead>
              <tbody>
                {history.liquidations.map((l) => (
                  <Row key={l.txHash}>
                    <Td>
                      <span className="num text-fg">{shortAddress(l.borrower)}</span>
                      <span className="ml-2 text-xs text-fg-3">by {shortAddress(l.liquidator)}</span>
                      {l.receiveSupply && <span className="ml-2"><StatusBadge tone="info">as supply</StatusBadge></span>}
                    </Td>
                    <Td right>
                      <div>{tokenAmount(l.debt.amount, l.debt.symbol)}</div>
                      <div className="text-xs text-fg-3">{usd(l.debt.usd)}</div>
                    </Td>
                    <Td right>
                      <div>{tokenAmount(l.collateral.amount, l.collateral.symbol)}</div>
                      <div className="text-xs text-fg-3">{usd(l.collateral.usd)}</div>
                    </Td>
                    <Td right className="text-good">{usd(l.liquidatorProfitUsd)}</Td>
                    <Td right className="text-fg-3">{timeAgo(l.blockTime)}</Td>
                  </Row>
                ))}
              </tbody>
            </Table>
          )}
        </Card>
        <Card>
          <CardHeader title="Rules" />
          <ul className="space-y-2.5 px-5 py-4 text-sm text-fg-2">
            <li><strong className="text-fg">Close factor 50%</strong> of one debt per call, or <strong className="text-fg">100%</strong> when HF &lt; 0.95 or the position is under $2,000: small or deeply unhealthy positions must be closable in one go.</li>
            <li><strong className="text-fg">Bonus</strong> 4.5–6.5% by collateral, paid in collateral.</li>
            <li><strong className="text-fg">Dust rule:</strong> a partial liquidation may not leave less than $1,000 of debt or collateral.</li>
            <li><strong className="text-fg">Bad debt:</strong> if the collateral runs out first, the remaining debt is written off: covered by the reserve&apos;s treasury buffer first, then booked as a visible deficit.</li>
            <li><strong className="text-fg">Oracle failure</strong> halts liquidations of exposed accounts: the protocol never liquidates on a price it cannot trust.</li>
          </ul>
        </Card>
      </div>
    </>
  );
}

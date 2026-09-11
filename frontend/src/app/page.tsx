"use client";

import Link from "next/link";
import { useAccount } from "wagmi";
import { Asset, Card, CardHeader, Empty, HealthFactor, KeyValue, PageHeader, PriceBadge, Row, Skeleton, Stat, StatusBadge, Table, Td, Th, UtilBar } from "@/components/ui";
import { duration, pct, shortAddress, timeAgo, tokenAmount, usd } from "@/lib/format";
import { useAccount as useAccountData, useAlerts, useEvents, useMarkets, useOracle, useProtocolStatus, useRiskSummary, useTvl } from "@/lib/hooks";

const EVENT_LABEL: Record<string, string> = {
  Supply: "Supplied",
  Withdraw: "Withdrew",
  Borrow: "Borrowed",
  Repay: "Repaid",
  LiquidationCall: "Liquidation",
  ReserveUsedAsCollateral: "Collateral toggled",
  BadDebtRecognized: "Bad debt recognised",
};

export default function Dashboard() {
  const { data: tvl } = useTvl();
  const { data: markets, isLoading } = useMarkets();
  const { data: risk } = useRiskSummary();
  const { data: alerts } = useAlerts();
  const { data: status } = useProtocolStatus();
  const { data: oracle } = useOracle();
  const { data: allEvents } = useEvents(60);
  const events = allEvents?.filter((e) => EVENT_LABEL[e.name]).slice(0, 12);
  const { address } = useAccount();
  const { data: me } = useAccountData(address);
  const symbolOf = (asset?: string) => markets?.find((m) => m.asset.toLowerCase() === asset?.toLowerCase());

  const atRisk = risk ? risk.levels.DANGER.accounts + risk.levels.LIQUIDATABLE.accounts : null;
  const critical = alerts?.filter((a) => a.severity === "critical").length ?? 0;

  return (
    <>
      <PageHeader
        title="Protocol overview"
        subtitle="Live state read from the chain through PoolLens; history from the reorg-aware indexer; risk levels from the monitor's last sweep."
      />

      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Stat label="Total value supplied" value={tvl ? usd(tvl.totalSuppliedUsd, { compact: true }) : <Skeleton className="h-8 w-32" />} sub="collateral + lendable liquidity" />
        <Stat label="Total borrowed" value={tvl ? usd(tvl.totalBorrowedUsd, { compact: true }) : <Skeleton className="h-8 w-28" />} sub={tvl ? `${pct(tvl.utilization, 1)} aggregate utilization` : ""} />
        <Stat label="Available liquidity" value={tvl ? usd(tvl.availableLiquidityUsd, { compact: true }) : <Skeleton className="h-8 w-28" />} sub="withdrawable or borrowable now" />
        <Stat
          label="Accounts at risk"
          tone={atRisk ? (risk!.levels.LIQUIDATABLE.accounts ? "critical" : "serious") : "good"}
          value={atRisk ?? "–"}
          sub={risk ? `${usd(risk.levels.DANGER.debtUsd + risk.levels.LIQUIDATABLE.debtUsd, { compact: true })} of debt · ${critical} critical alerts` : ""}
        />
      </div>

      <div className="mt-6 grid gap-6 xl:grid-cols-3">
        <Card className="xl:col-span-2">
          <CardHeader title="Markets" subtitle="Rates are variable and move with utilization" right={<Link className="text-xs text-accent hover:underline" href="/markets">All details →</Link>} />
          {isLoading ? (
            <div className="space-y-2 p-5">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-10" />)}</div>
          ) : (
            <Table>
              <thead>
                <tr>
                  <Th>Asset</Th>
                  <Th right>Supplied</Th>
                  <Th right>Borrowed</Th>
                  <Th>Utilization</Th>
                  <Th right>Supply APY</Th>
                  <Th right>Borrow APY</Th>
                </tr>
              </thead>
              <tbody>
                {markets?.map((m) => (
                  <Row key={m.asset}>
                    <Td>
                      <Link href={`/markets/${m.asset}`}>
                        <Asset symbol={m.symbol} sub={<span className="inline-flex items-center gap-1.5">{usd(m.price.usd)} {m.price.status !== "OK" && <PriceBadge status={m.price.status} />}</span>} />
                      </Link>
                    </Td>
                    <Td right>
                      <div className="text-fg">{usd(m.totalSupplied.usd, { compact: true })}</div>
                      <div className="text-xs text-fg-3">{tokenAmount(m.totalSupplied.amount, m.symbol)}</div>
                    </Td>
                    <Td right>
                      <div className="text-fg">{usd(m.totalBorrowed.usd, { compact: true })}</div>
                      <div className="text-xs text-fg-3">{tokenAmount(m.totalBorrowed.amount, m.symbol)}</div>
                    </Td>
                    <Td>
                      <UtilBar value={m.utilization} kink={m.interestRateModel.optimalUtilization} />
                    </Td>
                    <Td right className={m.supplyApy > 0 ? "text-good" : "text-fg-3"}>{pct(m.supplyApy)}</Td>
                    <Td right>{pct(m.borrowApy)}</Td>
                  </Row>
                ))}
              </tbody>
            </Table>
          )}
        </Card>

        <div className="space-y-6">
          <Card>
            <CardHeader title="Your position" right={address && <Link className="text-xs text-accent hover:underline" href="/portfolio">Portfolio →</Link>} />
            {!address ? (
              <Empty>Connect a wallet (or pick a local demo account) to see your position.</Empty>
            ) : !me ? (
              <div className="p-5"><Skeleton className="h-16" /></div>
            ) : (
              <>
                <div className="px-5 pt-4">
                  <div className="text-xs text-fg-3">Health factor</div>
                  <HealthFactor value={me.healthFactor} priced={me.priced} size="lg" />
                </div>
                <KeyValue
                  items={[
                    ["Collateral", usd(me.totalCollateralUsd)],
                    ["Debt", usd(me.totalDebtUsd)],
                    ["Available to borrow", usd(me.availableToBorrowUsd)],
                    ["Liquidation distance", me.distanceToLiquidation === null ? "no debt" : `${pct(me.distanceToLiquidation, 1)} collateral drop`],
                  ]}
                />
              </>
            )}
          </Card>

          <Card>
            <CardHeader title="Protocol safety" />
            <KeyValue
              items={[
                ["Pool", status ? (status.paused ? <StatusBadge tone="critical">Paused</StatusBadge> : <StatusBadge tone="good">Operational</StatusBadge>) : "–"],
                ["Oracles", oracle ? (oracle.assets.every((a) => a.status === "OK") ? <StatusBadge tone="good">All live</StatusBadge> : <StatusBadge tone="warning">{oracle.assets.filter((a) => a.status !== "OK").map((a) => a.symbol).join(", ")} degraded</StatusBadge>) : "–"],
                ["Risk-parameter delay", status ? `${duration(status.timelockDelaySeconds)} timelock` : "–"],
                ["Post-unpause liquidation grace", status ? duration(status.liquidationGracePeriodSeconds) : "–"],
                ["Bad debt (unrecovered)", tvl ? usd(tvl.deficitUsd) : "–"],
              ]}
            />
          </Card>
        </div>
      </div>

      <Card className="mt-6">
        <CardHeader title="Recent activity" subtitle="Indexed protocol events, newest first" />
        {!events?.length ? (
          <Empty>No indexed events yet.</Empty>
        ) : (
          <Table>
            <thead>
              <tr>
                <Th>Event</Th>
                <Th>Account</Th>
                <Th right>Amount</Th>
                <Th right>Block</Th>
                <Th right>When</Th>
              </tr>
            </thead>
            <tbody>
              {events.map((e) => {
                const reserve = (e.args.reserve ?? e.args.debtAsset) as string | undefined;
                const m = symbolOf(reserve);
                const raw = (e.args.amount ?? e.args.debtRepaid) as string | undefined;
                const who = (e.args.user ?? e.args.onBehalfOf ?? e.args.borrower) as string | undefined;
                return (
                  <Row key={`${e.tx_hash}-${e.log_index}`}>
                    <Td>
                      <span className={e.name === "LiquidationCall" || e.name === "BadDebtRecognized" ? "font-medium text-serious" : "text-fg"}>{EVENT_LABEL[e.name] ?? e.name}</span>
                    </Td>
                    <Td className="num text-fg-2">{shortAddress(who)}</Td>
                    <Td right>{m && raw ? tokenAmount(Number(raw) / 10 ** m.decimals, m.symbol) : "–"}</Td>
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
  );
}

"use client";

import { aclManagerAbi, mockAggregatorAbi, oracleManagerAbi, poolConfiguratorAbi, timelockAbi } from "@lending/shared";
import { useEffect, useMemo, useState } from "react";
import { encodeFunctionData, keccak256, toHex, zeroAddress, zeroHash, type Address } from "viem";
import { useAccount, useReadContract } from "wagmi";
import { Asset, Button, Callout, Card, CardHeader, Empty, PageHeader, Row, Segmented, StatusBadge, Table, Td, Th } from "@/components/ui";
import type { DeploymentConfig, Market, OracleAsset } from "@/lib/api";
import { duration, pct, shortAddress, usd } from "@/lib/format";
import { useConfig, useMarkets, useOracle, useProtocolStatus, useTimelock } from "@/lib/hooks";
import { useTransactor, type TxStep } from "@/lib/tx";

const EMERGENCY_ADMIN = keccak256(toHex("EMERGENCY_ADMIN"));

function useRoles(config?: DeploymentConfig) {
  const { address } = useAccount();
  const enabled = Boolean(config && address);
  const guardian = useReadContract({ address: config?.contracts.aclManager, abi: aclManagerAbi, functionName: "hasRole", args: [EMERGENCY_ADMIN, address ?? zeroAddress], query: { enabled } });
  const proposerRole = useReadContract({ address: config?.contracts.timelock, abi: timelockAbi, functionName: "PROPOSER_ROLE", query: { enabled: Boolean(config) } });
  const proposer = useReadContract({
    address: config?.contracts.timelock,
    abi: timelockAbi,
    functionName: "hasRole",
    args: [proposerRole.data ?? zeroHash, address ?? zeroAddress],
    query: { enabled: enabled && Boolean(proposerRole.data) },
  });
  const feedOwner = useReadContract({ address: config?.markets[0]?.primaryFeed, abi: mockAggregatorAbi, functionName: "owner", query: { enabled: Boolean(config) } });
  return {
    address,
    isGuardian: Boolean(guardian.data),
    isProposer: Boolean(proposer.data),
    isFeedOwner: Boolean(address && feedOwner.data && feedOwner.data.toLowerCase() === address.toLowerCase()),
  };
}

// ------------------------------------------------------------------ emergency

function EmergencyControls({ config, markets, oracle, enabled }: { config: DeploymentConfig; markets: Market[]; oracle: OracleAsset[]; enabled: boolean }) {
  const { data: status } = useProtocolStatus();
  const tx = useTransactor();
  const cfg = config.contracts.poolConfigurator;
  const step = (label: string, functionName: string, args: unknown[], target = cfg, abi: readonly unknown[] = poolConfiguratorAbi): TxStep => ({ label, address: target as Address, abi, functionName, args });

  return (
    <Card>
      <CardHeader title="Emergency controls" subtitle="Guardian · instant · risk-reducing only (unfreezing and every risk-increasing change go through the timelock)" />
      {!enabled && <div className="px-5 pt-4"><Callout tone="info" title="Read-only">Connect the guardian (Deployer demo account) to use these controls.</Callout></div>}
      <div className="flex items-center justify-between px-5 py-4">
        <div>
          <div className="text-sm font-medium text-fg">Entire protocol</div>
          <div className="text-xs text-fg-3">Pausing halts supply, withdraw, borrow and liquidations. Repay always stays open. Unpausing starts a {duration(status?.liquidationGracePeriodSeconds ?? 0)} liquidation grace window.</div>
        </div>
        <Button
          variant={status?.paused ? "primary" : "danger"}
          size="sm"
          disabled={!enabled || tx.busy || !status}
          onClick={() => tx.run([step(status?.paused ? "Unpause" : "Pause", "setPoolPaused", [!status?.paused])], status?.paused ? "Protocol unpaused" : "Protocol paused")}
        >
          {status?.paused ? "Unpause protocol" : "Pause protocol"}
        </Button>
      </div>
      <Table>
        <thead>
          <tr>
            <Th>Market</Th>
            <Th>State</Th>
            <Th right>Reserve</Th>
            <Th right>Freeze</Th>
            <Th right>Oracle breaker</Th>
          </tr>
        </thead>
        <tbody>
          {markets.map((m) => {
            const o = oracle.find((x) => x.asset.toLowerCase() === m.asset.toLowerCase());
            return (
              <Row key={m.asset}>
                <Td>
                  <Asset symbol={m.symbol} />
                </Td>
                <Td>
                  <div className="flex gap-1">
                    {m.config.paused && <StatusBadge tone="critical">Paused</StatusBadge>}
                    {m.config.frozen && <StatusBadge tone="warning">Frozen</StatusBadge>}
                    {o?.paused && <StatusBadge tone="critical">Oracle paused</StatusBadge>}
                    {!m.config.paused && !m.config.frozen && !o?.paused && <StatusBadge tone="good">Normal</StatusBadge>}
                  </div>
                </Td>
                <Td right>
                  <Button size="sm" variant="secondary" disabled={!enabled || tx.busy} onClick={() => tx.run([step("Reserve pause", "setReservePaused", [m.asset, !m.config.paused])], `${m.symbol} ${m.config.paused ? "unpaused" : "paused"}`)}>
                    {m.config.paused ? "Unpause" : "Pause"}
                  </Button>
                </Td>
                <Td right>
                  <Button size="sm" variant="secondary" disabled={!enabled || tx.busy || m.config.frozen} title={m.config.frozen ? "Unfreezing requires the timelock" : undefined} onClick={() => tx.run([step("Freeze", "setReserveFrozen", [m.asset, true])], `${m.symbol} frozen`)}>
                    {m.config.frozen ? "Frozen" : "Freeze"}
                  </Button>
                </Td>
                <Td right>
                  <Button
                    size="sm"
                    variant="secondary"
                    disabled={!enabled || tx.busy}
                    onClick={() => tx.run([step("Oracle breaker", "setAssetPaused", [m.asset, !o?.paused], config.contracts.oracleManager, oracleManagerAbi)], `${m.symbol} oracle ${o?.paused ? "resumed" : "paused"}`)}
                  >
                    {o?.paused ? "Resume" : "Trip"}
                  </Button>
                </Td>
              </Row>
            );
          })}
        </tbody>
      </Table>
      {tx.error && <div className="border-t border-line px-5 py-3 text-sm text-critical">{tx.error}</div>}
    </Card>
  );
}

// ------------------------------------------------------------------ timelock

type ProposalKind = "risk" | "reserveFactor" | "caps" | "borrowing" | "unfreeze" | "grace";

function ProposalForm({ config, markets, enabled, delay }: { config: DeploymentConfig; markets: Market[]; enabled: boolean; delay: number }) {
  const [kind, setKind] = useState<ProposalKind>("risk");
  const [idx, setIdx] = useState(0);
  const m = markets[idx]!;
  const [ltv, setLtv] = useState(String(m.config.ltv * 100));
  const [lt, setLt] = useState(String(m.config.liquidationThreshold * 100));
  const [bonus, setBonus] = useState(String(m.config.liquidationBonus * 100));
  const [rf, setRf] = useState(String(m.config.reserveFactor * 100));
  const [supplyCap, setSupplyCap] = useState(m.config.supplyCap);
  const [borrowCap, setBorrowCap] = useState(m.config.borrowCap);
  const [grace, setGrace] = useState("300");
  const tx = useTransactor();

  // Re-seed the form with the selected market's live parameters.
  useEffect(() => {
    setLtv(String(m.config.ltv * 100));
    setLt(String(m.config.liquidationThreshold * 100));
    setBonus(String(m.config.liquidationBonus * 100));
    setRf(String(m.config.reserveFactor * 100));
    setSupplyCap(m.config.supplyCap);
    setBorrowCap(m.config.borrowCap);
  }, [m.asset]); // eslint-disable-line react-hooks/exhaustive-deps

  const bps = (v: string) => Math.round(Number(v) * 100);
  const call = useMemo(() => {
    try {
      switch (kind) {
        case "risk":
          return encodeFunctionData({ abi: poolConfiguratorAbi, functionName: "setRiskParameters", args: [m.asset, bps(ltv), bps(lt), bps(bonus)] });
        case "reserveFactor":
          return encodeFunctionData({ abi: poolConfiguratorAbi, functionName: "setReserveFactor", args: [m.asset, bps(rf)] });
        case "caps":
          return encodeFunctionData({ abi: poolConfiguratorAbi, functionName: "setCaps", args: [m.asset, BigInt(supplyCap || "0"), BigInt(borrowCap || "0")] });
        case "borrowing":
          return encodeFunctionData({ abi: poolConfiguratorAbi, functionName: "setBorrowingEnabled", args: [m.asset, !m.config.borrowingEnabled] });
        case "unfreeze":
          return encodeFunctionData({ abi: poolConfiguratorAbi, functionName: "setReserveFrozen", args: [m.asset, false] });
        case "grace":
          return encodeFunctionData({ abi: poolConfiguratorAbi, functionName: "setLiquidationGracePeriod", args: [Number(grace)] });
      }
    } catch {
      return null;
    }
  }, [kind, m, ltv, lt, bonus, rf, supplyCap, borrowCap, grace]);

  const unsafe = kind === "risk" && (Number(ltv) >= Number(lt) || (Number(lt) / 100) * (1 + Number(bonus) / 100) >= 1);

  const input = (label: string, value: string, set: (v: string) => void, suffix = "%") => (
    <label className="block text-xs text-fg-3">
      {label}
      <div className="mt-1 flex items-center rounded-lg border border-line bg-surface-2 px-3">
        <input value={value} onChange={(e) => set(e.target.value)} className="num h-9 w-full bg-transparent text-sm text-fg outline-none" />
        <span className="text-fg-3">{suffix}</span>
      </div>
    </label>
  );

  return (
    <Card>
      <CardHeader title="Propose a risk change" subtitle={`Scheduled on the TimelockController; executable by anyone after ${duration(delay)}`} />
      <div className="space-y-4 p-5">
        <Segmented
          value={kind}
          onChange={setKind}
          options={[
            { value: "risk", label: "LTV / LT / bonus" },
            { value: "reserveFactor", label: "Reserve factor" },
            { value: "caps", label: "Caps" },
            { value: "borrowing", label: "Borrowing" },
            { value: "unfreeze", label: "Unfreeze" },
            { value: "grace", label: "Grace period" },
          ]}
        />
        {kind !== "grace" && (
          <div className="flex gap-2">
            {markets.map((x, i) => (
              <button key={x.asset} onClick={() => setIdx(i)} className={`rounded-lg border px-3 py-1.5 text-sm ${i === idx ? "border-accent bg-accent-soft text-fg" : "border-line text-fg-2"}`}>
                {x.symbol}
              </button>
            ))}
          </div>
        )}
        <div className="grid grid-cols-3 gap-3">
          {kind === "risk" && (
            <>
              {input("Max LTV", ltv, setLtv)}
              {input("Liquidation threshold", lt, setLt)}
              {input("Liquidation bonus", bonus, setBonus)}
            </>
          )}
          {kind === "reserveFactor" && input("Reserve factor", rf, setRf)}
          {kind === "caps" && (
            <>
              {input("Supply cap", supplyCap, setSupplyCap, m.symbol)}
              {input("Borrow cap", borrowCap, setBorrowCap, m.symbol)}
            </>
          )}
          {kind === "grace" && input("Liquidation grace after unpause", grace, setGrace, "s")}
        </div>
        {kind === "borrowing" && <p className="text-sm text-fg-2">Will {m.config.borrowingEnabled ? "disable" : "enable"} borrowing of {m.symbol}.</p>}
        {kind === "unfreeze" && <p className="text-sm text-fg-2">{m.config.frozen ? `Unfreezes ${m.symbol}: re-opens new supply and borrowing.` : `${m.symbol} is not frozen.`}</p>}
        {unsafe && <Callout tone="critical" title="The configurator will reject this">Rules: LTV &lt; LT, and LT × (1 + bonus) &lt; 100%. Otherwise liquidating a position would lower its health factor.</Callout>}
        {kind === "risk" && Number(lt) < m.config.liquidationThreshold * 100 && (
          <Callout tone="warning" title="Lowering the liquidation threshold">
            This can make existing positions liquidatable when it executes. The {duration(delay)} delay is what gives borrowers time to react.
          </Callout>
        )}
        {call && <div className="break-all rounded-lg bg-surface-2 px-3 py-2 font-mono text-[11px] text-fg-3">{call}</div>}
        {tx.error && <Callout tone="critical" title="Not scheduled">{tx.error}</Callout>}
        <Button
          className="w-full"
          disabled={!enabled || !call || tx.busy}
          onClick={() =>
            tx.run(
              [
                {
                  label: "Schedule",
                  address: config.contracts.timelock,
                  abi: timelockAbi,
                  functionName: "schedule",
                  args: [config.contracts.poolConfigurator, 0n, call!, zeroHash, keccak256(toHex(`${Date.now()}-${Math.random()}`)), BigInt(delay)],
                },
              ],
              "Proposal scheduled on the timelock",
            )
          }
        >
          {enabled ? (tx.busy ? `${tx.step}…` : `Schedule (executable in ${duration(delay)})`) : "Connect the timelock proposer (Deployer)"}
        </Button>
      </div>
    </Card>
  );
}

function TimelockQueue({ config, markets, canCancel }: { config: DeploymentConfig; markets: Market[]; canCancel: boolean }) {
  const { data } = useTimelock();
  const { isConnected } = useAccount();
  const tx = useTransactor();
  const symbol = (a: unknown) => markets.find((m) => m.asset.toLowerCase() === String(a).toLowerCase())?.symbol ?? shortAddress(String(a));
  const describe = (fn: string, args: unknown[]) => {
    const [asset, ...rest] = args;
    switch (fn) {
      case "setRiskParameters":
        return `${symbol(asset)}: LTV ${Number(rest[0]) / 100}%, LT ${Number(rest[1]) / 100}%, bonus ${Number(rest[2]) / 100}%`;
      case "setReserveFactor":
        return `${symbol(asset)}: reserve factor ${Number(rest[0]) / 100}%`;
      case "setCaps":
        return `${symbol(asset)}: supply cap ${rest[0]}, borrow cap ${rest[1]}`;
      case "setBorrowingEnabled":
        return `${symbol(asset)}: borrowing ${rest[0] ? "on" : "off"}`;
      case "setReserveFrozen":
        return `${symbol(asset)}: ${rest[0] ? "freeze" : "unfreeze"}`;
      case "setLiquidationGracePeriod":
        return `grace period ${asset}s`;
      default:
        return `${fn}(${args.map(String).join(", ")})`;
    }
  };
  const ops = data?.operations ?? [];
  return (
    <Card>
      <CardHeader title="Timelock queue" subtitle="Every pending change is public for the whole delay" />
      {ops.length === 0 ? (
        <Empty>No operations scheduled.</Empty>
      ) : (
        <Table>
          <thead>
            <tr>
              <Th>Change</Th>
              <Th>Status</Th>
              <Th right> </Th>
            </tr>
          </thead>
          <tbody>
            {ops.map((op) => (
              <Row key={`${op.id}-${op.index}`}>
                <Td>
                  <div className="text-sm text-fg">{op.call ? describe(op.call.function, op.call.args) : shortAddress(op.target)}</div>
                  <div className="num text-xs text-fg-3">{op.call?.contract} · {shortAddress(op.id)}</div>
                </Td>
                <Td>
                  {op.status === "pending" && <StatusBadge tone="warning">Ready in {duration(op.secondsUntilReady)}</StatusBadge>}
                  {op.status === "ready" && <StatusBadge tone="info">Ready</StatusBadge>}
                  {op.status === "executed" && <StatusBadge tone="good">Executed</StatusBadge>}
                  {op.status === "cancelled" && <StatusBadge tone="neutral">Cancelled</StatusBadge>}
                </Td>
                <Td right>
                  <div className="flex justify-end gap-2">
                    {op.status === "ready" && (
                      <Button size="sm" disabled={!isConnected || tx.busy} onClick={() => tx.run([{ label: "Execute", address: config.contracts.timelock, abi: timelockAbi, functionName: "execute", args: [op.target, BigInt(op.value), op.data, op.predecessor, op.salt] }], "Timelock operation executed")}>
                        Execute
                      </Button>
                    )}
                    {(op.status === "pending" || op.status === "ready") && canCancel && (
                      <Button size="sm" variant="ghost" disabled={tx.busy} onClick={() => tx.run([{ label: "Cancel", address: config.contracts.timelock, abi: timelockAbi, functionName: "cancel", args: [op.id] }], "Timelock operation cancelled")}>
                        Cancel
                      </Button>
                    )}
                  </div>
                </Td>
              </Row>
            ))}
          </tbody>
        </Table>
      )}
      {tx.error && <div className="border-t border-line px-5 py-3 text-sm text-critical">{tx.error}</div>}
    </Card>
  );
}

// ------------------------------------------------------------------ mock oracles

/**
 * One mock-feed row. The reference price is read straight from the mock's latestAnswer(), which
 * keeps answering during a simulated outage. The API's view of a failed feed is (correctly) null,
 * and scenario buttons must never compute from that and post a zero price.
 */
function OracleRow({
  o,
  feeds: f,
  evaluatedAt,
  enabled,
  tx,
  setPrice,
  input,
  setInput,
}: {
  o: OracleAsset;
  feeds: DeploymentConfig["markets"][number];
  evaluatedAt: number;
  enabled: boolean;
  tx: ReturnType<typeof useTransactor>;
  setPrice: (o: OracleAsset, usdPrice: number, label: string) => Promise<boolean>;
  input: string;
  setInput: (v: string) => void;
}) {
  const { data: answer } = useReadContract({ address: f.primaryFeed, abi: mockAggregatorAbi, functionName: "latestAnswer", query: { refetchInterval: 5_000 } });
  const price = answer !== undefined && answer > 0n ? Number(answer) / 1e8 : 0;
  const can = enabled && !tx.busy && price > 0;
  const down = o.primary?.status === "CALL_FAILED";
  return (
    <Row>
      <Td>
        <Asset symbol={o.symbol} sub={`${o.primary?.status ?? "–"}${o.secondary ? ` · 2nd ${o.secondary.status}` : ""}`} />
      </Td>
      <Td>
        <span className="num">{usd(o.price)}</span> <span className="text-xs text-fg-3">{o.status}</span>
        <div className="num text-xs text-fg-3">feed answer {usd(price)}</div>
      </Td>
      <Td>
        <div className="flex gap-2">
          <input
            value={input}
            placeholder={String(price)}
            onChange={(e) => setInput(e.target.value)}
            className="num h-8 w-28 rounded-lg border border-line bg-surface-2 px-2 text-sm text-fg outline-none focus:border-accent"
          />
          <Button size="sm" variant="secondary" disabled={!enabled || tx.busy || !(Number(input) > 0)} onClick={() => setPrice(o, Number(input), `${o.symbol} set to ${usd(Number(input))}`)}>
            Set
          </Button>
        </div>
      </Td>
      <Td right>
        <div className="flex flex-wrap justify-end gap-1.5">
          <Button size="sm" variant="ghost" disabled={!can} onClick={() => setPrice(o, price * 0.7, `${o.symbol} crashed 30%`)}>
            −30%
          </Button>
          <Button size="sm" variant="ghost" disabled={!can} onClick={() => setPrice(o, price * 1.1, `${o.symbol} +10%`)}>
            +10%
          </Button>
          <Button
            size="sm"
            variant="ghost"
            title="Re-post the price with a timestamp two heartbeats old"
            disabled={!can}
            onClick={() =>
              tx.run(
                [f.primaryFeed, ...(f.secondaryFeed !== zeroAddress ? [f.secondaryFeed] : [])].map((feed, i) => ({
                  label: "Stale feed",
                  address: feed,
                  abi: mockAggregatorAbi,
                  functionName: "setAnswerWithTimestamp",
                  args: [i === 0 ? BigInt(Math.round(price * 1e8)) : BigInt(Math.round(price * 1e8)) * 10n ** 10n, BigInt(evaluatedAt - 2 * (o.primary?.heartbeatSeconds ?? 3600))],
                })),
                `${o.symbol} feeds made stale`,
              )
            }
          >
            Stale
          </Button>
          <Button
            size="sm"
            variant="ghost"
            title="Primary feed reverts on every read (downtime / deprecation)"
            disabled={!enabled || tx.busy}
            onClick={() => tx.run([{ label: "Outage", address: f.primaryFeed, abi: mockAggregatorAbi, functionName: "setReverting", args: [!down] }], down ? `${o.symbol} primary restored` : `${o.symbol} primary feed down`)}
          >
            {down ? "Restore" : "Outage"}
          </Button>
          {f.secondaryFeed !== zeroAddress && (
            <Button
              size="sm"
              variant="ghost"
              title="Secondary disagrees by 5%: the deviation breaker trips"
              disabled={!can}
              onClick={() => tx.run([{ label: "Deviate", address: f.secondaryFeed, abi: mockAggregatorAbi, functionName: "setAnswer", args: [BigInt(Math.round(price * 1.05 * 1e8)) * 10n ** 10n] }], `${o.symbol} secondary deviates 5%`)}
            >
              Deviate
            </Button>
          )}
          <Button size="sm" variant="ghost" title="Re-post current answers with a fresh timestamp" disabled={!can} onClick={() => setPrice(o, price, `${o.symbol} feeds refreshed`)}>
            Heal
          </Button>
        </div>
      </Td>
    </Row>
  );
}

function OracleLab({ config, oracle, enabled }: { config: DeploymentConfig; oracle: { assets: OracleAsset[]; evaluatedAt: number }; enabled: boolean }) {
  const tx = useTransactor();
  const [inputs, setInputs] = useState<Record<string, string>>({});
  const feedsFor = (asset: string) => config.markets.find((m) => m.token.toLowerCase() === asset.toLowerCase())!;

  /** Moves every configured feed of the asset together, so the deviation check passes. */
  const setPrice = (o: OracleAsset, usdPrice: number, label: string) => {
    const f = feedsFor(o.asset);
    const steps: TxStep[] = [{ label: "Primary feed", address: f.primaryFeed, abi: mockAggregatorAbi, functionName: "setAnswer", args: [BigInt(Math.round(usdPrice * 1e8))] }];
    if (f.secondaryFeed !== zeroAddress) {
      steps.push({ label: "Secondary feed", address: f.secondaryFeed, abi: mockAggregatorAbi, functionName: "setAnswer", args: [BigInt(Math.round(usdPrice * 1e8)) * 10n ** 10n] });
    }
    return tx.run(steps, label);
  };

  return (
    <Card>
      <CardHeader title="Oracle lab (local mock feeds)" subtitle="Drive every failure mode the OracleManager defends against. Mock feeds exist only on the local chain." />
      {!enabled && <div className="px-5 pt-4"><Callout tone="info" title="Read-only">The feeds are owned by the Deployer demo account.</Callout></div>}
      <Table>
        <thead>
          <tr>
            <Th>Asset</Th>
            <Th>Resolved price</Th>
            <Th>Set price (all feeds)</Th>
            <Th right>Scenarios</Th>
          </tr>
        </thead>
        <tbody>
          {oracle.assets.map((o) => (
            <OracleRow key={o.asset} o={o} feeds={feedsFor(o.asset)} evaluatedAt={oracle.evaluatedAt} enabled={enabled} tx={tx} setPrice={setPrice} input={inputs[o.asset] ?? ""} setInput={(v) => setInputs({ ...inputs, [o.asset]: v })} />
          ))}
        </tbody>
      </Table>
      {tx.error && <div className="border-t border-line px-5 py-3 text-sm text-critical">{tx.error}</div>}
    </Card>
  );
}

// ------------------------------------------------------------------ page

export default function AdminPage() {
  const { data: config } = useConfig();
  const { data: markets } = useMarkets();
  const { data: oracle } = useOracle();
  const { data: timelock } = useTimelock();
  const roles = useRoles(config);
  const [tab, setTab] = useState<"governance" | "emergency" | "oracle">("governance");

  if (!config || !markets || !oracle) return <PageHeader title="Admin & risk parameters" subtitle="Loading…" />;

  return (
    <>
      <PageHeader
        title="Admin & risk parameters"
        subtitle="Risk-reducing actions are instant (guardian); risk-increasing ones wait out the timelock, so users can see them coming and exit."
        right={<Segmented value={tab} onChange={setTab} options={[{ value: "governance", label: "Timelock" }, { value: "emergency", label: "Emergency" }, { value: "oracle", label: "Oracle lab" }]} />}
      />

      <Card className="mb-6">
        <div className="flex flex-wrap items-center gap-x-8 gap-y-2 px-5 py-4 text-sm">
          <span className="text-fg-3">Connected: <span className="num text-fg">{roles.address ? shortAddress(roles.address) : "–"}</span></span>
          <span className="inline-flex items-center gap-2 text-fg-3">Guardian {roles.isGuardian ? <StatusBadge tone="good">yes</StatusBadge> : <StatusBadge tone="neutral">no</StatusBadge>}</span>
          <span className="inline-flex items-center gap-2 text-fg-3">Timelock proposer {roles.isProposer ? <StatusBadge tone="good">yes</StatusBadge> : <StatusBadge tone="neutral">no</StatusBadge>}</span>
          <span className="inline-flex items-center gap-2 text-fg-3">Mock feed owner {roles.isFeedOwner ? <StatusBadge tone="good">yes</StatusBadge> : <StatusBadge tone="neutral">no</StatusBadge>}</span>
          <span className="text-fg-3">POOL_ADMIN: <span className="num text-fg">timelock {shortAddress(config.contracts.timelock)}</span> · delay {duration(timelock?.minDelaySeconds ?? 0)}</span>
        </div>
      </Card>

      {tab === "governance" && (
        <div className="grid gap-6 xl:grid-cols-2">
          <ProposalForm config={config} markets={markets} enabled={roles.isProposer} delay={timelock?.minDelaySeconds ?? 60} />
          <div className="space-y-6">
            <TimelockQueue config={config} markets={markets} canCancel={roles.isProposer} />
            <Card>
              <CardHeader title="Current parameters" />
              <Table>
                <thead>
                  <tr>
                    <Th>Market</Th>
                    <Th right>LTV</Th>
                    <Th right>LT</Th>
                    <Th right>Bonus</Th>
                    <Th right>RF</Th>
                  </tr>
                </thead>
                <tbody>
                  {markets.map((m) => (
                    <Row key={m.asset}>
                      <Td><Asset symbol={m.symbol} /></Td>
                      <Td right>{pct(m.config.ltv, 1)}</Td>
                      <Td right>{pct(m.config.liquidationThreshold, 1)}</Td>
                      <Td right>{pct(m.config.liquidationBonus, 2)}</Td>
                      <Td right>{pct(m.config.reserveFactor, 0)}</Td>
                    </Row>
                  ))}
                </tbody>
              </Table>
            </Card>
          </div>
        </div>
      )}
      {tab === "emergency" && <EmergencyControls config={config} markets={markets} oracle={oracle.assets} enabled={roles.isGuardian} />}
      {tab === "oracle" && <OracleLab config={config} oracle={oracle} enabled={roles.isFeedOwner} />}
    </>
  );
}

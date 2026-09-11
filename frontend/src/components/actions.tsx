"use client";

import { lendingPoolAbi, mockErc20Abi } from "@lending/shared";
import clsx from "clsx";
import { useEffect, useMemo, useState } from "react";
import { maxUint256, type Address } from "viem";
import { useAccount } from "wagmi";
import type { Market, Position } from "@/lib/api";
import { formatUnitsExact, healthFactor, parseAmount, pct, tokenAmount, usd } from "@/lib/format";
import { useAccount as useAccountData, useAccountPositions, useConfig, useMarkets } from "@/lib/hooks";
import { levelFor, project, type Action } from "@/lib/risk";
import { useTransactor, type TxStep } from "@/lib/tx";
import { Button, Callout, Card, HealthFactor, RiskBadge, Segmented, TokenIcon } from "./ui";

const FAUCET: Record<string, string> = { WETH: "10", WBTC: "1", USDC: "10000" };

const LABEL: Record<Action, string> = { supply: "Supply", withdraw: "Withdraw", borrow: "Borrow", repay: "Repay" };

/**
 * One panel for the four account actions. What the user sees before signing:
 *  - the maximum the pool will accept (from PoolLens, with a 1 ppm rounding haircut)
 *  - their health factor before -> after, computed like the RiskEngine
 *  - blocking conditions (frozen / paused / oracle down) in plain language
 * Every transaction is simulated first (useTransactor), so reverts are explained, not signed.
 */
export function ActionPanel({ modes, initialAsset }: { modes: [Action, Action]; initialAsset?: string }) {
  const { address, isConnected } = useAccount();
  const { data: config } = useConfig();
  const { data: markets } = useMarkets();
  const { data: account } = useAccountData(address);
  const { data: positions } = useAccountPositions(address);
  const [mode, setMode] = useState<Action>(modes[0]);
  const [assetIdx, setAssetIdx] = useState(0);
  const [input, setInput] = useState("");
  const [isMax, setIsMax] = useState(false);
  const tx = useTransactor();

  useEffect(() => {
    if (initialAsset && markets) {
      const i = markets.findIndex((m) => m.asset.toLowerCase() === initialAsset.toLowerCase() || m.symbol === initialAsset);
      if (i >= 0) setAssetIdx(i);
    }
  }, [initialAsset, markets]);

  const market: Market | undefined = markets?.[assetIdx];
  const position: Position | undefined = positions?.positions.find((p) => p.asset.toLowerCase() === market?.asset.toLowerCase());
  const pool = config?.contracts.lendingPool;

  const maxRaw = useMemo(() => {
    if (!position) return 0n;
    switch (mode) {
      case "supply":
        return BigInt(position.walletBalance.raw);
      case "withdraw":
        return BigInt(position.maxWithdraw.raw);
      case "borrow":
        return BigInt(position.maxBorrow.raw);
      case "repay": {
        const debt = BigInt(position.borrowed.raw);
        const wallet = BigInt(position.walletBalance.raw);
        return debt < wallet ? debt : wallet;
      }
    }
  }, [position, mode]);

  const amount = market ? parseAmount(input, market.decimals) : null;
  const amountNum = amount !== null && market ? Number(formatUnitsExact(amount, market.decimals)) : 0;
  const projection = account && market ? project(account, market, mode, amountNum, position?.collateralEnabled ?? false) : null;

  const blocker = (() => {
    if (!market) return null;
    const c = market.config;
    if (!c.active) return "This market is not active.";
    if (c.paused && mode !== "repay") return "Market paused by the guardian. Only repayments are possible.";
    if (c.frozen && (mode === "supply" || mode === "borrow")) return "Market frozen: no new supply or borrowing. Withdrawals and repayments still work.";
    if (mode === "borrow" && !c.borrowingEnabled) return "Borrowing is disabled for this asset.";
    if ((mode === "borrow" || mode === "withdraw") && market.price.status !== "OK" && market.price.status !== "OK_PRIMARY_ONLY" && market.price.status !== "OK_FALLBACK")
      return `Oracle ${market.price.status}: risk-increasing actions are halted until the price recovers.`;
    // The account itself cannot be valued when ANY asset it is exposed to has no trusted price
    // (e.g. borrowing USDC against WETH while the WETH feed is down). Say so before signing.
    const hasDebt = positions?.positions.some((p) => p.borrowed.raw !== "0") ?? false;
    if (account && !account.priced && (mode === "borrow" || (mode === "withdraw" && position?.collateralEnabled && hasDebt)))
      return "A price feed for an asset in your account is unavailable, so your position cannot be valued. Borrowing and collateral withdrawals are halted until it recovers. Repaying and supplying still work.";
    return null;
  })();

  const exceedsMax = !blocker && amount !== null && !isMax && amount > maxRaw && mode !== "repay";
  const insufficientWallet = mode === "repay" && amount !== null && position && amount > BigInt(position.walletBalance.raw);
  const hfAfter = projection?.healthFactor ?? null;
  const risky = Boolean(account?.priced) && (mode === "borrow" || mode === "withdraw") && hfAfter !== null && hfAfter < 1.2;

  async function submit() {
    if (!market || !pool || !address || amount === null) return;
    const asset = market.asset as Address;
    const steps: TxStep[] = [];
    const allowance = BigInt(position?.allowance ?? "0");
    if (mode === "supply" || mode === "repay") {
      // Full repay passes max-uint so interest accrued between read and inclusion is covered;
      // approve a 0.1% buffer on top of the displayed debt for that case.
      const need = mode === "repay" && isMax ? (BigInt(position?.borrowed.raw ?? "0") * 1001n) / 1000n : amount;
      if (allowance < need) steps.push({ label: `Approve ${market.symbol}`, address: asset, abi: mockErc20Abi, functionName: "approve", args: [pool, need] });
    }
    const value = isMax && (mode === "withdraw" || mode === "repay") ? maxUint256 : amount;
    if (mode === "supply") steps.push({ label: "Supply", address: pool, abi: lendingPoolAbi, functionName: "supply", args: [asset, value, address] });
    if (mode === "withdraw") steps.push({ label: "Withdraw", address: pool, abi: lendingPoolAbi, functionName: "withdraw", args: [asset, value, address] });
    if (mode === "borrow") steps.push({ label: "Borrow", address: pool, abi: lendingPoolAbi, functionName: "borrow", args: [asset, value] });
    if (mode === "repay") steps.push({ label: "Repay", address: pool, abi: lendingPoolAbi, functionName: "repay", args: [asset, value, address] });
    const ok = await tx.run(steps, `${LABEL[mode]} ${isMax ? "all" : input} ${market.symbol} confirmed`);
    if (ok) {
      setInput("");
      setIsMax(false);
    }
  }

  async function faucet() {
    if (!market || !address) return;
    const amt = parseAmount(FAUCET[market.symbol] ?? "100", market.decimals)!;
    await tx.run([{ label: "Mint", address: market.asset, abi: mockErc20Abi, functionName: "mint", args: [address, amt] }], `Minted ${FAUCET[market.symbol]} test ${market.symbol}`);
  }

  return (
    <Card>
      <div className="flex items-center justify-between border-b border-line px-5 py-3">
        <Segmented
          value={mode}
          onChange={(m) => {
            setMode(m);
            setInput("");
            setIsMax(false);
            tx.reset();
          }}
          options={modes.map((m) => ({ value: m, label: LABEL[m] }))}
        />
        {market && isConnected && (
          <button onClick={faucet} className="text-xs text-accent hover:underline" disabled={tx.busy}>
            Get test {market.symbol}
          </button>
        )}
      </div>

      <div className="space-y-4 p-5">
        <div className="flex flex-wrap gap-2">
          {markets?.map((m, i) => (
            <button
              key={m.asset}
              onClick={() => {
                setAssetIdx(i);
                setInput("");
                setIsMax(false);
              }}
              className={clsx(
                "inline-flex items-center gap-2 rounded-lg border px-3 py-1.5 text-sm",
                i === assetIdx ? "border-accent bg-accent-soft text-fg" : "border-line text-fg-2 hover:border-line-strong",
              )}
            >
              <TokenIcon symbol={m.symbol} size={18} />
              {m.symbol}
            </button>
          ))}
        </div>

        <div className="rounded-lg border border-line bg-surface-2 p-3">
          <div className="flex items-center justify-between text-xs text-fg-3">
            <span>Amount</span>
            {market && position && (
              <span>
                {mode === "supply" || mode === "repay" ? "Wallet" : mode === "withdraw" ? "Withdrawable" : "Available"}{" "}
                <span className="num text-fg-2">{tokenAmount(Number(formatUnitsExact(mode === "repay" ? position.walletBalance.raw : maxRaw, market.decimals)))}</span>
              </span>
            )}
          </div>
          <div className="mt-1 flex items-center gap-2">
            <input
              inputMode="decimal"
              placeholder="0.00"
              value={input}
              onChange={(e) => {
                setInput(e.target.value.replace(",", "."));
                setIsMax(false);
              }}
              className="num w-full bg-transparent text-2xl font-semibold text-fg outline-none placeholder:text-fg-3"
              aria-label="Amount"
            />
            <button
              className="rounded-md border border-line-strong px-2 py-1 text-xs font-medium text-fg-2 hover:text-fg"
              onClick={() => {
                if (!market) return;
                setInput(formatUnitsExact(maxRaw, market.decimals));
                setIsMax(mode === "withdraw" ? maxRaw === BigInt(position?.supplied.raw ?? "-1") : mode === "repay" ? maxRaw === BigInt(position?.borrowed.raw ?? "-1") : false);
              }}
            >
              MAX
            </button>
          </div>
          <div className="num mt-1 text-xs text-fg-3">{market ? usd(amountNum * market.price.usd) : ""}</div>
        </div>

        {market && account && (
          <dl className="space-y-2 text-sm">
            <div className="flex justify-between">
              <dt className="text-fg-3">{mode === "supply" || mode === "withdraw" ? "Supply APY" : "Borrow APY"}</dt>
              <dd className="num text-fg">{pct(mode === "supply" || mode === "withdraw" ? market.supplyApy : market.borrowApy)}</dd>
            </div>
            <div className="flex items-center justify-between">
              <dt className="text-fg-3">Health factor</dt>
              {account.priced ? (
                <dd className="num flex items-center gap-2 text-fg">
                  <span className="text-fg-2">{healthFactor(account.healthFactor)}</span>
                  <span className="text-fg-3">→</span>
                  <span style={{ color: amountNum > 0 ? undefined : "var(--text-muted)" }}>{healthFactor(amountNum > 0 ? hfAfter : account.healthFactor)}</span>
                  {amountNum > 0 && <RiskBadge level={levelFor(hfAfter)} />}
                </dd>
              ) : (
                <dd className="text-fg-3">cannot be valued (oracle down)</dd>
              )}
            </div>
            <div className="flex justify-between">
              <dt className="text-fg-3">Borrow capacity used</dt>
              <dd className="num text-fg">
                {projection && projection.borrowCapacityUsd > 0 ? pct(projection.debtUsd / projection.borrowCapacityUsd, 1) : account.totalDebtUsd > 0 ? "100%+" : "0%"}
              </dd>
            </div>
            {(mode === "supply" || mode === "withdraw") && <div className="flex justify-between">
              <dt className="text-fg-3">Collateral</dt>
              <dd className="text-fg-2">
                {market.config.collateralEnabled ? `LTV ${pct(market.config.ltv, 0)} · liquidation at ${pct(market.config.liquidationThreshold, 1)}` : "not usable as collateral"}
              </dd>
            </div>}
          </dl>
        )}

        {blocker && <Callout tone="warning" title="Unavailable">{blocker}</Callout>}
        {exceedsMax && <Callout tone="critical" title="Above the maximum">The pool would reject this amount. Use MAX for the largest safe value.</Callout>}
        {insufficientWallet && <Callout tone="critical" title="Wallet balance too low">Use the test faucet above.</Callout>}
        {risky && !exceedsMax && (
          <Callout tone={hfAfter! < 1.05 ? "critical" : "warning"} title="Close to liquidation">
            A {pct(1 - 1 / hfAfter!, 1)} drop in your collateral's value would make this position liquidatable.
          </Callout>
        )}
        {tx.error && <Callout tone="critical" title="Transaction not sent">{tx.error}</Callout>}

        <Button
          className="w-full"
          disabled={!isConnected || !amount || amount === 0n || Boolean(blocker) || exceedsMax || Boolean(insufficientWallet) || tx.busy}
          onClick={submit}
        >
          {!isConnected ? "Connect a wallet" : tx.busy ? `${tx.step}…` : `${LABEL[mode]} ${market?.symbol ?? ""}`}
        </Button>
        {account && <div className="flex justify-end"><HealthFactor value={account.healthFactor} priced={account.priced} /></div>}
      </div>
    </Card>
  );
}

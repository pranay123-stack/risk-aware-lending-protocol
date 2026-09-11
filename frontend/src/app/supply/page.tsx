"use client";

import { lendingPoolAbi } from "@lending/shared";
import { useSearchParams } from "next/navigation";
import { Suspense } from "react";
import { zeroAddress } from "viem";
import { useAccount } from "wagmi";
import { ActionPanel } from "@/components/actions";
import { Asset, Button, Card, CardHeader, Empty, KeyValue, PageHeader, Row, Table, Td, Th } from "@/components/ui";
import { pct, shortAddress, tokenAmount, usd } from "@/lib/format";
import { useAccountPositions, useConfig } from "@/lib/hooks";
import { useTransactor } from "@/lib/tx";

function Supplies() {
  const { address } = useAccount();
  const { data: config } = useConfig();
  const { data } = useAccountPositions(address);
  const tx = useTransactor();
  const supplies = data?.positions.filter((p) => p.supplied.raw !== "0") ?? [];

  return (
    <Card>
      <CardHeader title="Your supplies" subtitle="Supplied assets earn the supply APY; enabled collateral backs your borrowing" />
      {!address ? (
        <Empty>Connect a wallet to see your supplies.</Empty>
      ) : supplies.length === 0 ? (
        <Empty>Nothing supplied yet.</Empty>
      ) : (
        <Table>
          <thead>
            <tr>
              <Th>Asset</Th>
              <Th right>Balance</Th>
              <Th right>APY</Th>
              <Th right>Collateral</Th>
            </tr>
          </thead>
          <tbody>
            {supplies.map((p) => (
              <Row key={p.asset}>
                <Td>
                  <Asset symbol={p.symbol} />
                </Td>
                <Td right>
                  <div>{tokenAmount(p.supplied.amount, p.symbol)}</div>
                  <div className="text-xs text-fg-3">{usd(p.supplied.usd)}</div>
                </Td>
                <Td right className="text-good">{pct(p.supplyApy)}</Td>
                <Td right>
                  <Button
                    size="sm"
                    variant={p.collateralEnabled ? "secondary" : "ghost"}
                    disabled={tx.busy || !config}
                    onClick={() =>
                      tx.run(
                        [
                          {
                            label: p.collateralEnabled ? "Disable collateral" : "Enable collateral",
                            address: config!.contracts.lendingPool,
                            abi: lendingPoolAbi,
                            functionName: "setUseReserveAsCollateral",
                            args: [p.asset, !p.collateralEnabled],
                          },
                        ],
                        `${p.symbol} collateral ${p.collateralEnabled ? "disabled" : "enabled"}`,
                      )
                    }
                  >
                    {p.collateralEnabled ? "On" : "Off"}
                  </Button>
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

function VaultInfo() {
  const { data: config } = useConfig();
  const vaults = config?.markets.filter((m) => m.vault !== zeroAddress) ?? [];
  return (
    <Card>
      <CardHeader title="Passive lending: ERC-4626 vaults" subtitle="Composable share tokens over a pool supply position" />
      <KeyValue items={vaults.map((v) => [`lv${v.symbol}`, shortAddress(v.vault)])} />
      <p className="px-5 pb-4 text-xs leading-relaxed text-fg-3">
        The vault never borrows, so its withdrawals never read an oracle and stay available during a price-feed outage.
        Virtual-share offsets make the first-depositor inflation attack unprofitable.
      </p>
    </Card>
  );
}

function SupplyContent() {
  const asset = useSearchParams().get("asset") ?? undefined;
  return (
    <div className="grid gap-6 lg:grid-cols-5">
      <div className="lg:col-span-2">
        <ActionPanel modes={["supply", "withdraw"]} initialAsset={asset} />
      </div>
      <div className="space-y-6 lg:col-span-3">
        <Supplies />
        <Card>
          <CardHeader title="How collateral works" />
          <ul className="space-y-2 px-5 py-4 text-sm text-fg-2">
            <li>• Your first supply of an asset enables it as collateral automatically. A supply made <em>on your behalf</em> by someone else never does, so nobody can add oracle exposure to your account.</li>
            <li>• Collateral can be disabled or withdrawn only while your remaining debt stays within your LTV borrowing capacity.</li>
            <li>• If you have no debt, withdrawals need no price at all, and work even while an oracle is down.</li>
          </ul>
        </Card>
        <VaultInfo />
      </div>
    </div>
  );
}

export default function SupplyPage() {
  return (
    <>
      <PageHeader title="Supply" subtitle="Lend assets to earn the variable supply rate, and use them as collateral to borrow." />
      <Suspense>
        <SupplyContent />
      </Suspense>
    </>
  );
}

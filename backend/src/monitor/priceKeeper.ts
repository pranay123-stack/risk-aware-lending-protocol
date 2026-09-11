import { mockAggregatorAbi, oracleManagerAbi } from "@lending/shared";
import { createWalletClient, http, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry } from "viem/chains";
import type { AppContext } from "../context.js";

/**
 * LOCAL DEMO ONLY. Mock feeds go stale after their heartbeat like real ones, and then every borrow,
 * collateral withdrawal and liquidation correctly reverts. For a long-running local stack, this
 * keeper re-posts each mock's current answer once half its heartbeat has elapsed. It never changes a
 * price. It only runs on chain 31337, and only for feeds the keeper key actually owns.
 */
export class MockPriceKeeper {
  private readonly account;
  private readonly wallet;

  constructor(
    private readonly ctx: AppContext,
    privateKey: Hex,
    private readonly refreshShare = 0.5,
  ) {
    if (ctx.deployment.chainId !== foundry.id) throw new Error("MockPriceKeeper is for the local Anvil chain only");
    this.account = privateKeyToAccount(privateKey);
    this.wallet = createWalletClient({ account: this.account, chain: foundry, transport: http(ctx.config.rpcUrl) });
  }

  async tick(): Promise<Address[]> {
    const { client, deployment } = this.ctx;
    const head = await client.getBlock({ blockTag: "latest" });
    // The poke must happen before the NEXT transaction sees a stale price, and on an idle Anvil the
    // next block is mined at wall-clock time, not at the (possibly hours-old) head timestamp.
    const now = Math.max(Number(head.timestamp), Math.floor(Date.now() / 1000));
    const poked: Address[] = [];
    for (const m of deployment.markets) {
      const cfg = await client.readContract({ address: deployment.contracts.oracleManager, abi: oracleManagerAbi, functionName: "getAssetConfig", args: [m.token] });
      const feeds: [Address, number][] = [[m.primaryFeed, Number(cfg.primaryHeartbeat)]];
      if (m.secondaryFeed !== zeroAddress) feeds.push([m.secondaryFeed, Number(cfg.secondaryHeartbeat)]);
      for (const [feed, heartbeat] of feeds) {
        const owner = await client.readContract({ address: feed, abi: mockAggregatorAbi, functionName: "owner" }).catch(() => null);
        if (!owner || owner.toLowerCase() !== this.account.address.toLowerCase()) continue;
        const [, , , updatedAt] = await client.readContract({ address: feed, abi: mockAggregatorAbi, functionName: "latestRoundData" });
        const age = now - Number(updatedAt);
        if (age < heartbeat * this.refreshShare) continue;
        const hash = await this.wallet.writeContract({ address: feed, abi: mockAggregatorAbi, functionName: "poke" });
        await client.waitForTransactionReceipt({ hash });
        poked.push(feed);
      }
    }
    if (poked.length) this.ctx.log.info({ poked }, "refreshed mock price feeds");
    return poked;
  }
}

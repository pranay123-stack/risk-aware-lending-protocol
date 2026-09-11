import { createConfig, createConnector, http } from "wagmi";
import { foundry } from "wagmi/chains";
import { injected } from "wagmi/connectors";
import type { Address, EIP1193Provider } from "viem";

export const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL ?? "http://127.0.0.1:8545";
export const DEV_WALLETS_ENABLED = (process.env.NEXT_PUBLIC_DEV_WALLETS ?? "true") === "true";

/**
 * Anvil's default accounts (derived from its PUBLIC test mnemonic). They are unlocked on the Anvil
 * node itself, so this connector forwards eth_sendTransaction and Anvil signs. No private key ever
 * reaches the browser, and on any real network these connectors cannot sign anything.
 */
export const DEV_ACCOUNTS: { index: number; label: string; role: string; address: Address }[] = [
  { index: 0, label: "Deployer", role: "guardian · timelock proposer · feed owner", address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" },
  { index: 1, label: "Alice", role: "liquidity provider", address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" },
  { index: 2, label: "Bob", role: "WETH borrower", address: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC" },
  { index: 3, label: "Carol", role: "WBTC borrower", address: "0x90F79bf6EB2c4f870365E785982E1f101E93b906" },
  { index: 4, label: "Liquidator", role: "liquidator", address: "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65" },
];

const storageKey = (i: number) => `lending.devWallet.${i}`;

function anvilProvider(address: Address): EIP1193Provider {
  let id = 0;
  return {
    async request({ method, params }: { method: string; params?: unknown }) {
      if (method === "eth_accounts" || method === "eth_requestAccounts") return [address];
      if (method === "eth_chainId") return `0x${foundry.id.toString(16)}`;
      if (method === "wallet_switchEthereumChain" || method === "wallet_requestPermissions") return null;
      const res = await fetch(RPC_URL, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params: params ?? [] }),
      });
      const body = await res.json();
      if (body.error) {
        // Preserve code + revert data so viem decodes custom errors.
        const err = new Error(body.error.message) as Error & { code: number; data?: unknown };
        err.code = body.error.code;
        err.data = body.error.data;
        throw err;
      }
      return body.result;
    },
    on() {},
    removeListener() {},
  } as unknown as EIP1193Provider;
}

export function anvilDevWallet(account: (typeof DEV_ACCOUNTS)[number]) {
  const provider = anvilProvider(account.address);
  return createConnector<EIP1193Provider>((config) => ({
    id: `anvil-${account.index}`,
    name: `${account.label} (Anvil #${account.index})`,
    type: "anvil-dev",
    async connect() {
      localStorage.setItem(storageKey(account.index), "1");
      return { accounts: [account.address], chainId: foundry.id } as never;
    },
    async disconnect() {
      localStorage.removeItem(storageKey(account.index));
    },
    async getAccounts() {
      return [account.address];
    },
    async getChainId() {
      return foundry.id;
    },
    async getProvider() {
      return provider;
    },
    async isAuthorized() {
      return typeof localStorage !== "undefined" && localStorage.getItem(storageKey(account.index)) === "1";
    },
    onAccountsChanged() {},
    onChainChanged() {},
    onDisconnect() {
      config.emitter.emit("disconnect");
    },
  }));
}

export const wagmiConfig = createConfig({
  chains: [foundry],
  connectors: [injected(), ...(DEV_WALLETS_ENABLED ? DEV_ACCOUNTS.map(anvilDevWallet) : [])],
  transports: { [foundry.id]: http(RPC_URL) },
  ssr: true,
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}

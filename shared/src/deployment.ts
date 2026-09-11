import { getAddress, zeroAddress, type Address } from "viem";
import { z } from "zod";

const address = z
  .string()
  .regex(/^0x[0-9a-fA-F]{40}$/, "not an address")
  .transform((a) => getAddress(a) as Address);

export const marketDeploymentSchema = z.object({
  symbol: z.string(),
  token: address,
  primaryFeed: address,
  secondaryFeed: address,
  interestRateModel: address,
  vault: address,
});

/** Shape of deployments/<chainId>.json written by script/Deploy.s.sol. */
export const deploymentSchema = z.object({
  chainId: z.number().int().positive(),
  startBlock: z.number().int().nonnegative(),
  deployer: address,
  guardian: address,
  timelockProposer: address,
  timelockDelay: z.number().int().nonnegative(),
  contracts: z.object({
    aclManager: address,
    oracleManager: address,
    lendingPool: address,
    poolConfigurator: address,
    poolLens: address,
    timelock: address,
  }),
  markets: z.array(marketDeploymentSchema).min(1),
});

export type Deployment = z.infer<typeof deploymentSchema>;
export type MarketDeployment = z.infer<typeof marketDeploymentSchema>;

export function parseDeployment(json: unknown): Deployment {
  return deploymentSchema.parse(json);
}

/** Price feed -> (asset, role) map, so feed events can be attributed to a market. */
export function feedIndex(d: Deployment): Map<Address, { asset: Address; symbol: string; role: "primary" | "secondary" }> {
  const map = new Map<Address, { asset: Address; symbol: string; role: "primary" | "secondary" }>();
  for (const m of d.markets) {
    map.set(m.primaryFeed, { asset: m.token, symbol: m.symbol, role: "primary" });
    if (m.secondaryFeed !== zeroAddress) map.set(m.secondaryFeed, { asset: m.token, symbol: m.symbol, role: "secondary" });
  }
  return map;
}

export function vaults(d: Deployment): Address[] {
  return d.markets.map((m) => m.vault).filter((v) => v !== zeroAddress);
}

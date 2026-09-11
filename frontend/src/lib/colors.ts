/**
 * Entity colors: every chart and badge colours an asset the same way, by identity, never by rank
 * (dataviz: "color follows the entity"). Slots come from the validated categorical palette in
 * globals.css (--series-1..5), checked with the palette validator against both card surfaces.
 */
const ASSET_SLOTS: Record<string, number> = { WETH: 1, WBTC: 2, USDC: 3 };

export function assetColor(symbol: string): string {
  const slot = ASSET_SLOTS[symbol] ?? 4;
  return `var(--series-${slot})`;
}

/** Fixed series order for non-asset categorical charts (activity types, supply vs borrow). */
export const SERIES = ["var(--series-1)", "var(--series-2)", "var(--series-3)", "var(--series-4)", "var(--series-5)"] as const;

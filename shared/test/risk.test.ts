import { describe, expect, it } from "vitest";
import { MAX_UINT256, RAY, WAD } from "../src/math.js";
import { classifyHealthFactor, distanceToLiquidation, evaluateAccount, evaluateMarket, type MarketRiskInput } from "../src/risk.js";

const hf = (x: number) => (BigInt(Math.round(x * 1e6)) * WAD) / 1_000_000n;

describe("classifyHealthFactor", () => {
  it.each([
    [0.5, "LIQUIDATABLE"],
    [0.999999, "LIQUIDATABLE"],
    [1.0, "DANGER"],
    [1.19, "DANGER"],
    [1.2, "WARNING"],
    [1.49, "WARNING"],
    [1.5, "SAFE"],
    [3, "SAFE"],
  ] as const)("HF %s -> %s", (value, level) => {
    expect(classifyHealthFactor(hf(value))).toBe(level);
  });

  it("treats no debt as SAFE and unpriceable accounts as UNKNOWN", () => {
    expect(classifyHealthFactor(MAX_UINT256)).toBe("SAFE");
    expect(classifyHealthFactor(hf(0.5), { priced: false })).toBe("UNKNOWN");
  });

  it("reports the collateral drop that reaches HF = 1", () => {
    expect(distanceToLiquidation(hf(2))).toBeCloseTo(0.5, 6);
    expect(distanceToLiquidation(hf(1.25))).toBeCloseTo(0.2, 6);
    expect(distanceToLiquidation(hf(0.9))).toBe(0);
    expect(distanceToLiquidation(MAX_UINT256)).toBeNull();
  });
});

const market = (over: Partial<MarketRiskInput> = {}): MarketRiskInput => ({
  reserve: "0xabc",
  symbol: "USDC",
  utilizationRay: (50n * RAY) / 100n,
  cash: 500n,
  totalSupplied: 1_000n,
  deficit: 0n,
  priceStatus: "OK",
  ...over,
});

describe("evaluateMarket", () => {
  it("is quiet for a healthy market", () => {
    expect(evaluateMarket(market())).toEqual([]);
  });

  it("flags high and critical utilization", () => {
    expect(evaluateMarket(market({ utilizationRay: (92n * RAY) / 100n, cash: 80n }))[0]).toMatchObject({ kind: "HIGH_UTILIZATION", severity: "warning" });
    const kinds = evaluateMarket(market({ utilizationRay: (98n * RAY) / 100n, cash: 20n })).map((f) => [f.kind, f.severity]);
    expect(kinds).toContainEqual(["HIGH_UTILIZATION", "critical"]);
    expect(kinds).toContainEqual(["LOW_LIQUIDITY", "critical"]);
  });

  it("flags abnormal utilization jumps in either direction", () => {
    const f = evaluateMarket(market({ previousUtilizationRay: (20n * RAY) / 100n }));
    expect(f.map((x) => x.kind)).toEqual(["ABNORMAL_UTILIZATION"]);
  });

  it("distinguishes a degraded oracle from an unavailable one", () => {
    expect(evaluateMarket(market({ priceStatus: "OK_FALLBACK" }))[0]).toMatchObject({ kind: "ORACLE_DEGRADED", severity: "warning" });
    expect(evaluateMarket(market({ priceStatus: "DEVIATION" }))[0]).toMatchObject({ kind: "ORACLE_UNAVAILABLE", severity: "critical" });
  });

  it("warns before a feed goes stale", () => {
    expect(evaluateMarket(market({ priceAgeSeconds: 3_000, heartbeatSeconds: 3_600 }))[0]?.kind).toBe("ORACLE_STALE_SOON");
    expect(evaluateMarket(market({ priceAgeSeconds: 1_000, heartbeatSeconds: 3_600 }))).toEqual([]);
  });

  it("flags recognised bad debt", () => {
    expect(evaluateMarket(market({ deficit: 1n }))[0]).toMatchObject({ kind: "BAD_DEBT", severity: "critical" });
  });
});

describe("evaluateAccount", () => {
  const base = { account: "0xbob", priced: true, collateralUsd: 18_000, debtUsd: 15_000 };

  it("raises LIQUIDATABLE for HF < 1", () => {
    const r = evaluateAccount({ ...base, healthFactor: hf(0.99) }, 1_000_000);
    expect(r.level).toBe("LIQUIDATABLE");
    expect(r.findings.map((f) => f.kind)).toEqual(["LIQUIDATABLE"]);
  });

  it("flags potential bad debt when collateral < debt", () => {
    const r = evaluateAccount({ ...base, collateralUsd: 14_000, healthFactor: hf(0.77) }, 1_000_000);
    expect(r.findings.map((f) => f.kind)).toContain("POTENTIAL_BAD_DEBT");
  });

  it("flags large borrowers by size or share", () => {
    expect(evaluateAccount({ ...base, debtUsd: 150_000, collateralUsd: 400_000, healthFactor: hf(2) }, 10_000_000).findings[0]?.kind).toBe("LARGE_BORROW");
    expect(evaluateAccount({ ...base, healthFactor: hf(2) }, 50_000).findings[0]?.kind).toBe("LARGE_BORROW"); // 30% share
  });

  it("marks unpriceable accounts UNKNOWN without guessing a health factor", () => {
    const r = evaluateAccount({ ...base, priced: false, healthFactor: 0n, collateralUsd: 0, debtUsd: 0 }, 1);
    expect(r.level).toBe("UNKNOWN");
    expect(r.findings.map((f) => f.kind)).toEqual(["UNPRICEABLE_ACCOUNT"]);
  });
});

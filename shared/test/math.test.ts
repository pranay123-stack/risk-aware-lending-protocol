import { describe, expect, it } from "vitest";
import {
  MAX_UINT256,
  RAY,
  WAD,
  aprToApy,
  healthFactorToNumber,
  impliedSupplyRate,
  kinkedBorrowRate,
  toNumber,
  usdValue,
} from "../src/math.js";

const PCT = RAY / 100n;
const usdcCurve = { baseRate: 0n, slope1: 6n * PCT, slope2: 60n * PCT, optimalUtilization: 90n * PCT };

describe("fixed-point conversion", () => {
  it("keeps full precision for normal magnitudes", () => {
    expect(toNumber(1_234_567_890n, 6)).toBeCloseTo(1234.56789, 10);
    expect(toNumber(WAD / 3n, 18)).toBeCloseTo(0.333333333333333, 12);
  });

  it("computes USD values with the token's own decimals", () => {
    expect(usdValue(10n * WAD, 18, 2_500n * WAD)).toBe(25_000); // 10 WETH @ $2,500
    expect(usdValue(15_000n * 10n ** 6n, 6, WAD)).toBe(15_000); // 15k USDC @ $1
    expect(usdValue(5n * 10n ** 8n, 8, 60_000n * WAD)).toBe(300_000); // 5 WBTC @ $60k
  });

  it("maps the no-debt sentinel to Infinity", () => {
    expect(healthFactorToNumber(MAX_UINT256)).toBe(Number.POSITIVE_INFINITY);
    expect(healthFactorToNumber((99n * WAD) / 100n)).toBeCloseTo(0.99, 12);
  });
});

describe("APR -> APY", () => {
  it("is the identity at zero and compounds above it", () => {
    expect(aprToApy(0n)).toBe(0);
    expect(aprToApy(10n * PCT)).toBeCloseTo(Math.exp(0.1) - 1, 6); // per-second ~= continuous
    expect(aprToApy(10n * PCT)).toBeGreaterThan(0.1);
  });
});

describe("kinked rate model mirror", () => {
  it("matches the on-chain curve at the anchor points (USDC params)", () => {
    expect(kinkedBorrowRate(0n, usdcCurve)).toBe(0n);
    expect(kinkedBorrowRate(90n * PCT, usdcCurve)).toBe(6n * PCT);
    expect(kinkedBorrowRate(RAY, usdcCurve)).toBe(66n * PCT);
    expect(kinkedBorrowRate(95n * PCT, usdcCurve)).toBe(36n * PCT);
  });

  it("is monotonic", () => {
    let prev = -1n;
    for (let u = 0n; u <= 100n; u += 5n) {
      const r = kinkedBorrowRate(u * PCT, usdcCurve);
      expect(r >= prev).toBe(true);
      prev = r;
    }
  });

  it("derives the supply rate as borrow x utilization x (1 - RF)", () => {
    // 50% utilization, 10% borrow rate, 10% reserve factor -> 4.5%
    expect(impliedSupplyRate(10n * PCT, 50n * PCT, 1_000n)).toBe(45n * (PCT / 10n));
  });
});

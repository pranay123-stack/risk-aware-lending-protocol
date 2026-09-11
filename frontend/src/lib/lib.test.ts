import { protocolErrorsAbi } from "@lending/shared";
import { ContractFunctionExecutionError, ContractFunctionRevertedError, encodeErrorResult, UserRejectedRequestError, type Abi } from "viem";
import { describe, expect, it } from "vitest";
import type { Health, Market } from "./api";
import { explainError } from "./errors";
import { formatUnitsExact, healthFactor, parseAmount, pct, usd } from "./format";
import { levelFor, project } from "./risk";

describe("amount parsing (no floating point between the input box and the chain)", () => {
  it("parses decimals exactly in base units", () => {
    expect(parseAmount("1.5", 18)).toBe(1_500_000_000_000_000_000n);
    expect(parseAmount("0.000001", 6)).toBe(1n);
    expect(parseAmount("15000", 6)).toBe(15_000_000_000n);
    expect(parseAmount(".5", 8)).toBe(50_000_000n);
    // 0.1 + 0.2 style float error can never occur
    expect(parseAmount("0.3", 18)).toBe(300_000_000_000_000_000n);
  });

  it("rejects malformed input and excess precision", () => {
    expect(parseAmount("", 6)).toBeNull();
    expect(parseAmount("abc", 6)).toBeNull();
    expect(parseAmount("1.2.3", 6)).toBeNull();
    expect(parseAmount("0.0000001", 6)).toBeNull(); // 7 decimals on a 6-decimal token
  });

  it("round-trips through formatUnitsExact", () => {
    for (const s of ["1", "0.5", "123.456789", "0.000001"]) {
      expect(formatUnitsExact(parseAmount(s, 6)!, 6)).toBe(s);
    }
  });

  it("formats display values", () => {
    expect(usd(1234.5)).toBe("$1,234.50");
    expect(usd(750_125, { compact: true })).toBe("$750.13K");
    expect(pct(0.60576)).toBe("60.58%");
    expect(healthFactor(null)).toBe("∞");
    expect(healthFactor(1.11375)).toBe("1.11");
  });
});

const weth = {
  symbol: "WETH",
  price: { usd: 2_500 },
  config: { ltv: 0.8, liquidationThreshold: 0.825, collateralEnabled: true },
} as unknown as Market;
const usdc = { symbol: "USDC", price: { usd: 1 }, config: { ltv: 0.77, liquidationThreshold: 0.8, collateralEnabled: true } } as unknown as Market;

// Bob after the brief's setup: 10 WETH @ $2,500, 15,000 USDC debt.
const bob = { liquidationThresholdUsd: 20_625, borrowCapacityUsd: 20_000, totalDebtUsd: 15_000 } as Health;

describe("health factor projection (mirrors RiskEngine)", () => {
  it("borrowing more lowers HF", () => {
    expect(project(bob, usdc, "borrow", 5_000, false).healthFactor).toBeCloseTo(20_625 / 20_000, 10);
  });

  it("repaying everything clears the debt", () => {
    expect(project(bob, usdc, "repay", 15_000, false).healthFactor).toBeNull();
  });

  it("withdrawing collateral removes LT-weighted value", () => {
    // 1 WETH out: liquidation value drops by 2,500 * 0.825
    expect(project(bob, weth, "withdraw", 1, true).healthFactor).toBeCloseTo((20_625 - 2_062.5) / 15_000, 10);
    // a non-collateral withdrawal does not change HF
    expect(project(bob, weth, "withdraw", 1, false).healthFactor).toBeCloseTo(1.375, 10);
  });

  it("classifies the projected HF with the protocol's levels", () => {
    expect(levelFor(null)).toBe("SAFE");
    expect(levelFor(0.99)).toBe("LIQUIDATABLE");
    expect(levelFor(1.1)).toBe("DANGER");
    expect(levelFor(1.3)).toBe("WARNING");
    expect(levelFor(1.6)).toBe("SAFE");
  });
});

describe("revert explanations", () => {
  const revert = (errorName: string, args?: readonly unknown[]) =>
    new ContractFunctionExecutionError(
      new ContractFunctionRevertedError({
        abi: protocolErrorsAbi as Abi,
        data: encodeErrorResult({ abi: protocolErrorsAbi as Abi, errorName, args } as never),
        functionName: "borrow",
      }),
      { abi: protocolErrorsAbi as Abi, functionName: "borrow" },
    );

  it("decodes protocol custom errors into plain language", () => {
    expect(explainError(revert("BorrowCapacityExceeded"))).toMatch(/borrowing capacity/);
    expect(explainError(revert("MustNotLeaveDust"))).toMatch(/\$1,000/);
    expect(explainError(revert("OraclePriceUnavailable", ["0x0000000000000000000000000000000000000001"]))).toMatch(/price feed is unavailable/);
  });

  it("reports wallet rejections as such", () => {
    expect(explainError(new UserRejectedRequestError(new Error("denied")))).toBe("Transaction rejected in the wallet.");
  });

  it("falls back to the error name for unmapped errors", () => {
    expect(explainError(revert("ReentrancyGuardReentrantCall"))).toBe("Reverted: ReentrancyGuardReentrantCall");
  });
});

/**
 * Fixed-point helpers mirroring the contracts' units.
 *
 *   WAD = 1e18  prices (USD per whole token), USD values, health factors
 *   RAY = 1e27  interest rates (annual), indexes, utilization
 *   BPS = 1e4   risk parameters
 *
 * Everything stays bigint until the final conversion for display, so no float ever touches an
 * on-chain amount.
 */
export const WAD = 10n ** 18n;
export const RAY = 10n ** 27n;
export const BPS = 10_000n;
export const SECONDS_PER_YEAR = 365 * 24 * 60 * 60;
export const MAX_UINT256 = 2n ** 256n - 1n;

/** Scale a fixed-point bigint to a JS number (for display and charts only). */
export function toNumber(value: bigint, decimals: number): number {
  const unit = 10n ** BigInt(decimals);
  const whole = value / unit;
  const frac = value % unit;
  return Number(whole) + Number(frac) / Number(unit);
}

export const rayToNumber = (v: bigint): number => toNumber(v, 27);
export const wadToNumber = (v: bigint): number => toNumber(v, 18);

/**
 * Annual percentage rate (ray) to annual percentage yield, assuming per-second compounding:
 * APY = (1 + APR / s)^s - 1. The pool compounds the borrow index continuously between
 * interactions and credits suppliers linearly per interval, so APY is the right number to show a
 * borrower and a close upper bound for a supplier.
 */
export function aprToApy(aprRay: bigint): number {
  const apr = rayToNumber(aprRay);
  return Math.expm1(SECONDS_PER_YEAR * Math.log1p(apr / SECONDS_PER_YEAR));
}

/** USD value (as a number) of `amount` token units at a WAD price. Exact until the last step. */
export function usdValue(amount: bigint, decimals: number, priceWad: bigint): number {
  return wadToNumber((amount * priceWad) / 10n ** BigInt(decimals));
}

/** Health factor as a number; accounts with no debt report `Infinity` (the pool returns 2^256-1). */
export function healthFactorToNumber(hf: bigint): number {
  return hf === MAX_UINT256 ? Number.POSITIVE_INFINITY : wadToNumber(hf);
}

/** Kinked rate model evaluated off-chain, for rate-curve charts. Mirrors KinkedInterestRateModel. */
export function kinkedBorrowRate(
  utilizationRay: bigint,
  params: { baseRate: bigint; slope1: bigint; slope2: bigint; optimalUtilization: bigint },
): bigint {
  const { baseRate, slope1, slope2, optimalUtilization } = params;
  if (utilizationRay <= optimalUtilization) {
    return baseRate + (slope1 * ((utilizationRay * RAY) / optimalUtilization)) / RAY;
  }
  const excess = ((utilizationRay - optimalUtilization) * RAY) / (RAY - optimalUtilization);
  return baseRate + slope1 + (slope2 * excess) / RAY;
}

/** Supply rate implied by a borrow rate, mirroring ReserveLogic.updateRates (no-deficit case). */
export function impliedSupplyRate(borrowRateRay: bigint, utilizationRay: bigint, reserveFactorBps: bigint): bigint {
  return (((borrowRateRay * utilizationRay) / RAY) * (BPS - reserveFactorBps)) / BPS;
}

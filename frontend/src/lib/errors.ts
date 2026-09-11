import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError } from "viem";

/** Human explanations for every protocol revert a user can trigger from the UI. */
const MESSAGES: Record<string, string> = {
  BorrowCapacityExceeded: "This would put your debt above your borrowing capacity (LTV). Borrow less, add collateral or repay first.",
  InsufficientLiquidity: "Not enough available liquidity in this market right now: it is lent out.",
  InsufficientBalance: "Amount exceeds your supplied balance.",
  SupplyCapExceeded: "This market's supply cap would be exceeded.",
  BorrowCapExceeded: "This market's borrow cap would be exceeded.",
  BorrowingNotEnabled: "Borrowing is disabled for this asset.",
  ReserveFrozen: "This market is frozen: no new supply or borrowing (exits and repayments still work).",
  ReservePaused: "This market is paused by the guardian (repayments still work).",
  PoolPaused: "The protocol is paused by the guardian (repayments still work).",
  ReserveNotActive: "This market is not active.",
  NoDebt: "There is no debt to repay here.",
  NoSupply: "Nothing supplied in this market.",
  ZeroAmount: "Enter an amount greater than zero.",
  AmountTooSmall: "Amount is below one unit at the current index; enter a larger amount.",
  HealthyPosition: "That account is healthy (health factor ≥ 1): it cannot be liquidated.",
  CollateralNotEnabledByUser: "The borrower does not use that asset as collateral.",
  MustNotLeaveDust: "This partial liquidation would leave less than $1,000 behind. Liquidate the full position instead.",
  NothingToLiquidate: "Nothing to liquidate with these parameters.",
  LiquidationGracePeriod: "Liquidations are paused for a grace window after the protocol was unpaused.",
  CollateralNotEnabledForReserve: "This asset cannot be used as collateral.",
  OraclePriceUnavailable: "A price feed is unavailable or stale. Borrows, collateral withdrawals and liquidations are halted for exposed accounts until it recovers.",
  OraclePriceDeviation: "The two price sources disagree beyond tolerance. The circuit breaker halts risk-increasing actions.",
  OracleAssetPaused: "The guardian paused this asset's oracle (circuit breaker).",
  OracleNotConfigured: "This asset has no oracle configured.",
  NotPoolAdmin: "Only the timelocked pool admin can do this.",
  NotEmergencyAdmin: "Only the guardian (or pool admin) can do this.",
  InvalidRiskParameters: "Rejected: parameters break a safety rule (LTV < LT, LT × (1 + bonus) < 100%, bonus ≤ 20%).",
  InvalidReserveFactor: "Reserve factor must be at most 50%.",
  FaucetLimitExceeded: "The test faucet caps each mint. Request a smaller amount.",
  ERC20InsufficientBalance: "Your wallet balance is too low for this transaction.",
  ERC20InsufficientAllowance: "Token allowance too low: approve first.",
  TimelockUnexpectedOperationState: "This timelock operation is not ready (or already executed/cancelled).",
  TimelockInsufficientDelay: "Delay is shorter than the timelock's minimum.",
  AccessControlUnauthorizedAccount: "The connected account does not have the required role.",
  OwnableUnauthorizedAccount: "The connected account does not own this mock feed.",
};

export function explainError(err: unknown): string {
  if (err instanceof BaseError) {
    if (err.walk((e) => e instanceof UserRejectedRequestError)) return "Transaction rejected in the wallet.";
    const revert = err.walk((e) => e instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
    const name = revert?.data?.errorName;
    if (name) return MESSAGES[name] ?? `Reverted: ${name}`;
    if (revert?.reason) return `Reverted: ${revert.reason}`;
    return err.shortMessage;
  }
  return err instanceof Error ? err.message : String(err);
}

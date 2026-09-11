#!/bin/sh
# Idempotent local deployment, run by the `deployer` compose service.
# Deploys + runs the demo scenario only if the contracts are not already on the (persisted) chain.
set -eu
RPC="${RPC_URL:-http://anvil:8545}"
OUT="${DEPLOYMENT_OUT:-/repo/deployments/31337.json}"

if [ -f "$OUT" ]; then
  POOL=$(sed -n 's/.*"lendingPool": *"\(0x[0-9a-fA-F]*\)".*/\1/p' "$OUT" | head -1)
  if [ -n "$POOL" ] && [ "$(cast code "$POOL" --rpc-url "$RPC")" != "0x" ]; then
    echo "Protocol already deployed at $POOL - nothing to do."
    exit 0
  fi
  echo "Deployment file exists but the chain has no code there (fresh Anvil): redeploying."
fi

echo "==> Deploying protocol"
forge script script/Deploy.s.sol --rpc-url "$RPC" --broadcast --slow
if [ "${RUN_DEMO:-true}" = "true" ]; then
  echo "==> Running the demo scenario"
  forge script script/Demo.s.sol --rpc-url "$RPC" --broadcast --slow
fi
echo "==> Done: $OUT"

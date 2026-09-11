#!/usr/bin/env bash
# The brief's local demo in one command (needs only Foundry):
#   1. start Anvil          5. configure markets        9. borrow
#   2. deploy contracts     6. mint test tokens        10. change the oracle price
#   3. deploy mock tokens   7. create sample users     11. trigger a liquidation
#   4. deploy mock oracles  8. supply collateral       12. display the resulting state
#
# Usage: scripts/demo.sh                   (starts a fresh Anvil on :8545 if none is running)
#        ANVIL_PORT=8549 scripts/demo.sh    (another port)
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${ANVIL_PORT:-8545}"
RPC="${RPC_URL:-http://127.0.0.1:$PORT}"
logs() { sed -n '/== Logs ==/,/^\(## \|==========\|Script ran\|SIMULATION\)/p' | grep -vE '^(== Logs ==|## |==========|Script ran|SIMULATION)'; }

if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  CHAIN=$(cast chain-id --rpc-url "$RPC")
  [ "$CHAIN" = "31337" ] || { echo "Refusing: $RPC is chain $CHAIN, not a local Anvil (31337)." >&2; exit 1; }
  if [ "$(cast block-number --rpc-url "$RPC")" != "0" ]; then
    echo "An Anvil chain with history is already running at $RPC."
    echo "Stop it (or pass RPC_URL of a fresh one) so the demo starts from a clean state." >&2
    exit 1
  fi
  echo "==> 1. Using the fresh Anvil already running at $RPC"
else
  echo "==> 1. Starting Anvil (chain 31337) on :$PORT"
  anvil --silent --chain-id 31337 --port "$PORT" > /tmp/anvil-demo.log 2>&1 &
  echo "$!" > /tmp/anvil-demo.pid
  for _ in $(seq 1 50); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done
fi

echo "==> 2-5. Deploying the protocol, mock tokens and mock oracles, configuring markets, handing admin to the timelock"
forge script script/Deploy.s.sol --rpc-url "$RPC" --broadcast --slow | logs

echo
echo "==> 6-12. Running the scenario"
forge script script/Demo.s.sol --rpc-url "$RPC" --broadcast --slow | logs

echo
echo "==> Live chain state (read back from the chain, not the script's simulation)"
forge script script/ShowState.s.sol --rpc-url "$RPC" | logs

echo
echo "Done. Deployment: ${DEPLOYMENT_OUT:-deployments/31337.json}"
[ -f /tmp/anvil-demo.pid ] && echo "Anvil is still running (pid $(cat /tmp/anvil-demo.pid)): stop it with  kill \$(cat /tmp/anvil-demo.pid)"

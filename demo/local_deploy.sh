#!/usr/bin/env bash
# Local rehearsal only: deploy the production contracts against Anvil with a
# mock system contract and a mock callback proxy.  Generates throwaway
# addresses and transactions -- never submit these as hackathon evidence.
#
#   ORIGIN_CHAIN=sepolia       ./demo/local_deploy.sh
#   ORIGIN_CHAIN=base-sepolia  ./demo/local_deploy.sh
set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="${FOUNDRY_BIN:-$HOME/.foundry/bin}:$PATH"

ORIGIN_CHAIN=${ORIGIN_CHAIN:-sepolia}
case "$ORIGIN_CHAIN" in
  sepolia)
    CHAIN_ID=11155111
    PROXY=0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4
    EXPLORER=https://sepolia.etherscan.io
    ;;
  base-sepolia)
    CHAIN_ID=84532
    PROXY=0x476F44b11F5C942c58f4c8E3d0300E5710743585
    EXPLORER=https://sepolia.basescan.org
    ;;
  *)
    echo "ORIGIN_CHAIN must be sepolia or base-sepolia" >&2
    exit 2
    ;;
esac

PORT=${PORT:-8548}
RPC=http://127.0.0.1:$PORT
OUT=${OUT:-/tmp/opencode/reactive-local.json}

if ! cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  (anvil --chain-id "$CHAIN_ID" --port "$PORT" --silent >"/tmp/opencode/anvil-$PORT.log" 2>&1 &)
  sleep 2
fi

ACTUAL_ID=$(cast chain-id --rpc-url "$RPC")
if [[ "$ACTUAL_ID" != "$CHAIN_ID" ]]; then
  echo "Anvil on port $PORT is chain $ACTUAL_ID, expected $CHAIN_ID; use a different PORT" >&2
  exit 2
fi

A=$(cast rpc eth_accounts --rpc-url "$RPC" | jq -r '.[0]')
echo "anvil $RPC  chain $CHAIN_ID  account $A"

create() { forge create --json --broadcast --rpc-url "$RPC" --unlocked --from "$A" "$@"; }

SYS=$(create test/mocks/MockReactive.sol:MockSystem | jq -r .deployedTo)
PROXY_IMPL=$(create test/mocks/MockReactive.sol:MockProxy | jq -r .deployedTo)
cast rpc anvil_setCode 0x8888888888888888888888888888888888888888 "$(cast code "$SYS" --rpc-url "$RPC")" --rpc-url "$RPC" >/dev/null
cast rpc anvil_setCode "$PROXY" "$(cast code "$PROXY_IMPL" --rpc-url "$RPC")" --rpc-url "$RPC" >/dev/null
cast send --unlocked --from "$A" --rpc-url "$RPC" 0x8888888888888888888888888888888888888888 \
  "setProxy(address)" "$PROXY" >/dev/null

FEED=$(create src/PriceFeedOrigin.sol:PriceFeedOrigin --constructor-args "$A" | jq -r .deployedTo)
REACTIVE=$(create src/SentinelReactive.sol:SentinelReactive \
  --constructor-args "$CHAIN_ID" "$FEED" "$CHAIN_ID" "$A" | jq -r .deployedTo)
VAULT=$(create src/SentinelVault.sol:SentinelVault \
  --constructor-args "$PROXY" "$REACTIVE" | jq -r .deployedTo)
cast send --unlocked --from "$A" --rpc-url "$RPC" "$REACTIVE" "setVault(address)" "$VAULT" >/dev/null

jq -n --arg feed "$FEED" --arg reactive "$REACTIVE" --arg vault "$VAULT" \
  --arg rpc "$RPC" --arg rpc_lasna "$RPC" --arg chain "$ORIGIN_CHAIN" --argjson chain_id "$CHAIN_ID" \
  --arg proxy "$PROXY" --arg explorer "$EXPLORER" \
  '{feed:$feed,reactive:$reactive,vault:$vault,rpc:$rpc,rpc_lasna:$rpc_lasna,origin_chain:$chain,
    chain_id:$chain_id,callback_proxy:$proxy,explorer:$explorer}' > "$OUT"
echo "feed $FEED"
echo "reactive $REACTIVE"
echo "vault $VAULT"
echo "wrote $OUT"

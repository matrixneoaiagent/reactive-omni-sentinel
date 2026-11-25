#!/usr/bin/env bash
# Local rehearsal only: deploy the production contracts against Anvil with a
# mock system contract and a mock callback proxy.  Generates throwaway
# addresses and transactions -- never submit these as hackathon evidence.
set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="${FOUNDRY_BIN:-$HOME/.foundry/bin}:$PATH"

PORT=${PORT:-8548}
RPC=http://127.0.0.1:$PORT
OUT=${OUT:-/tmp/opencode/reactive-local.json}

if ! cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  (anvil --chain-id 84532 --port "$PORT" --silent >"/tmp/opencode/anvil-$PORT.log" 2>&1 &)
  sleep 2
fi

A=$(cast rpc eth_accounts --rpc-url "$RPC" | jq -r '.[0]')
echo "anvil $RPC  account $A"

create() { forge create --json --broadcast --rpc-url "$RPC" --unlocked --from "$A" "$@"; }

SYS=$(create test/mocks/MockReactive.sol:MockSystem | jq -r .deployedTo)
PROXY_IMPL=$(create test/mocks/MockReactive.sol:MockProxy | jq -r .deployedTo)
cast rpc anvil_setCode 0x8888888888888888888888888888888888888888 "$(cast code "$SYS" --rpc-url "$RPC")" --rpc-url "$RPC" >/dev/null
cast rpc anvil_setCode 0x476F44b11F5C942c58f4c8E3d0300E5710743585 "$(cast code "$PROXY_IMPL" --rpc-url "$RPC")" --rpc-url "$RPC" >/dev/null
cast send --unlocked --from "$A" --rpc-url "$RPC" 0x8888888888888888888888888888888888888888 \
  "setProxy(address)" 0x476F44b11F5C942c58f4c8E3d0300E5710743585 >/dev/null

FEED=$(create src/PriceFeedOrigin.sol:PriceFeedOrigin --constructor-args "$A" | jq -r .deployedTo)
REACTIVE=$(create src/SentinelReactive.sol:SentinelReactive \
  --constructor-args 84532 "$FEED" 84532 "$A" | jq -r .deployedTo)
VAULT=$(create src/SentinelVault.sol:SentinelVault \
  --constructor-args 0x476F44b11F5C942c58f4c8E3d0300E5710743585 "$REACTIVE" | jq -r .deployedTo)
cast send --unlocked --from "$A" --rpc-url "$RPC" "$REACTIVE" "setVault(address)" "$VAULT" >/dev/null

jq -n --arg feed "$FEED" --arg reactive "$REACTIVE" --arg vault "$VAULT" --arg rpc "$RPC" \
  '{feed:$feed,reactive:$reactive,vault:$vault,rpc:$rpc}' > "$OUT"
echo "feed $FEED"
echo "reactive $REACTIVE"
echo "vault $VAULT"
echo "wrote $OUT"

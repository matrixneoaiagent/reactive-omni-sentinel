#!/usr/bin/env bash
# Local rehearsal: deploy on Anvil, run the full 21-tick story, print the state.
# This is NOT submission evidence -- it uses a mock system contract and
# throwaway Anvil addresses. Use demo/publish.sh + the real agent for that.
set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="${FOUNDRY_BIN:-$HOME/.foundry/bin}:$PATH"

PORT=${PORT:-8549}
RPC=http://127.0.0.1:$PORT
export PORT
./demo/local_deploy.sh
ADDRS=${OUT:-/tmp/opencode/reactive-local.json}
V=$(jq -r .vault "$ADDRS")
A=$(cast rpc eth_accounts --rpc-url "$RPC" | jq -r '.[0]')
STATE=/tmp/opencode/agent-state-local.json
AUDIT=/tmp/opencode/agent-audit-local.jsonl
rm -f "$STATE" "$AUDIT"

PRICES=(
  200000000000 200200000000 200039840000 200339899760 200239729810 200399921594
  200640401500 197630795477 193678179568 188836225079 185437173027 183211926951
  183944774659 184496608983 185142347114 185512631808 185976413388 186534342628
  186907411313 187187772430 187374960203
)

for ((i=0; i<${#PRICES[@]}; i++)); do
  .venv/bin/python demo/local_loop.py --rpc "$RPC" tick "${PRICES[$i]}" >/dev/null
  .venv/bin/python agent/agent.py --rpc-url "$RPC" --vault "$V" --unlocked --from "$A" \
    --start-block 0 --state "$STATE" --audit "$AUDIT" --once >/dev/null 2>&1 || true
  .venv/bin/python demo/local_loop.py --rpc "$RPC" relay >/dev/null 2>&1 || true
  state=$(.venv/bin/python demo/local_loop.py --rpc "$RPC" status | jq -r '"\(.mode) \(.score)"')
  printf 'tick %2d  %-10s %s\n' "$((i+1))" "$state"
  if [[ $i -eq 5 || $i -eq 9 || $i -eq 20 ]]; then
    if cast call "$V" "deposit()" --value 0.001ether --from "$A" --rpc-url "$RPC" >/dev/null 2>&1; then
      echo "         deposit allowed"
    else
      echo "         deposit blocked (GuardActive)"
    fi
  fi
done

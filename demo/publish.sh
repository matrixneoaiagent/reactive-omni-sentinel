#!/usr/bin/env bash
# Publish the demo price path to PriceFeedOrigin.
#
#   ./demo/publish.sh --calm
#   ./demo/publish.sh --crash
#   ./demo/publish.sh --recover
#   ./demo/publish.sh --story --interval 5
set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="${FOUNDRY_BIN:-$HOME/.foundry/bin}:$PATH"

CONFIG=${CONFIG:-deploy/config.env}
if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$CONFIG"; set +a
fi

: "${RPC_BASE:?RPC_BASE missing}"
: "${CALLBACK_PROXY:=0x476F44b11F5C942c58f4c8E3d0300E5710743585}"

AUTH=()
if [[ -n "${ACCOUNT:-}" ]]; then AUTH=(--account "$ACCOUNT"); else AUTH=(--private-key "${PRIVATE_KEY:?}"); fi

DEPLOY=${DEPLOY:-deployments/latest.json}
FEED=${PRICE_FEED:-$(jq -r .contracts.price_feed "$DEPLOY")}
INTERVAL=${INTERVAL:-5}

MODE=${1:---calm}

# 21 ticks: calm, crash, partial recovery (the same path as the Foundry E2E test)
PRICES=(
  200000000000 200200000000 200039840000 200339899760 200239729810 200399921594
  200640401500 197630795477 193678179568 188836225079 185437173027 183211926951
  183944774659 184496608983 185142347114 185512631808 185976413388 186534342628
  186907411313 187187772430 187374960203
)

case "$MODE" in
  --calm)    RANGE=(0 6) ;;
  --crash)   RANGE=(6 12) ;;
  --recover) RANGE=(12 21) ;;
  --story)   RANGE=(0 21) ;;
  *) echo "usage: $0 [--calm|--crash|--recover|--story] [--interval N]" >&2; exit 2 ;;
esac

# allow --interval N as the second argument
if [[ "${2:-}" == "--interval" ]]; then INTERVAL=${3:?}; fi

echo "feed $FEED  mode $MODE  interval ${INTERVAL}s"
for ((i=${RANGE[0]}; i<${RANGE[1]}; i++)); do
  price=${PRICES[$i]}
  tx=$(cast send --json --rpc-url "$RPC_BASE" "${AUTH[@]}" "$FEED" "publish(uint256)" "$price" | jq -r .transactionHash)
  printf 'tick %2d  price %s  tx %s\n' "$((i+1))" "$price" "$tx"
  if (( i + 1 < RANGE[1] )); then sleep "$INTERVAL"; fi
done

#!/usr/bin/env bash
# Demonstrate the deposit gate.
#   ./demo/deposit.sh --check   # simulate only, shows GuardActive in defensive mode
#   ./demo/deposit.sh --send    # actually deposit 0.001 ETH
set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="${FOUNDRY_BIN:-$HOME/.foundry/bin}:$PATH"

CONFIG=${CONFIG:-deploy/config.env}
if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$CONFIG"; set +a
fi

: "${RPC_ORIGIN:=${RPC_BASE:-}}"
: "${RPC_ORIGIN:?RPC_ORIGIN (or legacy RPC_BASE) missing}"
VAULT=${VAULT_ADDRESS:-$(jq -r .contracts.vault deployments/latest.json)}
USER_ADDR=${USER_ADDR:-${OWNER:?set USER_ADDR or OWNER}}
VALUE=${VALUE:-0.001ether}

AUTH=()
if [[ -n "${ACCOUNT:-}" ]]; then AUTH=(--account "$ACCOUNT"); else AUTH=(--private-key "${PRIVATE_KEY:?}"); fi

case "${1:---check}" in
  --check)
    if out=$(cast call "$VAULT" "deposit()" --value "$VALUE" --from "$USER_ADDR" --rpc-url "$RPC_ORIGIN" 2>&1); then
      echo "deposit allowed (vault is NORMAL)"
    else
      echo "deposit blocked:"
      echo "$out" | sed 's/^/  /'
      exit 1
    fi
    ;;
  --send)
    cast send --json --rpc-url "$RPC_ORIGIN" "${AUTH[@]}" "$VAULT" "deposit()" --value "$VALUE" \
      | jq -r '"deposit tx " + .transactionHash'
    ;;
  *)
    echo "usage: $0 [--check|--send]" >&2
    exit 2
    ;;
esac

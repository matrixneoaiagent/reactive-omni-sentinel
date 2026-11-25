#!/usr/bin/env bash
# Deploy Sentinel: Base Sepolia (origin + vault) and Reactive Lasna.
#
#   cp deploy/config.env.example deploy/config.env
#   $EDITOR deploy/config.env          # add RPCs and auth
#   ./deploy/deploy.sh --dry-run
#   ./deploy/deploy.sh
#
# The script never prints a private key.  Use a dedicated testnet key.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
export PATH="${FOUNDRY_BIN:-$HOME/.foundry/bin}:$PATH"

CONFIG=${CONFIG:-deploy/config.env}
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$CONFIG"; set +a
fi

: "${RPC_BASE:?RPC_BASE missing}"
: "${RPC_LASNA:?RPC_LASNA missing}"
: "${ORIGIN_CHAIN_ID:=84532}"
: "${DEST_CHAIN_ID:=84532}"
: "${CALLBACK_PROXY:=0x476F44b11F5C942c58f4c8E3d0300E5710743585}"
: "${SYSTEM:=0x8888888888888888888888888888888888888888}"
: "${FUND_REACT:=0.2ether}"
: "${FUND_ETH:=0.005ether}"

AUTH=()
if [[ -n "${ACCOUNT:-}" ]]; then
  AUTH=(--account "$ACCOUNT")
elif [[ -n "${PRIVATE_KEY:-}" ]]; then
  AUTH=(--private-key "$PRIVATE_KEY")
else
  echo "set ACCOUNT or PRIVATE_KEY (see deploy/config.env.example)" >&2
  exit 2
fi

if [[ -z "${OWNER:-}" ]]; then
  OWNER=$(cast wallet address "${AUTH[@]}")
fi

say() { printf '\n== %s ==\n' "$*"; }
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

say "preflight"
BASE_ID=$(cast chain-id --rpc-url "$RPC_BASE")
LASNA_ID=$(cast chain-id --rpc-url "$RPC_LASNA")
[[ "$BASE_ID" == "$ORIGIN_CHAIN_ID" ]] || { echo "Base RPC chain $BASE_ID != $ORIGIN_CHAIN_ID" >&2; exit 2; }
[[ "$LASNA_ID" == "5318007" ]] || { echo "Lasna RPC chain $LASNA_ID != 5318007" >&2; exit 2; }
[[ "$(cast code "$CALLBACK_PROXY" --rpc-url "$RPC_BASE")" != "0x" ]] || { echo "no proxy code" >&2; exit 2; }
[[ "$(cast code "$SYSTEM" --rpc-url "$RPC_LASNA")" != "0x" ]] || { echo "no system code" >&2; exit 2; }

BASE_BAL=$(cast balance "$OWNER" --rpc-url "$RPC_BASE")
REACT_BAL=$(cast balance "$OWNER" --rpc-url "$RPC_LASNA")
echo "deployer     $OWNER"
echo "Base Sepolia $BASE_BAL wei"
echo "Lasna        $REACT_BAL wei"
[[ "$BASE_BAL" != "0" ]] || { echo "deployer has no Base Sepolia ETH: use a faucet first" >&2; exit 2; }

say "1/6 origin feed (Base Sepolia)"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] forge create PriceFeedOrigin"
  FEED=0x0000000000000000000000000000000000000001
  FEED_TX=0x0
else
  OUT=$(forge create --json --broadcast --rpc-url "$RPC_BASE" "${AUTH[@]}" \
    src/PriceFeedOrigin.sol:PriceFeedOrigin --constructor-args "$OWNER")
  FEED=$(jq -r .deployedTo <<<"$OUT")
  FEED_TX=$(jq -r .transactionHash <<<"$OUT")
fi
echo "PRICE_FEED $FEED  $FEED_TX"

say "2/6 reactive contract (Lasna)"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] forge create SentinelReactive"
  REACTIVE=0x0000000000000000000000000000000000000002
  REACTIVE_TX=0x0
else
  OUT=$(ORIGIN_CHAIN_ID="$ORIGIN_CHAIN_ID" PRICE_FEED="$FEED" DEST_CHAIN_ID="$DEST_CHAIN_ID" OWNER="$OWNER" \
    forge create --json --broadcast --rpc-url "$RPC_LASNA" "${AUTH[@]}" \
    src/SentinelReactive.sol:SentinelReactive \
    --constructor-args "$ORIGIN_CHAIN_ID" "$FEED" "$DEST_CHAIN_ID" "$OWNER")
  REACTIVE=$(jq -r .deployedTo <<<"$OUT")
  REACTIVE_TX=$(jq -r .transactionHash <<<"$OUT")
fi
echo "REACTIVE   $REACTIVE  $REACTIVE_TX"

say "3/6 vault (Base Sepolia)"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] forge create SentinelVault"
  VAULT=0x0000000000000000000000000000000000000003
  VAULT_TX=0x0
else
  OUT=$(CALLBACK_PROXY="$CALLBACK_PROXY" REACTIVE_ADDRESS="$REACTIVE" \
    forge create --json --broadcast --rpc-url "$RPC_BASE" "${AUTH[@]}" \
    src/SentinelVault.sol:SentinelVault \
    --constructor-args "$CALLBACK_PROXY" "$REACTIVE")
  VAULT=$(jq -r .deployedTo <<<"$OUT")
  VAULT_TX=$(jq -r .transactionHash <<<"$OUT")
fi
echo "VAULT      $VAULT  $VAULT_TX"

say "4/6 bind vault on the reactive contract"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] cast send SentinelReactive.setVault"
  SET_VAULT_TX=0x0
else
  SET_VAULT_TX=$(cast send --json --rpc-url "$RPC_LASNA" "${AUTH[@]}" \
    "$REACTIVE" "setVault(address)" "$VAULT" | jq -r .transactionHash)
fi
echo "setVault   $SET_VAULT_TX"

say "5/6 fund the reactive contract ($FUND_REACT lREACT)"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] cast send system.depositTo(reactive)"
  FUND_REACT_TX=0x0
else
  FUND_REACT_TX=$(cast send --json --rpc-url "$RPC_LASNA" "${AUTH[@]}" \
    "$SYSTEM" "depositTo(address)" "$REACTIVE" --value "$FUND_REACT" | jq -r .transactionHash)
fi
echo "fundReact  $FUND_REACT_TX"

say "6/6 fund the vault ($FUND_ETH Base Sepolia ETH)"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] cast send proxy.depositTo(vault)"
  FUND_ETH_TX=0x0
else
  FUND_ETH_TX=$(cast send --json --rpc-url "$RPC_BASE" "${AUTH[@]}" \
    "$CALLBACK_PROXY" "depositTo(address)" "$VAULT" --value "$FUND_ETH" | jq -r .transactionHash)
fi
echo "fundVault  $FUND_ETH_TX"

say "verify"
if [[ $DRY_RUN -eq 0 ]]; then
  [[ "$(cast call "$REACTIVE" 'vault()(address)' --rpc-url "$RPC_LASNA" | tr 'A-F' 'a-f')" == "$(echo "$VAULT" | tr 'A-F' 'a-f')" ]] \
    || { echo "vault binding mismatch" >&2; exit 3; }
  [[ "$(cast call "$REACTIVE" 'PRICE_FEED()(address)' --rpc-url "$RPC_LASNA" | tr 'A-F' 'a-f')" == "$(echo "$FEED" | tr 'A-F' 'a-f')" ]] \
    || { echo "feed binding mismatch" >&2; exit 3; }
  [[ "$(cast call "$VAULT" 'MODEL_HASH()(bytes32)' --rpc-url "$RPC_BASE")" == "$(cat training/model_hash.txt)" ]] \
    || { echo "model hash mismatch" >&2; exit 3; }
fi

FEED_BLOCK=0
if [[ $DRY_RUN -eq 0 ]]; then
  FEED_BLOCK=$(cast to-dec "$(cast receipt "$FEED_TX" --json --rpc-url "$RPC_BASE" | jq -r .blockNumber)")
fi

TS=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p deployments
OUT_FILE="deployments/${TS}.json"
if [[ $DRY_RUN -eq 0 ]]; then
  jq -n \
    --arg ts "$TS" --arg owner "$OWNER" --argjson block "$FEED_BLOCK" \
    --arg feed "$FEED" --arg reactive "$REACTIVE" --arg vault "$VAULT" \
    --arg feed_tx "$FEED_TX" --arg reactive_tx "$REACTIVE_TX" --arg vault_tx "$VAULT_TX" \
    --arg set_vault_tx "$SET_VAULT_TX" --arg fund_react_tx "$FUND_REACT_TX" --arg fund_eth_tx "$FUND_ETH_TX" \
    --arg model "$(cat training/model_hash.txt)" \
    '{ts:$ts, block:$block, deployer:$owner,
      chain_ids:{origin:84532, reactive:5318007},
      contracts:{price_feed:$feed, reactive:$reactive, vault:$vault},
      txs:{deploy_feed:$feed_tx, deploy_reactive:$reactive_tx, deploy_vault:$vault_tx,
           set_vault:$set_vault_tx, fund_reactive:$fund_react_tx, fund_vault:$fund_eth_tx},
      model_hash:$model}' > "$OUT_FILE"
  cp "$OUT_FILE" deployments/latest.json
  echo "wrote $OUT_FILE"
fi

say "done"
echo "Next: ./demo/publish.sh (calm ticks), then run agent/agent.py, then ./demo/publish.sh --crash"

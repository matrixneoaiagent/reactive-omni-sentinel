#!/usr/bin/env bash
# Deploy Sentinel on an EVM testnet origin/destination + Reactive Lasna.
#
#   ORIGIN_CHAIN=sepolia       (default) Ethereum Sepolia 11155111
#   ORIGIN_CHAIN=base-sepolia  Base Sepolia 84532
#
#   cp deploy/config.env.example deploy/config.env
#   $EDITOR deploy/config.env
#   ./deploy/deploy.sh --dry-run
#   ./deploy/deploy.sh
#
# The script never prints a private key.  Use a dedicated testnet key.
set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="${FOUNDRY_BIN:-$HOME/.foundry/bin}:$PATH"

CONFIG=${CONFIG:-deploy/config.env}
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$CONFIG"; set +a
fi

ORIGIN_CHAIN=${ORIGIN_CHAIN:-sepolia}
case "$ORIGIN_CHAIN" in
  sepolia)
    DEFAULT_CHAIN_ID=11155111
    DEFAULT_RPC=https://ethereum-sepolia-rpc.publicnode.com
    DEFAULT_PROXY=0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4
    DEFAULT_EXPLORER=https://sepolia.etherscan.io
    DEFAULT_FAUCET=0x9b9BB25f1A81078C544C829c5EB7822d747Cf434
    ORIGIN_NAME="Ethereum Sepolia"
    ;;
  base-sepolia)
    DEFAULT_CHAIN_ID=84532
    DEFAULT_RPC=https://sepolia.base.org
    DEFAULT_PROXY=0x476F44b11F5C942c58f4c8E3d0300E5710743585
    DEFAULT_EXPLORER=https://sepolia.basescan.org
    DEFAULT_FAUCET=0x2afaFD298b23b62760711756088F75B7409f5967
    ORIGIN_NAME="Base Sepolia"
    ;;
  *)
    echo "ORIGIN_CHAIN must be sepolia or base-sepolia (got: $ORIGIN_CHAIN)" >&2
    exit 2
    ;;
esac

: "${RPC_ORIGIN:=${RPC_BASE:-$DEFAULT_RPC}}"
: "${ORIGIN_CHAIN_ID:=$DEFAULT_CHAIN_ID}"
: "${DEST_CHAIN_ID:=$ORIGIN_CHAIN_ID}"
: "${CALLBACK_PROXY:=$DEFAULT_PROXY}"
: "${EXPLORER:=$DEFAULT_EXPLORER}"
: "${REACTIVE_FAUCET:=$DEFAULT_FAUCET}"
: "${RPC_LASNA:=https://lasna-rpc.rnk.dev/}"
: "${SYSTEM:=0x8888888888888888888888888888888888888888}"
: "${FUND_REACT:=0.2ether}"
: "${FUND_ETH:=0.005ether}"

if [[ "$ORIGIN_CHAIN_ID" != "$DEFAULT_CHAIN_ID" ]]; then
  echo "ORIGIN_CHAIN_ID=$ORIGIN_CHAIN_ID does not match ORIGIN_CHAIN=$ORIGIN_CHAIN ($DEFAULT_CHAIN_ID)" >&2
  exit 2
fi
if [[ "$DEST_CHAIN_ID" != "$ORIGIN_CHAIN_ID" ]]; then
  echo "DEST_CHAIN_ID must equal ORIGIN_CHAIN_ID for this build" >&2
  exit 2
fi

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

say "preflight — $ORIGIN_NAME ($ORIGIN_CHAIN_ID) + Reactive Lasna (5318007)"
ORIGIN_ID=$(cast chain-id --rpc-url "$RPC_ORIGIN")
LASNA_ID=$(cast chain-id --rpc-url "$RPC_LASNA")
[[ "$ORIGIN_ID" == "$ORIGIN_CHAIN_ID" ]] || { echo "origin RPC chain $ORIGIN_ID != $ORIGIN_CHAIN_ID" >&2; exit 2; }
[[ "$LASNA_ID" == "5318007" ]] || { echo "Lasna RPC chain $LASNA_ID != 5318007" >&2; exit 2; }
[[ "$(cast code "$CALLBACK_PROXY" --rpc-url "$RPC_ORIGIN")" != "0x" ]] || { echo "no callback proxy code at $CALLBACK_PROXY on $ORIGIN_NAME" >&2; exit 2; }
[[ "$(cast code "$SYSTEM" --rpc-url "$RPC_LASNA")" != "0x" ]] || { echo "no system code at $SYSTEM on Lasna" >&2; exit 2; }

ORIGIN_BAL=$(cast balance "$OWNER" --rpc-url "$RPC_ORIGIN")
REACT_BAL=$(cast balance "$OWNER" --rpc-url "$RPC_LASNA")
echo "deployer     $OWNER"
echo "$ORIGIN_NAME $ORIGIN_BAL wei"
echo "Lasna        $REACT_BAL wei"
[[ "$ORIGIN_BAL" != "0" ]] || { echo "deployer has no $ORIGIN_NAME ETH: use a faucet first" >&2; exit 2; }
[[ "$REACT_BAL" != "0" ]] || {
  echo "deployer has no lREACT on Lasna. Send 0.01 $ORIGIN_NAME ETH to the Reactive faucet:" >&2
  echo "  cast send $REACTIVE_FAUCET \"request(address)\" $OWNER --value 0.01ether --rpc-url $RPC_ORIGIN <your-auth-flag>" >&2
  exit 2
}

say "1/6 origin feed ($ORIGIN_NAME)"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] forge create PriceFeedOrigin"
  FEED=0x0000000000000000000000000000000000000001
  FEED_TX=0x0
else
  OUT=$(forge create --json --broadcast --rpc-url "$RPC_ORIGIN" "${AUTH[@]}" \
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
  OUT=$(forge create --json --broadcast --rpc-url "$RPC_LASNA" "${AUTH[@]}" \
    src/SentinelReactive.sol:SentinelReactive \
    --constructor-args "$ORIGIN_CHAIN_ID" "$FEED" "$DEST_CHAIN_ID" "$OWNER")
  REACTIVE=$(jq -r .deployedTo <<<"$OUT")
  REACTIVE_TX=$(jq -r .transactionHash <<<"$OUT")
fi
echo "REACTIVE   $REACTIVE  $REACTIVE_TX"

say "3/6 vault ($ORIGIN_NAME)"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] forge create SentinelVault"
  VAULT=0x0000000000000000000000000000000000000003
  VAULT_TX=0x0
else
  OUT=$(forge create --json --broadcast --rpc-url "$RPC_ORIGIN" "${AUTH[@]}" \
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

say "6/6 fund the vault ($FUND_ETH $ORIGIN_NAME ETH)"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] cast send proxy.depositTo(vault)"
  FUND_ETH_TX=0x0
else
  FUND_ETH_TX=$(cast send --json --rpc-url "$RPC_ORIGIN" "${AUTH[@]}" \
    "$CALLBACK_PROXY" "depositTo(address)" "$VAULT" --value "$FUND_ETH" | jq -r .transactionHash)
fi
echo "fundVault  $FUND_ETH_TX"

say "verify"
if [[ $DRY_RUN -eq 0 ]]; then
  [[ "$(cast call "$REACTIVE" 'vault()(address)' --rpc-url "$RPC_LASNA" | tr 'A-F' 'a-f')" == "$(echo "$VAULT" | tr 'A-F' 'a-f')" ]] \
    || { echo "vault binding mismatch" >&2; exit 3; }
  [[ "$(cast call "$REACTIVE" 'PRICE_FEED()(address)' --rpc-url "$RPC_LASNA" | tr 'A-F' 'a-f')" == "$(echo "$FEED" | tr 'A-F' 'a-f')" ]] \
    || { echo "feed binding mismatch" >&2; exit 3; }
  [[ "$(cast call "$REACTIVE" 'ORIGIN_CHAIN_ID()(uint256)' --rpc-url "$RPC_LASNA" --json | jq -r '.[0]')" == "$ORIGIN_CHAIN_ID" ]] \
    || { echo "origin chain binding mismatch" >&2; exit 3; }
  [[ "$(cast call "$VAULT" 'MODEL_HASH()(bytes32)' --rpc-url "$RPC_ORIGIN")" == "$(cat training/model_hash.txt)" ]] \
    || { echo "model hash mismatch" >&2; exit 3; }
  [[ "$(cast call "$VAULT" '_SERVICE_PROVIDER()(address)' --rpc-url "$RPC_ORIGIN" | tr 'A-F' 'a-f')" == "$(echo "$CALLBACK_PROXY" | tr 'A-F' 'a-f')" ]] \
    || { echo "callback proxy binding mismatch" >&2; exit 3; }
fi

FEED_BLOCK=0
if [[ $DRY_RUN -eq 0 ]]; then
  FEED_BLOCK=$(cast to-dec "$(cast receipt "$FEED_TX" --json --rpc-url "$RPC_ORIGIN" | jq -r .blockNumber)")
fi

TS=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p deployments
OUT_FILE="deployments/${TS}.json"
if [[ $DRY_RUN -eq 0 ]]; then
  jq -n \
    --arg ts "$TS" --arg owner "$OWNER" --argjson block "$FEED_BLOCK" \
    --arg origin_chain "$ORIGIN_CHAIN" --argjson origin_chain_id "$ORIGIN_CHAIN_ID" --arg rpc_origin "$RPC_ORIGIN" --arg rpc_lasna "$RPC_LASNA" \
    --arg explorer "$EXPLORER" --arg proxy "$CALLBACK_PROXY" --arg faucet "$REACTIVE_FAUCET" \
    --arg feed "$FEED" --arg reactive "$REACTIVE" --arg vault "$VAULT" \
    --arg feed_tx "$FEED_TX" --arg reactive_tx "$REACTIVE_TX" --arg vault_tx "$VAULT_TX" \
    --arg set_vault_tx "$SET_VAULT_TX" --arg fund_react_tx "$FUND_REACT_TX" --arg fund_eth_tx "$FUND_ETH_TX" \
    --arg model "$(cat training/model_hash.txt)" \
    '{ts:$ts, block:$block, deployer:$owner,
      origin_chain:$origin_chain, origin_chain_id:$origin_chain_id, rpc_origin:$rpc_origin, rpc_lasna:$rpc_lasna,
      explorer:$explorer, callback_proxy:$proxy, reactive_faucet:$faucet,
      chain_ids:{origin:$origin_chain_id, reactive:5318007},
      contracts:{price_feed:$feed, reactive:$reactive, vault:$vault},
      txs:{deploy_feed:$feed_tx, deploy_reactive:$reactive_tx, deploy_vault:$vault_tx,
           set_vault:$set_vault_tx, fund_reactive:$fund_react_tx, fund_vault:$fund_eth_tx},
      model_hash:$model}' > "$OUT_FILE"
  cp "$OUT_FILE" deployments/latest.json
  echo "wrote $OUT_FILE"
fi

say "done — $ORIGIN_NAME"
echo "Explorer:  $EXPLORER"
echo "Feed:      $EXPLORER/address/$FEED"
echo "Vault:     $EXPLORER/address/$VAULT"
echo "Reactive:  https://lasna.reactscan.net/address/$REACTIVE"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry run only. Fund lREACT with 0.01 $ORIGIN_NAME ETH to $REACTIVE_FAUCET if the Lasna balance is zero."
fi
echo "Next: ./demo/publish.sh --calm, then agent/agent.py, then ./demo/publish.sh --crash"

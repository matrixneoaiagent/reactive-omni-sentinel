# Deploy runbook — Ethereum Sepolia + Reactive Lasna

This runbook is for the orchestrator, who holds the key. The build subagent did not create accounts, connect a wallet, or spend anything.

**Default path: Ethereum Sepolia (11155111) as origin and destination, Reactive Lasna (5318007) as the reactive chain.** Base Sepolia (84532) is supported by setting `ORIGIN_CHAIN=base-sepolia`; see §8.

## 0. What you need

- Foundry (`forge`, `cast`) on `PATH`. On NixOS: `nix shell nixpkgs#foundry -c bash`.
- `jq`.
- A dedicated **testnet** EVM key. Do not reuse a funded mainnet key.
- ~15 minutes.

No mainnet gas, no purchase, no stake. The only asset is free Ethereum Sepolia ETH.

## 1. Fund the deployer with Sepolia ETH

Use the **Sepolia PoW faucet**: <https://sepolia-faucet.pk910.de/>. It pays Ethereum Sepolia ETH after a short browser mining session; no account is required. Mine to the deployer address.

Alternatives: Alchemy Sepolia faucet, Chainstack Sepolia faucet, QuickNode Sepolia faucet, or any public Sepolia faucet. Some require an account. If a standalone human-verification checkbox appears, it may be clicked; if a **CAPTCHA challenge** appears after it, stop — do not solve, bypass, or outsource it.

Confirm:

```bash
cast balance <DEPLOYER> --rpc-url https://ethereum-sepolia-rpc.publicnode.com
cast chain-id --rpc-url https://ethereum-sepolia-rpc.publicnode.com   # 11155111
```

Budget:

| Item | Cost |
|---|---|
| Feed + vault deployments | ~0.0002–0.001 SepETH |
| Vault callback reserve | 0.005 SepETH |
| Agent score txs | ~0.00001 SepETH each |
| Reactive faucet | **0.01 SepETH** → 1 lREACT |
| Total | **~0.02 SepETH** is comfortable; keep the rest for gas |

## 2. Get lREACT (1 lREACT is enough)

Send **0.01 SepETH** to the official Reactive faucet on Ethereum Sepolia. Rate: 1 ETH → 100 lREACT.

```bash
cast send 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 \
  "request(address)" <DEPLOYER> \
  --value 0.01ether \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com \
  --private-key $PRIVATE_KEY
```

This yields **1 lREACT**. Check:

```bash
cast balance <DEPLOYER> --rpc-url https://lasna-rpc.rnk.dev/
```

The deployment needs roughly 0.2 lREACT for the reactive contract reserve plus Lasna gas; 1 lREACT is sufficient for the whole demo. If you prefer more headroom, send 0.05 SepETH for 5 lREACT.

## 3. Configure

```bash
cd /tmp/opencode/reactive-omni
cp deploy/config.env.example deploy/config.env
$EDITOR deploy/config.env
```

Minimum:

```dotenv
ORIGIN_CHAIN=sepolia
RPC_ORIGIN=                      # empty -> https://ethereum-sepolia-rpc.publicnode.com
RPC_LASNA=https://lasna-rpc.rnk.dev/
OWNER=0x...                      # deployer address
PRIVATE_KEY=0x...                # or ACCOUNT=my-keystore
```

`deploy/config.env` is gitignored; never commit it. `deploy.sh` derives `ORIGIN_CHAIN_ID=11155111`, `DEST_CHAIN_ID=11155111`, `CALLBACK_PROXY=0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4`, `EXPLORER=https://sepolia.etherscan.io` and the faucet address from `ORIGIN_CHAIN`.

Dry run:

```bash
./deploy/deploy.sh --dry-run
```

It checks both chain ids, the Lasna system contract, the Sepolia callback proxy, and the deployer's Sepolia + lREACT balances before doing anything.

## 4. Deploy

```bash
./deploy/deploy.sh
```

| Step | Chain | What it does |
|---|---|---|
| 1 | Ethereum Sepolia | `PriceFeedOrigin(owner)` |
| 2 | Lasna | `SentinelReactive(11155111, feed, 11155111, owner)` — subscribes to price ticks |
| 3 | Ethereum Sepolia | `SentinelVault(proxy, reactive)` |
| 4 | Lasna | `reactive.setVault(vault)` — subscribes to score events |
| 5 | Lasna | `SYSTEM.depositTo(reactive)` with 0.2 lREACT |
| 6 | Ethereum Sepolia | `proxy.depositTo(vault)` with 0.005 ETH |

The script verifies `reactive.vault()`, `reactive.PRICE_FEED()`, `reactive.ORIGIN_CHAIN_ID()`, `vault.MODEL_HASH()` and `vault._SERVICE_PROVIDER()` before writing `deployments/<timestamp>.json` and `deployments/latest.json`. Commit the JSON after a successful run.

If a step fails, the script stops; already-deployed contracts are not rolled back. Record the addresses from the failed run and either resume manually or start clean.

## 5. Verify manually

```bash
RPC_ORIGIN=https://ethereum-sepolia-rpc.publicnode.com
RPC_LASNA=https://lasna-rpc.rnk.dev/

cast call <REACTIVE> 'ORIGIN_CHAIN_ID()(uint256)' --rpc-url $RPC_LASNA   # 11155111
cast call <REACTIVE> 'vault()(address)' --rpc-url $RPC_LASNA
cast call <REACTIVE> 'PRICE_FEED()(address)' --rpc-url $RPC_LASNA
cast call <VAULT> 'MODEL_HASH()(bytes32)' --rpc-url $RPC_ORIGIN
cast call <VAULT> '_SERVICE_PROVIDER()(address)' --rpc-url $RPC_ORIGIN  # 0xAa14...
cast call <VAULT> 'mode()(uint8)' --rpc-url $RPC_ORIGIN                 # 0 = NORMAL
cast call <SYSTEM> 'reserves(address)(uint256)' <REACTIVE> --rpc-url $RPC_LASNA
cast call <PROXY> 'reserves(address)(uint256)' <VAULT> --rpc-url $RPC_ORIGIN
```

`MODEL_HASH` must equal `cat training/model_hash.txt`. If it does not, the vault was deployed from different weights; do not proceed.

## 6. Run the loop

```bash
# terminal 1: dashboard
.venv/bin/python demo/monitor.py --env-file deploy/config.env

# terminal 2: agent
.venv/bin/python agent/agent.py --env-file deploy/config.env \
  --start-block $(jq .block deployments/latest.json)

# terminal 3: price path
./demo/publish.sh --calm --interval 6
./demo/publish.sh --crash --interval 4
./demo/publish.sh --recover --interval 4
```

The agent validates that its RPC chain equals `ORIGIN_CHAIN_ID` (11155111) before submitting. It writes `agent/audit.jsonl`; keep it for the evidence table (it contains no secrets).

Ethereum Sepolia produces ~12 s blocks, so the demo runs slower than the Base Sepolia variant. The fallback timer uses `block.timestamp`, so the 180 s deadline is unaffected by block time.

## 7. Evidence

```bash
.venv/bin/python demo/evidence.py --deployments deployments/latest.json
```

It prints the origin, reactive, callback, score, and policy transactions with Etherscan/Reactscan links. Paste the relevant rows into `docs/SUBMISSION_CHECKLIST.md` and the README.

## 8. Base Sepolia alternative

```dotenv
ORIGIN_CHAIN=base-sepolia
RPC_ORIGIN=                      # empty -> https://sepolia.base.org
```

`deploy.sh` then derives chain 84532, callback proxy `0x476F44b11F5C942c58f4c8E3d0300E5710743585`, explorer `https://sepolia.basescan.org`, and Reactive faucet `0x2afaFD298b23b62760711756088F75B7409f5967`. Get Base Sepolia ETH from a Base Sepolia faucet and send 0.01 ETH to that faucet for 1 lREACT. The contract source and tests are identical; `test/SepoliaPath.t.sol` covers the Sepolia variant.

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `chain 11155111 != 84532` or similar | wrong `ORIGIN_CHAIN` / RPC | set `ORIGIN_CHAIN=sepolia` and an Ethereum Sepolia RPC; never mix mainnet and testnet |
| `insufficient funds for gas` on Sepolia | no Sepolia ETH | PoW faucet step 1 |
| `deployer has no lREACT` | faucet not called | step 2; check `cast balance` on Lasna |
| `no callback proxy code` | wrong proxy for the chain | let `deploy.sh` derive it, or set `CALLBACK_PROXY` correctly |
| `InDebt` on a callback | vault reserve exhausted | `cast send <PROXY> "depositTo(address)" <VAULT> --value 0.01ether --rpc-url $RPC_ORIGIN ...` |
| Reactive contract goes quiet | reactive debt | `cast send <SYSTEM> "depositTo(address)" <REACTIVE> --value 0.2ether --rpc-url $RPC_LASNA ...` |
| `NotAuthorized` on `requestRiskAssessment` | caller is not the callback proxy | only the proxy can deliver; do not call it directly |
| `CallbackNotAuthorized` | injected sender is not the vault's `_CALLBACK_SENDER` | the vault was deployed with the wrong reactive address; redeploy the vault |
| `ScoreMismatch` | agent score != on-chain inference | run `forge test --match-path 'test/generated/*'` and `pytest agent/test_agent.py` |
| `BadModelHash` | agent uses a different weights file | point `--model` at the committed `training/weights.json` |
| `AlreadyScored` | two agents answered the same request | harmless; the second submission is rejected |
| No `RiskAssessmentRequested` | fewer than 6 ticks, or no tick since `setVault` | publish at least 6 ticks; wait for Sepolia's ~12 s blocks |
| Agent reports `RPC chain ... != expected` | agent pointed at the wrong RPC | fix `RPC_ORIGIN` or pass `--expected-chain-id 11155111` |
| `CallbackFailure` | destination gas limit too low or vault reverts | check the vault state and `cast receipt` |
| Agent loops on `send_failed` nonce | stuck pending tx | `cast nonce <DEPLOYER> --rpc-url $RPC_ORIGIN`; replace or wait |

## 10. Shutdown / cleanup

There is no admin pause. To stop the demo, stop the agent and the publisher; the contracts remain public and harmless on testnet. Do not send mainnet funds to any address in this repository.

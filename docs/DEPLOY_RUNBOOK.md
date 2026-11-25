# Deploy runbook — Base Sepolia + Reactive Lasna

This runbook is for the orchestrator, who holds the key. The build subagent did not create accounts, connect a wallet, or spend anything.

## 0. What you need

- Foundry (`forge`, `cast`) on `PATH`. On NixOS: `nix shell nixpkgs#foundry -c bash`.
- `jq`.
- A dedicated **testnet** EVM key with Base Sepolia ETH. Do not reuse a funded mainnet key.
- ~15 minutes.

No mainnet gas, no purchase, no stake. The only asset is free Base Sepolia ETH.

## 1. Fund the deployer

The deployer needs Base Sepolia ETH. It pays:

- three contract deployments (~0.001 ETH total),
- the vault's callback reserve (0.005 ETH),
- the agent's score transactions (~0.0002 ETH each).

`0.05 ETH` is comfortable.

Free route (human browser):

1. Open <https://faucet.quicknode.com/base/sepolia>.
2. Paste the deployer address.
3. Complete the standalone human-verification checkbox. If a **CAPTCHA challenge** appears after it, stop: do not solve, bypass, or outsource it. Try another faucet or ask the user.
4. Confirm the balance:

```bash
cast balance <DEPLOYER> --rpc-url https://sepolia.base.org
```

Alternatives: Alchemy Base Sepolia faucet, Coinbase CDP faucet, Chainstack faucet. All are free; some require an account.

## 2. Get lREACT

Send a small amount of Base Sepolia ETH to the official Reactive faucet:

```bash
cast send 0x2afaFD298b23b62760711756088F75B7409f5967 \
  "request(address)" <DEPLOYER> \
  --value 0.05ether \
  --rpc-url https://sepolia.base.org \
  --private-key $PRIVATE_KEY
```

Rate: 1 ETH → 100 lREACT, so 0.05 ETH → 5 lREACT. Check:

```bash
cast balance <DEPLOYER> --rpc-url https://lasna-rpc.rnk.dev/
```

## 3. Configure

```bash
cd /tmp/opencode/reactive-omni
cp deploy/config.env.example deploy/config.env
$EDITOR deploy/config.env
```

Set `OWNER`, `RPC_BASE`, `RPC_LASNA`, and one of `PRIVATE_KEY` / `ACCOUNT`. `deploy/config.env` is gitignored; never commit it.

Dry run first:

```bash
./deploy/deploy.sh --dry-run
```

It checks both chain ids, the system contract, the callback proxy, and the deployer balance before doing anything.

## 4. Deploy

```bash
./deploy/deploy.sh
```

Steps and expected output:

| Step | Chain | What it does |
|---|---|---|
| 1 | Base Sepolia | `PriceFeedOrigin(owner)` |
| 2 | Lasna | `SentinelReactive(84532, feed, 84532, owner)` — subscribes to price ticks |
| 3 | Base Sepolia | `SentinelVault(proxy, reactive)` |
| 4 | Lasna | `reactive.setVault(vault)` — subscribes to score events |
| 5 | Lasna | `SYSTEM.depositTo(reactive)` with 0.2 lREACT |
| 6 | Base Sepolia | `proxy.depositTo(vault)` with 0.005 ETH |

The script verifies `reactive.vault()`, `reactive.PRICE_FEED()`, and `vault.MODEL_HASH()` before writing `deployments/<timestamp>.json` and `deployments/latest.json`. Commit the JSON after a successful run.

If a step fails, the script stops; already-deployed contracts are not rolled back. Re-running deploys new ones, so record the addresses from the failed run and either resume manually or start clean.

## 5. Verify manually

```bash
RPC_BASE=https://sepolia.base.org
RPC_LASNA=https://lasna-rpc.rnk.dev/

cast call <REACTIVE> 'vault()(address)' --rpc-url $RPC_LASNA
cast call <REACTIVE> 'PRICE_FEED()(address)' --rpc-url $RPC_LASNA
cast call <VAULT> 'MODEL_HASH()(bytes32)' --rpc-url $RPC_BASE
cast call <VAULT> 'mode()(uint8)' --rpc-url $RPC_BASE          # 0 = NORMAL
cast call <SYSTEM> 'reserves(address)(uint256)' <REACTIVE> --rpc-url $RPC_LASNA
cast call <PROXY> 'reserves(address)(uint256)' <VAULT> --rpc-url $RPC_BASE
```

`MODEL_HASH` must equal `cat training/model_hash.txt`. If it does not, the vault was deployed from different weights; do not proceed.

## 6. Run the loop

```bash
# terminal 1: dashboard
.venv/bin/python demo/monitor.py --env-file deploy/config.env

# terminal 2: agent
.venv/bin/python agent/agent.py --env-file deploy/config.env --start-block $(jq .block deployments/latest.json)

# terminal 3: price path
./demo/publish.sh --calm --interval 6
./demo/publish.sh --crash --interval 4
./demo/publish.sh --recover --interval 4
```

The agent writes `agent/audit.jsonl`; keep it for the evidence table (it contains no secrets).

If the agent is started after some requests already exist, it scans from `--start-block` and answers the ones still open. Already-scored requests are skipped by `getRequest`.

## 7. Evidence

```bash
.venv/bin/python demo/evidence.py --deployments deployments/latest.json
```

It prints the origin, reactive, callback, score, and policy transactions with explorer links. Paste the relevant rows into `docs/SUBMISSION_CHECKLIST.md` and the README.

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `chain 84532 != 8453` or similar | wrong RPC | fix `RPC_BASE` / `RPC_LASNA`; never mix mainnet and testnet |
| `insufficient funds for gas` | no Base Sepolia ETH | faucet step 1 |
| `InDebt` on a callback | vault reserve exhausted | `cast send <PROXY> "depositTo(address)" <VAULT> --value 0.01ether --rpc-url $RPC_BASE ...` |
| Reactive contract goes quiet | reactive debt | `cast send <SYSTEM> "depositTo(address)" <REACTIVE> --value 0.2ether --rpc-url $RPC_LASNA ...` |
| `NotAuthorized` on `requestRiskAssessment` | caller is not the callback proxy | only the proxy can deliver; do not call it directly |
| `CallbackNotAuthorized` | payload's injected sender is not the vault's `_CALLBACK_SENDER` | the vault was deployed with the wrong reactive address; redeploy the vault |
| `ScoreMismatch` | agent score != on-chain inference | the agent and contract disagree on weights or integer maths; run `forge test --match-path 'test/generated/*'` and `pytest agent/test_agent.py` |
| `BadModelHash` | agent uses a different weights file | point `--model` at the committed `training/weights.json` |
| `AlreadyScored` | two agents answered the same request | harmless; the second submission is rejected |
| No `RiskAssessmentRequested` | fewer than 6 ticks, or no tick since `setVault` | publish at least 6 ticks; wait a few seconds for indexing |
| No `RiskScoreSubmitted` seen by Reactive | score tx landed before the subscription, or wrong vault | check `reactive.vault()`, then wait for the next tick |
| Agent loops on `send_failed` nonce | stuck pending tx | `cast nonce <DEPLOYER> --rpc-url $RPC_BASE`; replace or wait |
| `CallbackFailure` | destination gas limit too low or vault reverts | check the vault state and `cast receipt`; raise limits only by redeploying the reactive contract |

## 9. Shutdown / cleanup

There is no admin pause. To stop the demo, stop the agent and the publisher; the contracts remain public and harmless on testnet. Do not send mainnet funds to any address in this repository.

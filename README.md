# Sentinel — an AI risk officer for on-chain vaults

**Reactive Omni Buildathon · Reactive Meets AI track**

Sentinel puts a small neural network inside a Reactive Network automation loop. Price events on Ethereum Sepolia become features on Reactive Lasna; the network asks an off-chain agent for an assessment; the agent's score is **recomputed and verified on-chain** before the vault changes its risk posture. If the agent is late, the reactive contract applies a conservative fallback instead of waiting forever.

> Thresholds cannot tell noise from a regime change. Sentinel scores the regime, and the contract — not the agent — decides what to do about it.

```
Ethereum Sepolia                Reactive Lasna                 Ethereum Sepolia
────────────────                ──────────────                 ────────────────
PriceTick ──▶ SentinelReactive ──▶ callback #1 ──▶ SentinelVault
(origin)        features              request          emits RiskAssessmentRequested
                                        │
                                        ▼
                                  AI agent (Python, 6-8-1 MLP)
                                        │ submitRiskScore
                                        ▼
                  SentinelReactive ◀── RiskScoreSubmitted
                        │
                        └──▶ callback #2 ──▶ SentinelVault.applyPolicy
                                              NORMAL / DEFENSIVE
```

## Why this needs Reactive Omni

The loop has two callback hops, and the second one only exists because the first produced an event. A keeper bot could do this with a cron job, but then the policy is off-chain and the audit trail is a database. Here every hop is a reactive transaction and a callback: the origin event, the inference request, the score, and the policy change are all on-chain and independently verifiable. Omni's ~1 s blocks and instant finality keep the reactive half of the loop fast; the origin chain's block time still sets the floor (Ethereum Sepolia ~12 s, Base Sepolia 200 ms). The point is auditability and automatic execution, not HFT latency.

## What is in the box

| Contract | Chain | Job |
|---|---|---|
| `PriceFeedOrigin` | Ethereum Sepolia (11155111) | Publishes `PriceTick(tickId, price, timestamp)`. A stand-in for a Chainlink adapter or DEX `Sync` subscription. |
| `SentinelReactive` | Reactive Lasna (5318007) | Subscribes to ticks and score events, keeps an 8-tick ring buffer, computes six integer features, requests inference, then requests the policy callback. Applies a timeout fallback. |
| `SentinelVault` | Ethereum Sepolia (11155111) | Holds user deposits. Accepts new deposits only in `NORMAL` mode. Verifies the agent's score against the committed model, applies hysteresis, and exposes the full request history. |
| `SentinelFeatures` | library | Deterministic integer feature extraction, mirrored in `training/features.py`. |
| `SentinelModel` | library | Integer-only 6-8-1 MLP inference, generated from `training/weights.json`. |

The origin/destination chain is switchable with `ORIGIN_CHAIN` in `deploy/config.env`:

| `ORIGIN_CHAIN` | Chain ID | Callback proxy | Reactive faucet |
|---|---|---|---|
| `sepolia` (default) | 11155111 | `0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4` | `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` |
| `base-sepolia` | 84532 | `0x476F44b11F5C942c58f4c8E3d0300E5710743585` | `0x2afaFD298b23b62760711756088F75B7409f5967` |

Both are Lasna-testnet origins/destinations; the Reactive contract subscribes with the selected chain ID.

## The AI is in the loop, not in the build

The model is a 6-8-1 MLP with ReLU hidden units and a bounded linear output. It predicts the next five-tick return from six features:

| # | Feature | Intuition |
|---|---|---|
| 0 | 1-tick return × 20 | immediate move |
| 1 | 5-tick return × 10 | short trend |
| 2 | mean absolute return × 40 | realised volatility |
| 3 | drawdown from the 8-tick peak × 4 | how far below the high |
| 4 | 3-tick vol / 7-tick vol − 1 | volatility expansion |
| 5 | down-tick share over 5 ticks | trend consistency |

The output is mapped to a **0–10000 risk score**. `≥ 6500` enters `DEFENSIVE`; `≤ 4900` returns to `NORMAL`; the band between is a hysteresis zone that prevents flapping.

**Verification, not trust.** The weights are quantised to 1e6 and exported to Solidity. On submission the vault recomputes the forward pass from the stored features and rejects any score that does not match (`ScoreMismatch`). The agent is trusted for liveness only. A malicious agent can censor, but it cannot lie, and censorship is covered by the reactive timeout fallback.

### Held-out results

Synthetic regime-switching paths, 600 × 300 ticks, 25% of paths held out (43,500 samples). Full details in `training/metrics.json` and `docs/MODEL_CARD.md`.

| Metric (quantised model) | Sentinel | 1%-last-tick rule |
|---|---|---|
| R² | 0.179 | — |
| MAE | 0.143 | — |
| Recall of ≥1.5% five-tick drawdowns at the policy threshold | **35.0%** | 25.7% |
| False alarms on calm samples | 1.19% | 0.60% |

The model buys ~9 points of recall for ~0.6 points of extra false alarms. It is a small, honest edge on a noisy target, not a market-beating claim. The demo path is deterministic and reproduced in the Foundry E2E test.

## Safety properties

- **Agent cannot forge a score.** `SentinelVault.submitRiskScore` recomputes `SentinelModel.score(features)` and compares.
- **Agent cannot silently stop the guard.** If a request is unanswered for `fallbackDelay` (180 s), the next tick makes `SentinelReactive` request `applyFallback`, which puts the vault in `DEFENSIVE` without a score.
- **No stale scores.** The reactive contract tracks one in-flight request and ignores score events for any other request id.
- **No replay.** Tick ids are monotonic; duplicate price logs are ignored.
- **Hysteresis.** A single noisy score cannot flip the vault back and forth.
- **Deposits are never trapped.** `withdraw` works in both modes; only new deposits are blocked while defensive.
- **Callback authentication.** The vault checks both the callback proxy (`onlyServiceProvider`) and the injected reactive address (`onlyCallbackSender`), matching the production proxy behaviour.

## Repository

```
src/
  PriceFeedOrigin.sol        origin event source
  SentinelReactive.sol       Lasna reactive contract
  SentinelVault.sol          origin/destination chain + policy
  lib/SentinelFeatures.sol   integer feature extraction
  lib/SentinelModel.sol      generated integer inference
  lib/ModelWeights.sol       generated quantised weights + hash
test/
  Vault.t.sol                auth, score verification, hysteresis, fallback
  Reactive.t.sol             subscriptions, feature window, replay, timeout
  E2E.t.sol                  calm → crash → recovery, full two-hop loop
  SepoliaPath.t.sol          same suites on Ethereum Sepolia + its proxy
  generated/                 80 model vectors + 76 feature vectors from Python
training/
  generate_data.py           regime-switching synthetic paths
  train.py                   MLP training, quantisation, Solidity export
  features.py                canonical integer features
  weights.json               committed model (hash in ModelWeights.sol)
  metrics.json               held-out results
agent/
  model.py                   integer inference, identical to Solidity
  agent.py                   event watcher, idempotent submitter, audit log
deploy/
  deploy.sh                  Sepolia or Base Sepolia + Lasna deployment, preflight, JSON record
demo/
  publish.sh                 publishes the 21-tick demo path
  monitor.py                 terminal dashboard
docs/
  RULES_VERIFICATION.md      official quotes, network, costs, unknowns
  ARCHITECTURE.md            sequence, auth, failure modes
  MODEL_CARD.md              data, metrics, limitations
  DEMO_SCRIPT.md             2:30 shot list
  SUBMISSION_CHECKLIST.md    form fields and evidence table
  DEPLOY_RUNBOOK.md          faucet → deploy → verify
```

## Reproduce

Requirements: Foundry, Python 3.11+, Node not required.

```bash
# contracts
forge test                      # 36 tests: both chains + cross-language parity
forge test --match-contract E2ETest -vvv

# python environment
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt

# retrain from scratch (optional; weights are committed)
.venv/bin/python training/generate_data.py
.venv/bin/python training/train.py
.venv/bin/python training/export_feature_vectors.py
.venv/bin/python -m pytest agent/test_agent.py -q
```

`docs/test-output.txt` is the captured output of the last full run.

### Local rehearsal (no testnet, no keys)

The full two-hop loop can be rehearsed on Anvil with a mock system contract and a mock callback proxy. This is for validation and video practice only; the addresses and hashes are local and must not be submitted as evidence.

```bash
./demo/local_demo.sh                          # Ethereum Sepolia chain id
ORIGIN_CHAIN=base-sepolia ./demo/local_demo.sh  # Base Sepolia variant
```

The Sepolia and Base variants use their respective chain IDs and callback-proxy addresses; the mock proxy's calldata injection is identical.

Expected: score 0 while the window fills, 4768 at tick 6, `DEFENSIVE` at tick 8 (8118), back to `NORMAL` at tick 18 (4790). `docs/test-output.txt` shows the Foundry version of the same path.

## Deploy and run

Deployment is **testnet only** and costs $0 in real funds; it needs Sepolia ETH from a faucet, which is also the input to the official Reactive faucet (1 ETH → 100 lREACT; **0.01 SepETH → 1 lREACT** is enough, keep the rest for gas). The default is Ethereum Sepolia; `ORIGIN_CHAIN=base-sepolia` switches the whole path. See `docs/DEPLOY_RUNBOOK.md`.

```bash
cp deploy/config.env.example deploy/config.env
# ORIGIN_CHAIN=sepolia, RPC_ORIGIN, OWNER, and one auth method
# never commit this file
./deploy/deploy.sh --dry-run
./deploy/deploy.sh

# calm ticks, then the agent, then the crash
./demo/publish.sh --calm --interval 12
.venv/bin/python agent/agent.py --env-file deploy/config.env
./demo/publish.sh --crash --interval 12
./demo/publish.sh --recover --interval 12
```

## Deployed addresses and transactions

> **Status: pending testnet deployment.** The repository is complete and the full loop is proven in Foundry. The public addresses and transaction hashes are filled here and in `deployments/latest.json` after the deployer runs `deploy/deploy.sh`. No mainnet deployment and no purchase are required.

| Item | Value |
|---|---|
| PriceFeedOrigin (11155111) | _pending_ |
| SentinelReactive (5318007) | _pending_ |
| SentinelVault (11155111) | _pending_ |
| Origin tick tx | _pending_ |
| Reactive inference tx | _pending_ |
| Inference request callback tx | _pending_ |
| Agent score tx | _pending_ |
| Reactive policy tx | _pending_ |
| Policy callback tx (mode change) | _pending_ |
| Model hash | `0x671b59e6a51dddd6ef2900c996807258f1a783a58ceff12ed5fe538af3d403e9` |

The exact evidence table and Etherscan/Reactscan link format are in `docs/SUBMISSION_CHECKLIST.md`.

## Limitations and production path

- The price feed is a demo publisher, not a production oracle. Swapping in a Chainlink adapter changes only the event source.
- The model is trained on synthetic regimes. A production model needs real venue data, walk-forward validation, and a shadow-mode period before it can gate deposits.
- The agent is a single process. Production needs redundant agents, alerting, and a longer fallback window; the on-chain verification makes redundancy safe because every replica produces the same score.
- The score is verified on-chain, so changing the model requires deploying a new vault (or a model registry with timelocked hashes). That is intentional: the model is part of the trust surface.
- Testnet only. No audit. Do not use with real funds.

## Licence

MIT. See `LICENSE`.

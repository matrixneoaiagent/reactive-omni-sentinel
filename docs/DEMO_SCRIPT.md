# Demo video — 2:30 shot list

Target length **2:20–2:40**. The DoraHacks limit is three minutes. Record at 1080p, 30 fps, terminal font ≥18 pt. Two scenes: terminal + pre-opened block explorer tabs.

## Pre-flight (before recording)

```bash
# contracts deployed, addresses in deployments/latest.json
export VAULT=$(jq -r .contracts.vault deployments/latest.json)
export FEED=$(jq -r .contracts.price_feed deployments/latest.json)
# fund a demo user with Base Sepolia ETH, e.g. 0xbEEF...
```

Tabs to have open:

1. Basescan: `https://sepolia.basescan.org/address/$FEED`
2. Reactscan Lasna: `https://lasna.reactscan.net/address/<reactive>`
3. Basescan: `https://sepolia.basescan.org/address/$VAULT`
4. The repository README architecture diagram.

Kill background noise, hide notifications, clear the terminal, set `PS1='$ '`.

## 0:00–0:20 — Hook

**On screen:** README architecture diagram, cursor on the two-hop arrow.

**Voice:** "DeFi guards are dumb thresholds. A 1% drop can be noise — or the first tick of a crash. Sentinel puts a neural network inside a Reactive Network loop, so the guard scores the regime instead of counting the drop. And the contract verifies the AI's answer on-chain, so the agent can't lie."

## 0:20–0:40 — The loop

**On screen:** scroll the diagram; highlight Base Sepolia → Lasna → Base Sepolia.

**Voice:** "A price event on Base Sepolia wakes a reactive contract on Lasna. It turns the last eight ticks into six features and asks for an assessment. The agent answers with a score. The reactive contract sees that answer and sends a second callback that applies the policy. Two cross-chain hops, both on-chain."

Show contract addresses in `deployments/latest.json` for five seconds.

## 0:40–1:05 — Calm market

```bash
./demo/publish.sh --calm --interval 6
```

**On screen:** monitor refreshing, `NORMAL`, score ~4700, deposit accepted.

```bash
./demo/deposit.sh --send
```

**Voice:** "Six calm ticks. The model reads low volatility, no drawdown, no trend consistency, and returns 47 out of 100. The vault stays normal and accepts a deposit."

Point at the green `NORMAL` badge and the deposit event.

## 1:05–1:30 — Crash

```bash
./demo/publish.sh --crash --interval 4
```

**On screen:** prices fall, score jumps to ~8100, badge turns red, `GuardTriggered`.

**Voice:** "Now the same feed prints five down ticks. Volatility expands, drawdown deepens, every tick is down. The model returns 81. The reactive contract sends the second callback, and the vault flips to defensive."

```bash
./demo/deposit.sh --check
```

**On screen:** `GuardActive()` revert.

**Voice:** "New deposits are blocked. Withdrawals still work. The guard is up."

## 1:30–2:00 — Proof on-chain

Switch to Basescan.

1. Open the origin `PriceTick` transaction. Show the timestamp.
2. Switch to Reactscan Lasna. Open the reactive transaction that called `requestCallbackV_1_0`. Show the emitted `CallbackRequest` and its destination chain 84532.
3. Back to Basescan: the callback transaction to the vault, `requestRiskAssessment`.
4. Open the agent's `submitRiskScore` transaction; show the score and the model hash.
5. Open the final `applyPolicy` callback; show `ModeChanged(0 → 1)`.

**Voice:** "Every step is a public transaction: the origin tick, the reactive transaction, the inference request callback, the agent's score, the policy callback. The vault recomputed the model from the committed weights and accepted the score — a wrong score reverts."

Keep this section tight; five tabs, ~6 seconds each.

## 2:00–2:20 — Recovery and the fail-safe

```bash
./demo/publish.sh --recover --interval 4
```

**On screen:** score falls below 4900, badge returns to green, deposit accepted again.

**Voice:** "As volatility collapses, the score falls through the 49 recovery threshold — hysteresis stops it flapping — and the vault reopens."

Cut to the fallback test in the test suite:

```bash
forge test --match-test test_fallbackWhenAgentIsSilent -vv
```

**Voice:** "If the agent goes silent, the reactive contract waits 180 seconds, then applies a defensive fallback without a score. The AI can fail; the guard doesn't."

## 2:20–2:35 — Close

**On screen:** README top, repo URL, model metrics table.

**Voice:** "Sentinel is open source, runs on Base Sepolia and Reactive Lasna, and the full loop is covered by 19 tests including cross-language parity between Python and Solidity. Repo and transactions are in the submission. Thanks."

## Contingencies

| Problem | Fix |
|---|---|
| Testnet RPC slow | Publish one tick every 8 s; cut the waiting in editing, keep the timestamps visible |
| Agent misses a request | The fallback fires after 180 s; for the demo, restart the agent before the crash sequence and show the fallback separately in the tests |
| Basescan tabs fail | Use `cast tx` / `cast receipt` in the terminal; the hashes are the evidence |
| Video runs long | Cut the calm deposit shot to 5 s; the crash and the five proofs are the core |
| Score does not cross 6500 | Check that the crash ticks were delivered in order and that the agent answered the request for tick 8; `demo/monitor.py` shows the request ids |

## Post-recording checks

- [ ] Video < 3:00 (hard limit)
- [ ] All five tx hashes visible and matching `docs/SUBMISSION_CHECKLIST.md`
- [ ] No private keys, `.env` contents, or browser autofill visible
- [ ] Audio intelligible; no copyrighted music
- [ ] Upload unlisted/public to YouTube or Loom; paste the URL into the form

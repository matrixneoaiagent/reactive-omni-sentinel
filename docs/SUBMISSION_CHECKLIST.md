# Submission checklist

Deadline: **2026-12-05 20:00 UTC**. Submit at <https://dorahacks.io/hackathon/reactive-omni-buildathon>.

## 1. Form fields

| Field | Value |
|---|---|
| Build name | **Sentinel — AI risk officer for on-chain vaults** |
| Track | **Reactive Meets AI** (one track only) |
| Short description | A neural network scores market stress inside a Reactive Omni loop; the vault recomputes the inference on-chain and blocks new deposits when the score crosses 6500. |
| GitHub | public repo URL, `main` branch, commit `________` |
| Demo video | URL, duration `__:__` (< 3:00) |
| Contract addresses | feed `________`, reactive `________`, vault `________` |
| Transaction hashes | see table below |
| Team | solo |
| Country | Moldova (no restriction published) |

## 2. Evidence table

Fill after `deploy/deploy.sh` and the demo run. All links are public.

| # | Step | Chain | Tx hash | Explorer |
|---|---|---|---|---|
| 1 | Deploy feed | Base Sepolia | `____` | `https://sepolia.basescan.org/tx/____` |
| 2 | Deploy reactive | Lasna | `____` | `https://lasna.reactscan.net/tx/____` |
| 3 | Deploy vault | Base Sepolia | `____` | `https://sepolia.basescan.org/tx/____` |
| 4 | `setVault` | Lasna | `____` | `https://lasna.reactscan.net/tx/____` |
| 5 | Origin `PriceTick` (calm) | Base Sepolia | `____` | `https://sepolia.basescan.org/tx/____` |
| 6 | Reactive tx → inference callback | Lasna | `____` | `https://lasna.reactscan.net/tx/____` |
| 7 | `requestRiskAssessment` callback | Base Sepolia | `____` | `https://sepolia.basescan.org/tx/____` |
| 8 | Agent `submitRiskScore` | Base Sepolia | `____` | `https://sepolia.basescan.org/tx/____` |
| 9 | Reactive tx → policy callback | Lasna | `____` | `https://lasna.reactscan.net/tx/____` |
| 10 | `applyPolicy` → DEFENSIVE | Base Sepolia | `____` | `https://sepolia.basescan.org/tx/____` |
| 11 | Recovery → NORMAL | Base Sepolia | `____` | `https://sepolia.basescan.org/tx/____` |

The minimum the form asks for is "a few transaction hashes showing the full loop, from origin event to callback". Rows **5–10** are the irreducible set; rows 1–4 prove deployment.

`demo/evidence.py` prints this table from `deployments/latest.json` and the chain logs.

## 3. Repository checklist

- [ ] Public and open source (MIT `LICENSE` present)
- [ ] `README.md` has architecture, addresses, tx hashes, test output, limitations
- [ ] `deployments/latest.json` committed with the real addresses and deploy txs
- [ ] No `.env`, private keys, seed phrases, API keys, or `deploy/config.env`
- [ ] No `out/`, `cache/`, `.venv/`, `__pycache__/`, `agent/state.json`, `agent/audit.jsonl`
- [ ] `forge test` is green on a clean clone
- [ ] `agent/test_agent.py` is green
- [ ] README quickstart works from a clean clone
- [ ] Commit is tagged or the commit hash is recorded

## 4. Judging evidence map

| Criterion | Where the judge sees it |
|---|---|
| **Execution** | Rows 5–10 show the origin event, the reactive tx, the first callback, the agent tx, the second reactive tx, and the policy callback. `forge test` shows the same loop deterministically. |
| **Integration** | The reactive contract computes the features, decides when to ask for inference, routes the score, and owns the policy callback. The AI is not a bolt-on: `SentinelModel` is part of the vault's verification path. |
| **Usefulness** | A vault guard that distinguishes a noisy dip from a regime change; deposits are blocked only while the model sees stress, and withdrawals always work. Fallback covers agent downtime. |
| **Craft** | 19 tests, cross-language parity vectors, generated weights with a committed hash, a deploy script with preflight and verification, a runbook, a model card with honest metrics, and a reproducible demo. |

## 5. Video checklist

- [ ] < 3:00 (hard limit; target 2:30)
- [ ] Shows the origins event → reactive tx → callback → agent → policy callback
- [ ] Shows a deposit being accepted in NORMAL and rejected in DEFENSIVE
- [ ] Shows the recovery to NORMAL
- [ ] No keys, `.env`, or personal data on screen
- [ ] Public or unlisted URL that works in incognito

## 6. Final pre-submit checks

- [ ] `curl -s <repo-url>` returns 200 in a logged-out browser
- [ ] The commit on GitHub is the one that was tested
- [ ] Addresses on the form match `deployments/latest.json`
- [ ] The model hash on the vault equals `training/model_hash.txt`
- [ ] Every tx hash opens on the right explorer and has status success
- [ ] The video URL opens in incognito
- [ ] Track is Reactive Meets AI, not a second track
- [ ] Deadline buffer: submit by **2026-12-04 20:00 UTC**, 24 h early
- [ ] If DoraHacks shows a CAPTCHA after the consent checkbox, stop and hand off to the human; never solve or outsource it

## 7. If deployment is blocked

The entry fails the Execution gate without on-chain evidence. Do not submit a repo-only build as a Reactive Meets AI entry. Options, in order:

1. Claim Base Sepolia ETH from a free faucet and deploy (preferred; $0).
2. Ask the organizer in the DoraHacks Q&A whether a Lasna-only or local trace is acceptable (unlikely; the page requires deployed addresses and tx hashes).
3. Withdraw rather than submit an entry that cannot be scored.

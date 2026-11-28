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

Fill after `./deploy/deploy.sh` (default `ORIGIN_CHAIN=sepolia`) and the demo run. All links are public. Base Sepolia is supported by `ORIGIN_CHAIN=base-sepolia`; the explorer column then becomes `sepolia.basescan.org`.

| # | Step | Chain | Tx hash | Explorer |
|---|---|---|---|---|
| 1 | Deploy feed | Ethereum Sepolia | `0xd434ac324f232d802e6a6a6397fb6f9a8daaa04d61e2cdb03cd46e08747e006a` | `https://sepolia.etherscan.io/tx/0xd434ac324f232d802e6a6a6397fb6f9a8daaa04d61e2cdb03cd46e08747e006a` |
| 2 | Deploy reactive | Lasna | `0x2ea64a741859fc5b02c8261e74e7ba0250bf5ec630a0e4705004a5071deba515` | `https://lasna.reactscan.net/tx/0x2ea64a741859fc5b02c8261e74e7ba0250bf5ec630a0e4705004a5071deba515` |
| 3 | Deploy vault | Ethereum Sepolia | `0x033b15ad21401497b0740f22117aef3bd967f5fd6cbaee3659bfd9c39cb7509e` | `https://sepolia.etherscan.io/tx/0x033b15ad21401497b0740f22117aef3bd967f5fd6cbaee3659bfd9c39cb7509e` |
| 4 | `setVault` | Lasna | `0xf1b76728bc7ed68b1559a0ba24ca1b15d67698bde15e90860332014f6b09d58d` | `https://lasna.reactscan.net/tx/0xf1b76728bc7ed68b1559a0ba24ca1b15d67698bde15e90860332014f6b09d58d` |
| 5 | Origin `PriceTick` (calm, #18) | Ethereum Sepolia | `0x2fd77f90cdbc34a4f33e5870174035c8f1e9bbc02baa9a8ad2a155b5b6cc09c2` | `https://sepolia.etherscan.io/tx/0x2fd77f90cdbc34a4f33e5870174035c8f1e9bbc02baa9a8ad2a155b5b6cc09c2` |
| 6 | Reactive tx → inference callback | Lasna | `0xe624133209086b347597744f4d2801ab2050df3895200aa7965fb6c5168f6db4` | `https://lasna.reactscan.net/tx/0xe624133209086b347597744f4d2801ab2050df3895200aa7965fb6c5168f6db4` |
| 7 | `requestRiskAssessment` callback | Ethereum Sepolia | `0x49354ae47f4438e67ddfeab7dfa62eeb949dd1383b1f7d68f52e953ab1fe64de` | `https://sepolia.etherscan.io/tx/0x49354ae47f4438e67ddfeab7dfa62eeb949dd1383b1f7d68f52e953ab1fe64de` |
| 8 | Agent `submitRiskScore` (4768) | Ethereum Sepolia | `0x9d5bf2ce295fa66e99a9941a60e231ec8f7456daefe60c39ae63c562c36ca9f7` | `https://sepolia.etherscan.io/tx/0x9d5bf2ce295fa66e99a9941a60e231ec8f7456daefe60c39ae63c562c36ca9f7` |
| 9 | Reactive tx → policy callback | Lasna | `0xcf59d8c8bc5f0d81014faf0c1ba3773c7bc03ccfabf120af6105a76ac40618a4` | `https://lasna.reactscan.net/tx/0xcf59d8c8bc5f0d81014faf0c1ba3773c7bc03ccfabf120af6105a76ac40618a4` |
| 10 | `applyPolicy` → NORMAL (4768) | Ethereum Sepolia | `0xf1c343118e25bfb9eec10c81258dfdad5e996204e25dac1c7a2c1062a01d0b9f` | `https://sepolia.etherscan.io/tx/0xf1c343118e25bfb9eec10c81258dfdad5e996204e25dac1c7a2c1062a01d0b9f` |
| 11 | Recovery → NORMAL | — | n/a live (calm loop already NORMAL) | covered by `test/E2E.t.sol` + local Sepolia rehearsal |

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
| **Craft** | 38 tests (both chains), cross-language parity vectors, generated weights with a committed hash, a deploy script with preflight and verification, a runbook, a model card with honest metrics, and a reproducible demo. |

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

1. Claim Ethereum Sepolia ETH from the free PoW faucet (<https://sepolia-faucet.pk910.de/>) and deploy with `ORIGIN_CHAIN=sepolia` (preferred; $0).
2. Ask the organizer in the DoraHacks Q&A whether a Lasna-only or local trace is acceptable (unlikely; the page requires deployed addresses and tx hashes).
3. Withdraw rather than submit an entry that cannot be scored.

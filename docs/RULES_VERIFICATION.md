# Rules, network and cost verification

Checked **2026-11-25 ~08:30–09:10 UTC** against the live DoraHacks page and the official Reactive docs. No account was created, no wallet was connected, nothing was submitted.

## 1. Event

| Item | Verified value | Source |
|---|---|---|
| Event | Reactive Omni Buildathon | <https://dorahacks.io/hackathon/reactive-omni-buildathon/detail> |
| Organizer | Reactive Network (DoraHacks org 2445) | same |
| Window | 2026-11-05 12:00 → **2026-12-05 20:00 UTC** | detail page timeline |
| Prize pool | **$5,500, paid in REACT** | detail page |
| Field at check | **157 builds**, 383 hackers | detail page tabs |
| Entry fee | none stated; **$0** | detail page |
| KYC | **no KYC clause published** | detail page + tracks page |
| Format | virtual | detail page |

Exact text:

> "From **November 5th** to **December 5th**, we're running a month-long buildathon to put **Reactive Omni** through its paces, with **$5,500 in prizes, paid in REACT**, across three tracks."

## 2. Tracks and prizes

> "**Every Second Counts:** $2,000 for the first place, $250 for the runner-up"
>
> "**Set It and Forget It:** $2,000 for the first place, $250 for the runner-up"
>
> "**Reactive Meets AI:** $1,000 for the first place"

Five paid places. One build is entered under one track on the submission form; the rules do **not** say whether multiple entries are allowed, so this submission uses **one entry, Reactive Meets AI**, and does not double-enter.

### Reactive Meets AI — exact brief

> "This track is deliberately open. Bring a neural network into the loop and show us how it works alongside Reactive. How the two fit together is up to you."
>
> "**One rule:** the AI has to be part of the running system, not just the tool you used to build it. Projects where AI only wrote the code belong in Set It and Forget It."
>
> "**Network:** Reactive mainnet/Lasna testnet"

Sentinel satisfies this literally: a 6-8-1 MLP scores every inference request at runtime, and the vault recomputes the MLP on-chain before acting.

## 3. Judging

> "Every entry is scored from 1 to 5 on four equally weighted criteria:
> **Execution:** Does it run? We want to see the reactive transactions and the callbacks they trigger on-chain. Entries without them aren't scored further.
> **Integration:** Does the reactive contract do real work, or is it bolted on? Each track's brief says what this means there.
> **Usefulness:** Does it solve a problem real users have?
> **Craft:** Readable code, a working demo, and documentation someone else could follow."

Consequence: a repository plus a local Foundry test is **not enough**. The entry needs public testnet addresses and transaction hashes for the full loop. This is why deployment is the gating step in the go/no-go.

## 4. Submission requirements

> "Submit your build on this page with:
> - A link to your public repository
> - Deployed contract addresses
> - A few transaction hashes showing the full loop, from origin event to callback
> - A demo video under three minutes"

DoraHacks also flags "GitHub/Gitlab/Bitbucket Link Required" and "Demo Video Required".

## 5. Ground rules

> "Repositories need to be **public** and **open-source** by the time you submit."
>
> "Everything should be built during the event. Prior work can come in as a dependency, but not as the submission itself."
>
> "Base Sepolia now produces blocks every 200ms, so use timestamps rather than block counts for any timers, cooldowns, or deadlines there."

Sentinel was written for this event; its only dependencies are `reactive-lib-omni`, `forge-std`, `web3.py` and `numpy`. It uses timestamps for the fallback timer, not block counts. The default deployment is Ethereum Sepolia (~12 s blocks); the Base Sepolia variant also satisfies the timestamp rule.

## 6. Required network and faucet

The page allows "Reactive mainnet/Lasna testnet". This build uses the **testnet pair**, with Ethereum Sepolia as the default and Base Sepolia as a supported alternative:

| Role | Network | Chain ID | Contract |
|---|---|---|---|
| Origin + destination (default) | Ethereum Sepolia | 11155111 | callback proxy `0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4` |
| Origin + destination (alternative) | Base Sepolia | 84532 | callback proxy `0x476F44b11F5C942c58f4c8E3d0300E5710743585` |
| Reactive | Reactive Lasna | 5318007 | system `0x8888888888888888888888888888888888888888` |

`ORIGIN_CHAIN=sepolia|base-sepolia` selects the pair; the reactive contract receives the matching chain ID and callback proxy at deployment.

Official docs:

> "Reactive Mainnet and Lasna Testnet share the same system contract address: `0x8888888888888888888888888888888888888888`"
>
> "Origin is the chain where events originate... Mainnets and testnets must not be mixed: if the origin is a testnet, the destination must also be a testnet."

### Faucet

> "To obtain testnet lREACT, send Sepolia ETH to one of the faucet contracts:
> **Ethereum Sepolia:** `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`
> **Base Sepolia:** `0x2afaFD298b23b62760711756088F75B7409f5967`
> Exchange rate: **1 ETH → 100 lREACT**."
>
> "Don't send more than 5 ETH per transaction."

So the only asset needed is **Ethereum Sepolia ETH** (or Base Sepolia ETH for the alternative), which is free from public faucets. It pays both the origin-chain deployment/callbacks and, sent to the Reactive faucet, produces lREACT. **0.01 SepETH → 1 lREACT** is enough; keep the rest for gas.

## 7. Cost

| Item | Cost |
|---|---|
| Entry fee | **$0** |
| Ethereum Sepolia ETH (deploy + callbacks + agent gas) | **$0** — PoW/public faucet |
| lREACT (reactive gas) | **$0** — 1:100 from Sepolia ETH |
| Mainnet deployment | **not required** |
| Purchase / stake / deposit | **none** |

No mainnet gas and no purchase is required. This is a testnet-only entry.

### Current funding gap (read-only balance check, 2026-11-25)

| Address | Base Sepolia | Ethereum Sepolia | Lasna |
|---|---|---|---|
| `0xa15c58e7008Fc7A0331cFcc86A28Af99FD21b93c` | 0 | 0 | 0 |
| `0x50CcB646b7965dd5bC5Aa93EE3a9f09645e40A8E` | 0 | 0 | 0 |
| `0x0340a9b74b9172B17498ffd167d2A4fC7949F7a2` | 0 | 0 | 0 |

Base mainnet holds 0.000159 ETH, which **cannot** be used for testnet (different chain). A faucet claim is required before deployment. The workspace policy is that the orchestrator, not this subagent, holds and uses the key.

Suggested free route (Sepolia PoW faucet, no account):

1. Open <https://sepolia-faucet.pk910.de/>, enter the deployer address, and let the browser mine Sepolia ETH for a few minutes. No account is required. If a standalone human-verification checkbox appears, it may be clicked; a CAPTCHA challenge must not be solved or outsourced.
2. Send `0.01 SepETH` to the Reactive faucet `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` with calldata `request(address)` and the deployer address. That yields `1 lREACT`.
3. Run `./deploy/deploy.sh` (default `ORIGIN_CHAIN=sepolia`).

The deployment needs roughly `0.001 SepETH` for gas plus `0.005 SepETH` to fund the vault's callback reserve; `0.01–0.02 SepETH` is comfortable. On Lasna, `0.2 lREACT` covers the reactive contract; `1 lREACT` is enough for the whole demo.

## 8. What could not be verified

- **Track enforcement on the form.** The rules do not say whether one build may enter multiple tracks. This entry selects one.
- **KYC at payout.** None is published, but DoraHacks or Reactive may screen winners before paying REACT. Registration was not attempted, so this is unknown.
- **Judging and results dates.** Not published on the detail page.
- **Whether Lasna deployments are prize-eligible.** The track explicitly lists "Reactive mainnet/Lasna testnet", which is the best available evidence; the prize currency is mainnet REACT regardless.
- **Exact build count.** The page reports 157 builds but the build list is hidden ("The organizer is reviewing Builds"), so quality and overlap cannot be assessed.
- **Faucet availability.** The Sepolia PoW faucet was not exercised by this subagent (browser mining). Public faucets change requirements; the orchestrator should confirm the claim before deploying.
- **DoraHacks WAF.** The public pages loaded normally on 2026-11-25; the KB records WAF challenges on submission/edit endpoints in November. The submit step may require a human browser session.

## 9. Live protocol checks performed

- Lasna RPC `eth_chainId` → `5318007`.
- Ethereum Sepolia RPC `eth_chainId` → `11155111`.
- Base Sepolia RPC `eth_chainId` → `84532`.
- System contract code present at `0x8888…8888` on Lasna; callback proxy code present at `0xAa14…23b4` on Ethereum Sepolia and `0x476F…3585` on Base Sepolia.
- Decoded a live `CallbackRequest` on Lasna (`tx 0x5eba70cf…adb5`) and the matching `deliverCallback` transaction on Ethereum Sepolia (`0x56a544f0…9cfe`). The destination payload preserved the 4-byte selector and carried the reactive contract address in its first argument, confirming the authentication scheme used by `SentinelVault`. See `docs/ARCHITECTURE.md`.

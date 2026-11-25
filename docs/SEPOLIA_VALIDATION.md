# Sepolia path validation

Date: 2026-11-25. Commit at validation: `5ba101f` (local only; not pushed).
No keys were used, no funds were spent, and nothing was deployed to a public network.

## 1. Foundry: both chain variants

`forge test` runs the same suites twice: Base Sepolia (84532) and Ethereum Sepolia (11155111), plus the chain-agnostic parity tests.

```
36 tests passed, 0 failed
  ReactiveTest            9  Base Sepolia
  VaultTest               6  Base Sepolia
  E2ETest                 2  Base Sepolia
  SepoliaReactiveTest     9  Ethereum Sepolia
  SepoliaVaultTest        6  Ethereum Sepolia
  SepoliaE2ETest          2  Ethereum Sepolia
  ModelParityTest         1  80 vectors
  FeatureParityTest       1  76 vectors
```

The Sepolia suites assert:

- `MockSystem` received the price subscription with `chainId == 11155111`, `contract == feed`, `topic0 == PriceTick`;
- the score subscription uses `chainId == 11155111`, `contract == vault`;
- the callback configuration's destination `chainId == 11155111`;
- the vault's `_SERVICE_PROVIDER` is the official Ethereum Sepolia proxy `0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4`;
- the injected first argument is the reactive contract, so `onlyCallbackSender` accepts it;
- the full calm → crash → recovery path reaches `DEFENSIVE` at tick 8 (8118) and `NORMAL` at tick 18 (4790).

`docs/test-output.txt` is the captured run.

## 2. Local Anvil rehearsal, chain 11155111

Command:

```bash
ORIGIN_CHAIN=sepolia PORT=8558 ./demo/local_demo.sh
```

The script starts Anvil with `--chain-id 11155111`, etches the mock system at `0x8888…8888` and the mock proxy at the **Ethereum Sepolia** address `0xAa14…23b4`, deploys the production contracts, and runs the 21-tick story with the real agent and relay.

Result:

```
tick  6  NORMAL     4768   deposit allowed
tick  7  NORMAL     4759
tick  8  DEFENSIVE  8118
tick  9  DEFENSIVE  8278
tick 10  DEFENSIVE  8560   deposit blocked (GuardActive)
tick 13  DEFENSIVE  6202   neutral band
tick 18  NORMAL     4790   deposit allowed
tick 21  NORMAL     4677
```

The local deployment record contained `"chain_id": 11155111`, `"callback_proxy": "0xAa14…23b4"`, `"origin_chain": "sepolia"`.

## 3. Deploy script dry run

```bash
CONFIG=/tmp/opencode/sepolia-dry.env ./deploy/deploy.sh --dry-run
```

Output:

```
== preflight — Ethereum Sepolia (11155111) + Reactive Lasna (5318007) ==
deployer     0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
Ethereum Sepolia 9999983657727760534563 wei
Lasna        9999999230578999230579 wei
...
== done — Ethereum Sepolia ==
Explorer:  https://sepolia.etherscan.io
```

This exercised the Sepolia branch, the chain-id check, the callback-proxy code check, and the Lasna system-code check without sending a transaction.

## 4. Deploy script full run against local Anvils

Two throwaway Anvils were used: origin chain 11155111 and Lasna chain 5318007, with the mock system/proxy etched at the production addresses. The production `deploy/deploy.sh` ran without `--dry-run`, deploying, binding, funding, and verifying the contracts.

| Item | Local throwaway value |
|---|---|
| PriceFeedOrigin | `0x71C95911E9a5D330f4D621842EC243EE1343292e` |
| SentinelReactive | `0x71C95911E9a5D330f4D621842EC243EE1343292e` (same nonce on the other chain) |
| SentinelVault | `0x948B3c65b89DF0B4894ABE91E6D02FE579834F8F` |
| deploy feed tx | `0xa4502538a9608a03b9e1e2a3a42b9fc8c7f7fd941415b1397474a814a12a4292` |
| deploy reactive tx | `0x31175d88b290c78436187dad6ef5643b5db28ab1d724e3089f37e59ce502ed56` |
| deploy vault tx | `0xb3e5cf54e72d920c8e18e94744f3183edf8699994849b9c85bf9f8c607bcee8c` |
| setVault tx | `0xabc380abcd9e00c1047a1d5a81ff10a79c37db3fa5fceecdd3bcc301f8b2eaea` |
| fund reactive tx | `0xcb003157a7c7d4d8dd4986ada0b036e81c3a0c28bc0ab5127a8dd07b0a984f18` |
| fund vault tx | `0x0bd428e44aaaccf975f0991841ee075f5b32d69c5d6ae4aa836d8662950d0596` |

These are **local Anvil hashes**, not public explorer transactions, and must not be submitted as hackathon evidence. The run proves the deploy script's order, constructor arguments, `setVault`, funding calls, binding checks and JSON record.

The generated JSON contained:

```json
{
  "origin_chain": "sepolia",
  "origin_chain_id": 11155111,
  "rpc_origin": "http://127.0.0.1:8556",
  "rpc_lasna": "http://127.0.0.1:8557",
  "callback_proxy": "0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4",
  "reactive_faucet": "0x9b9BB25f1A81078C544C829c5EB7822d747Cf434",
  "chain_ids": { "origin": 11155111, "reactive": 5318007 },
  "model_hash": "0x671b59e6a51dddd6ef2900c996807258f1a783a58ceff12ed5fe538af3d403e9"
}
```

The JSON was removed after the test; only `deployments/.gitkeep` is committed.

## 5. Not yet verified (requires a funded deploy)

- Real Lasna `SYSTEM.requestCallbackV_1_0` delivery from a real Sepolia transaction.
- Real Ethereum Sepolia callback proxy operator injection (the calldata shape was verified against a live Sepolia callback, and the local mock reproduces it).
- Faucet claim (PoW mining) and actual Sepolia gas costs.
- End-to-end latency with Sepolia's ~12 s blocks.

These are the remaining risks before the funded deploy. The contract code, deploy script, chain IDs, proxy binding, subscription filters and auth path are covered by the tests above.

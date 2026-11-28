# Deployment records

`latest.json` is the first Sentinel deployment (2026-11-25 09:05Z): feed
`0x6F6f31D95c791aA3f7e61277E7e46Ff2BA3891D1`, reactive
`0x098EED1eB26C11106A4f8329Db87f9bc988397AA`, vault
`0x58f839b80b37B11260a3018ae26cf3f1586A5CCf`. It is kept as history.

The judged live loop uses the **second** deployment recorded in the README:

| Contract | Address |
|---|---|
| PriceFeedOrigin (11155111) | `0x6F6f31D95c791aA3f7e61277E7e46Ff2BA3891D1` |
| SentinelReactive (5318007) | `0x790e35eF3F2aCA3Bec0418fBe14973CDC80F89D9` |
| SentinelVault (11155111) | `0xe006b89478eeAd20B34B8B7e8a2ef980Dd4760e6` |

Verified read-only: `SentinelVault._CALLBACK_SENDER()` returns
`0x790e35eF3F2aCA3Bec0418fBe14973CDC80F89D9`, `SentinelReactive.vault()`
returns `0xe006b89478eeAd20B34B8B7e8a2ef980Dd4760e6`, and
`SentinelVault.lastRequestId()` returns 19.

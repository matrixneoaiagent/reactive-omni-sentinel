# Model card — Sentinel risk model v1

## What it is

A 6-input, 8-hidden-unit, 1-output multilayer perceptron with ReLU hidden units and a bounded linear output. It predicts the **next five-tick return** of a price series, scaled by 20 and clamped to `[-1, 1]`. The policy maps that prediction to a `0..10000` risk score:

```
score = (output + 1) * 5000
```

So `output = 0` is a score of 5000 ("no directional edge"), `output = +0.3` is 6500 (the defensive threshold), and `output = -0.02` is 4900 (the recovery threshold).

The model is **not** a price predictor in the trading sense. It is a regime-stress detector: it answers "given the last eight ticks, is the next five ticks likely to be a drawdown?"

## Inputs

All features are integers with 6 decimals, computed on-chain from eight prices with 8 decimals:

| # | Feature | Scale | Range |
|---|---|---|---|
| 0 | 1-tick return × 20 | 1e6 | -1 … +1 |
| 1 | 5-tick return × 10 | 1e6 | -1 … +1 |
| 2 | mean absolute return over 5 ticks × 40 | 1e6 | 0 … +1 |
| 3 | drawdown from the 8-tick peak × 4 | 1e6 | -1 … 0 |
| 4 | 3-tick vol / 7-tick vol − 1 | 1e6 | -1 … +1 |
| 5 | down-tick share over 5 ticks | 1e6 | -1 … +1 |

The exact integer operations are in `training/features.py` and `src/lib/SentinelFeatures.sol`. They are covered by 76 generated parity vectors.

## Training data

Synthetic regime-switching paths:

- three regimes: calm (`μ=0`, `σ=0.30%`), trend (`μ=±0.15%`, `σ=0.20%`), crash (`μ=-1.20%`, `σ=0.80%`, 8% chance of an extra -3% jump);
- Markov transitions with crash persistence 0.80, calm persistence 0.985;
- 600 paths × 300 ticks, prices start at 2000e8;
- 25% of **paths** held out, never individual samples, to avoid leakage;
- 130,500 training samples, 43,500 test samples;
- label: forward 5-tick return `r`, mapped to `clamp(-20r, -1, 1)`.

The generator is deliberately simple and auditable. It is not a market simulator and the results should not be read as evidence of real-market performance.

## Training

- float forward/backward pass implemented in NumPy (no framework dependency);
- Adam, learning rate 0.003, batch 512, 200 epochs;
- sample weight 3 for `|label| > 0.2` to stop the calm majority from dominating;
- weights quantised to 1e6 and exported to `src/lib/ModelWeights.sol`;
- the quantised model, not the float model, is what is evaluated and deployed.

## Held-out results

Test set: 43,500 samples, 6.1% labelled as a ≥1.5% five-tick drawdown.

| Metric | Value |
|---|---|
| R² (quantised) | 0.179 |
| MAE | 0.143 |
| Event recall at score ≥ 6500 | 35.0% |
| False-alarm rate on calm samples (label ≤ 0.05) | 1.19% |

Baseline: "last tick fell at least 1%" (`feature[0] <= -200000`).

| Threshold | Recall | False alarms | Precision |
|---|---|---|---|
| 6000 | 38.2% | 1.90% | 66.6% |
| 6250 | 36.4% | 1.45% | 71.5% |
| **6500 (policy)** | **35.0%** | **1.19%** | **74.6%** |
| 7000 | 32.8% | 0.90% | 78.5% |
| 7250 | 31.6% | 0.83% | 79.2% |

At the deployed threshold the model catches about nine percentage points more drawdowns than the 1% rule, at the cost of about 0.6 points more false alarms on calm data. The edge narrows as the false-alarm budget shrinks and is largely gone below ~0.5%; the value of the MLP is the higher-recall operating point, plus the ability to combine volatility expansion and trend consistency into one score. That is a modest, honest edge on a noisy target, not a claim of market-beating alpha.

## What the score means operationally

- `score ≥ 6500`: predicted forward drawdown ≥ ~1.5%; vault enters `DEFENSIVE` and refuses new deposits.
- `4900 < score < 6500`: no change. This band absorbs noise and prevents flapping.
- `score ≤ 4900`: predicted forward return is non-negative enough to return to `NORMAL`.

The thresholds are policy choices, not model outputs. They are constants in `SentinelVault` and can only be changed by deploying a new vault.

## Limitations

1. **Synthetic data.** The model has never seen a real order book, funding rate, liquidation cascade, or news shock. It is a pipeline demonstration, not a production risk model.
2. **No calibration.** The output is a regression score, not a probability. A score of 8000 does not mean "80% chance of a crash".
3. **Regime assumption.** The generator assumes crashes persist and calm mean-reverts. Real markets have different and non-stationary dynamics.
4. **Small capacity.** Eight hidden units and six features cannot represent order-book imbalance, cross-asset contagion, or macro events.
5. **Adversarial inputs.** A manipulated price feed can drive the features. The model does not detect oracle manipulation.
6. **No online learning.** The weights are fixed at deployment. Drift requires a new model and a new vault.
7. **On-chain verification cost.** Recomputing the MLP costs gas on every score. At 6×8 weights this is cheap; a larger model would need a different verification scheme.

## Reproduce

```bash
.venv/bin/python training/generate_data.py     # seed 7
.venv/bin/python training/train.py             # seed 11
.venv/bin/python training/export_feature_vectors.py
.venv/bin/python -m pytest agent/test_agent.py -q
forge test --match-path 'test/generated/*'
```

The committed `training/weights.json` is the artifact that produced `src/lib/ModelWeights.sol`; its keccak256 is `0x671b59e6a51dddd6ef2900c996807258f1a783a58ceff12ed5fe538af3d403e9` and is hard-coded in the vault.

## Intended use

Research and demonstration on a public testnet. **Not** investment advice, not audited, not for real funds.

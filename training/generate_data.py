"""Generate synthetic regime-switching price paths for Sentinel.

The generator is deliberately simple and auditable: three regimes (calm,
trend, crash) with a Markov transition matrix, Gaussian returns and rare
jumps.  It is not a market model; it is a test bench that contains the one
structure the policy must react to -- volatility clusters followed by
drawdowns -- plus long calm stretches that punish trigger-happy rules.
"""

from __future__ import annotations

import argparse
import json

import numpy as np

from features import SCALE, clamp, features_from_prices, trunc_div

# regime: 0 calm, 1 trend, 2 crash
TRANSITION = np.array(
    [
        [0.985, 0.010, 0.005],
        [0.030, 0.960, 0.010],
        [0.120, 0.080, 0.800],
    ]
)
MU = np.array([0.0000, 0.0015, -0.0120])
SIGMA = np.array([0.0030, 0.0020, 0.0080])


def simulate_path(rng: np.random.Generator, n_ticks: int, start_price: int) -> np.ndarray:
    prices = np.empty(n_ticks, dtype=np.int64)
    price = float(start_price)
    regime = 0
    trend_sign = 1.0

    for t in range(n_ticks):
        if regime != 1 and rng.random() < 0.02:
            trend_sign = 1.0 if rng.random() < 0.5 else -1.0
        mu = MU[regime] * (trend_sign if regime == 1 else 1.0)
        r = mu + SIGMA[regime] * rng.standard_normal()

        # fat left tail: crashes jump, calm rarely gaps down
        u = rng.random()
        if regime == 2 and u < 0.08:
            r -= 0.030
        elif regime == 0 and u < 0.001:
            r -= 0.020

        price = max(1.0, price * float(np.exp(r)))
        prices[t] = int(round(price))

        regime = int(rng.choice(3, p=TRANSITION[regime]))

    return prices


def build_dataset(paths: list[np.ndarray]):
    xs, ys = [], []
    for prices in paths:
        p = prices.tolist()
        for i in range(5, len(p) - 5):
            window = p[max(0, i - 7) : i + 1]
            feats = features_from_prices(window)
            fwd = trunc_div((p[i + 5] - p[i]) * SCALE, p[i])
            label = clamp(-(fwd * 20) / SCALE, -1.0, 1.0)
            xs.append(feats)
            ys.append(label)
    return np.asarray(xs, dtype=np.float64), np.asarray(ys, dtype=np.float64)


def story_path() -> list[int]:
    """Hand-built path used in the demo: calm, crash, partial recovery."""
    moves = [
        0.0010, -0.0008, 0.0015, -0.0005, 0.0008, 0.0012,
        -0.0150, -0.0200, -0.0250, -0.0180, -0.0120,
        0.0040, 0.0030, 0.0035, 0.0020, 0.0025, 0.0030, 0.0020, 0.0015, 0.0010,
    ]
    price = 2000.0
    out = [int(round(price * 1e8))]
    for m in moves:
        price *= 1.0 + m
        out.append(int(round(price * 1e8)))
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--paths", type=int, default=600)
    ap.add_argument("--ticks", type=int, default=300)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--out", default="training/data.npz")
    args = ap.parse_args()

    rng = np.random.default_rng(args.seed)
    paths = [
        simulate_path(rng, args.ticks, 2000 * 10**8)
        for _ in range(args.paths)
    ]

    n_test = args.paths // 4
    train_x, train_y = build_dataset(paths[:-n_test])
    test_x, test_y = build_dataset(paths[-n_test:])

    story = story_path()
    story_feats = [
        features_from_prices(story[max(0, i - 7) : i + 1])
        for i in range(5, len(story))
    ]

    np.savez_compressed(
        args.out,
        train_x=train_x,
        train_y=train_y,
        test_x=test_x,
        test_y=test_y,
        story=np.asarray(story, dtype=np.int64),
        story_feats=np.asarray(story_feats, dtype=np.int64),
    )

    print(f"train {train_x.shape} test {test_x.shape}")
    print(f"label mean {train_y.mean():.3f}  positive(>0.3) {(train_y > 0.3).mean():.3%}")
    print(f"story ticks {len(story)} features {len(story_feats)}")
    print(json.dumps({"paths": args.paths, "ticks": args.ticks, "seed": args.seed}))


if __name__ == "__main__":
    main()

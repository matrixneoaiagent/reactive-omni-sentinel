"""Integer feature extraction shared by training and the on-chain mirror.

Every value is a signed integer with 6 decimals (SCALE = 1e6).  The Solidity
implementation in src/SentinelReactive.sol performs exactly the same operations
in the same order, including truncation toward zero, so a vector produced here
must match the chain bit-for-bit.

Prices use 8 decimals, matching Chainlink-style feeds (2000 USD = 2000e8).
"""

SCALE = 1_000_000


def trunc_div(a: int, b: int) -> int:
    """Solidity-style signed division (truncates toward zero)."""
    if b == 0:
        raise ZeroDivisionError
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def clamp(x: int, lo: int, hi: int) -> int:
    return lo if x < lo else hi if x > hi else x


def features_from_prices(prices) -> list[int]:
    """Return six features in 1e6 fixed point.

    ``prices`` is ordered oldest -> newest and must contain at least 6 entries.

    [0] 1-tick momentum      [1] 5-tick momentum
    [2] 5-tick volatility    [3] drawdown from the 8-tick peak
    [4] short/long vol ratio [5] down-tick share
    """
    p = list(prices)
    if len(p) < 6:
        raise ValueError("need at least 6 prices")

    p0, p1, p5 = p[-1], p[-2], p[-6]

    ret1 = trunc_div((p0 - p1) * SCALE, p1)
    ret5 = trunc_div((p0 - p5) * SCALE, p5)

    rets = []
    for k in range(1, len(p)):
        a, b = p[-k], p[-k - 1]
        rets.append(trunc_div((a - b) * SCALE, b))

    abs_rets = [abs(r) for r in rets]
    vol5 = sum(abs_rets[:5]) // min(5, len(abs_rets))

    peak = max(p[-8:])
    drawdown = trunc_div((p0 - peak) * SCALE, peak)

    vol3 = sum(abs_rets[:3]) // min(3, len(abs_rets))
    long_n = min(7, len(abs_rets))
    vol_long = sum(abs_rets[:long_n]) // long_n
    vol_ratio = 0 if vol_long == 0 else trunc_div(vol3 * SCALE, vol_long) - SCALE

    downs = sum(1 for r in rets[:5] if r < 0)
    down_share = trunc_div((downs * 2 - 5) * SCALE, 5)

    return [
        clamp(ret1 * 20, -SCALE, SCALE),      # 1% move -> 0.20
        clamp(ret5 * 10, -SCALE, SCALE),      # 5% move -> 0.50
        clamp(vol5 * 40, 0, SCALE),           # 2.5% average abs move -> 1.0
        clamp(drawdown * 4, -SCALE, 0),       # 25% drawdown -> -1.0
        clamp(vol_ratio, -SCALE, SCALE),      # short vol 2x long vol -> +1.0
        clamp(down_share, -SCALE, SCALE),     # five down ticks -> +1.0
    ]

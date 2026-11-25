// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title Sentinel feature extraction
/// @notice Turns an 8-tick ring buffer of prices into six bounded, 1e6-scaled
///         features.  This is the on-chain half of the model input contract:
///         training/features.py and agent/model.py implement the same integer
///         operations in the same order, and test/generated proves parity.
library SentinelFeatures {
    int256 internal constant SCALE = 1_000_000;

    /// @param ring   Circular buffer of prices (8 decimals).
    /// @param next   Index where the next price will be written.
    /// @param count  Number of valid entries, 1..8.
    function compute(uint256[8] memory ring, uint256 next, uint256 count)
        internal
        pure
        returns (int256[6] memory f)
    {
        require(count >= 6, "SentinelFeatures: need 6 prices");
        uint256 n = count < 8 ? count : 8;

        uint256 p0 = _at(ring, next, 0);
        uint256 p1 = _at(ring, next, 1);
        uint256 p5 = _at(ring, next, 5);

        int256 ret1 = (int256(p0) - int256(p1)) * SCALE / int256(p1);
        int256 ret5 = (int256(p0) - int256(p5)) * SCALE / int256(p5);

        int256 absSum;
        for (uint256 k = 1; k <= 5; k++) {
            int256 r = _ret(ring, next, k);
            absSum += r < 0 ? -r : r;
        }
        int256 vol5 = absSum / 5;

        uint256 peak;
        for (uint256 i = 0; i < n; i++) {
            uint256 v = _at(ring, next, i);
            if (v > peak) peak = v;
        }
        int256 drawdown = (int256(p0) - int256(peak)) * SCALE / int256(peak);

        // short volatility relative to the longest window we hold
        uint256 len = n - 1; // number of returns available, 5..7
        uint256 d3 = len < 3 ? len : 3;

        int256 abs3;
        for (uint256 k = 1; k <= d3; k++) {
            int256 r = _ret(ring, next, k);
            abs3 += r < 0 ? -r : r;
        }
        int256 vol3 = abs3 / int256(d3);

        int256 absLong;
        for (uint256 k = 1; k <= len; k++) {
            int256 r = _ret(ring, next, k);
            absLong += r < 0 ? -r : r;
        }
        int256 volLong = absLong / int256(len);
        int256 volRatio = volLong == 0 ? int256(0) : (vol3 * SCALE / volLong) - SCALE;

        int256 downs;
        for (uint256 k = 1; k <= 5; k++) {
            if (_ret(ring, next, k) < 0) downs++;
        }
        int256 downShare = (downs * 2 - 5) * SCALE / 5;

        f[0] = _clamp(ret1 * 20, -SCALE, SCALE); // 1% move  -> 0.20
        f[1] = _clamp(ret5 * 10, -SCALE, SCALE); // 5% move  -> 0.50
        f[2] = _clamp(vol5 * 40, 0, SCALE); // 2.5% mean abs -> 1.0
        f[3] = _clamp(drawdown * 4, -SCALE, 0); // 25% drawdown -> -1.0
        f[4] = _clamp(volRatio, -SCALE, SCALE); // short vol 2x long -> +1.0
        f[5] = _clamp(downShare, -SCALE, SCALE); // five down ticks -> +1.0
    }

    function _at(uint256[8] memory ring, uint256 next, uint256 k) private pure returns (uint256) {
        return ring[(next + 8 - 1 - k) % 8];
    }

    function _ret(uint256[8] memory ring, uint256 next, uint256 k) private pure returns (int256) {
        uint256 a = _at(ring, next, k - 1);
        uint256 b = _at(ring, next, k);
        return (int256(a) - int256(b)) * SCALE / int256(b);
    }

    function _clamp(int256 x, int256 lo, int256 hi) private pure returns (int256) {
        if (x < lo) return lo;
        if (x > hi) return hi;
        return x;
    }
}

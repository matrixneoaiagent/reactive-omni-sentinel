"""Integer-only inference for the Sentinel agent.

This mirrors src/lib/SentinelModel.sol exactly.  The weights file is the same
one that generated the Solidity constants; the model hash is keccak256 of its
canonical JSON, which the vault checks on every submission.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

SCALE = 1_000_000


def trunc_div(a: int, b: int) -> int:
    if b == 0:
        raise ZeroDivisionError
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def clamp(x: int, lo: int, hi: int) -> int:
    return lo if x < lo else hi if x > hi else x


@dataclass(frozen=True)
class SentinelModel:
    w1: tuple[tuple[int, ...], ...]
    b1: tuple[int, ...]
    w2: tuple[int, ...]
    b2: int
    scale: int = SCALE
    model_hash: str = ""

    @classmethod
    def load(cls, path: str | Path) -> "SentinelModel":
        raw = json.loads(Path(path).read_text())
        if raw.get("version") != "sentinel-mlp-v1":
            raise ValueError(f"unsupported model version: {raw.get('version')}")
        if raw["scale"] != SCALE:
            raise ValueError("unexpected scale")
        canonical = json.dumps(raw, sort_keys=True, separators=(",", ":")).encode()
        from eth_utils import keccak

        return cls(
            w1=tuple(tuple(int(v) for v in row) for row in raw["w1"]),
            b1=tuple(int(v) for v in raw["b1"]),
            w2=tuple(int(v) for v in raw["w2"]),
            b2=int(raw["b2"]),
            scale=int(raw["scale"]),
            model_hash="0x" + keccak(canonical).hex(),
        )

    @property
    def inputs(self) -> int:
        return len(self.w1)

    @property
    def hidden(self) -> int:
        return len(self.b1)

    def forward(self, features: Iterable[int]) -> int:
        f = list(features)
        if len(f) != self.inputs:
            raise ValueError(f"expected {self.inputs} features, got {len(f)}")
        h = []
        for j in range(self.hidden):
            acc = self.b1[j]
            for i in range(self.inputs):
                acc += trunc_div(f[i] * self.w1[i][j], self.scale)
            h.append(max(0, acc))
        out = self.b2
        for j in range(self.hidden):
            out += trunc_div(h[j] * self.w2[j], self.scale)
        return clamp(out, -self.scale, self.scale)

    def score_bps(self, features: Iterable[int]) -> int:
        out = self.forward(features)
        return clamp((out + self.scale) * 10_000 // (2 * self.scale), 0, 10_000)

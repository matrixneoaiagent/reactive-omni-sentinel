"""Cross-language parity: the Python agent must reproduce every Solidity vector."""

from __future__ import annotations

import re
from pathlib import Path

from model import SentinelModel

ROOT = Path(__file__).resolve().parent.parent
VECTORS = ROOT / "test/generated/ModelParity.t.sol"


def parse_vectors():
    text = VECTORS.read_text()
    feats = {}
    expected = {}
    for line in text.splitlines():
        m = re.match(r"\s*f\[(\d)\] = (-?\d+);", line)
        if m:
            feats.setdefault(len(expected), {})[int(m.group(1))] = int(m.group(2))
            continue
        m = re.match(r"\s*assertEq\(uint256\(SentinelModel\.score\(f\)\), (\d+),", line)
        if m:
            expected[len(expected)] = int(m.group(1))
    return [feats[i] for i in range(len(expected))], [expected[i] for i in range(len(expected))]


def test_agent_matches_every_solidity_vector():
    model = SentinelModel.load(ROOT / "training/weights.json")
    vectors, expected = parse_vectors()
    assert len(vectors) >= 80
    for i, (fv, want) in enumerate(zip(vectors, expected)):
        got = model.score_bps([fv[j] for j in range(6)])
        assert got == want, f"vector {i}: python {got} != solidity {want}"


def test_model_hash_is_stable():
    model = SentinelModel.load(ROOT / "training/weights.json")
    assert model.model_hash == (ROOT / "training/model_hash.txt").read_text().strip()


def test_threshold_vectors():
    model = SentinelModel.load(ROOT / "training/weights.json")
    calm = [16000, 19990, 36800, 0, 14130, -200000]
    crash = [-300000, -120420, 152000, -60000, 907101, -200000]
    assert model.score_bps(calm) < 4900
    assert model.score_bps(crash) > 6500

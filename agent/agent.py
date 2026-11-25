#!/usr/bin/env python3
"""Sentinel inference agent.

Watches SentinelVault for RiskAssessmentRequested events, runs the committed
neural network, and submits the score.  The vault recomputes the inference, so
a buggy or malicious agent cannot change the outcome -- it can only fail to
answer, which triggers the on-chain fallback.

Usage:
    python agent/agent.py --once --dry-run
    python agent/agent.py --score 16000,19990,36800,0,14130,-200000
    AGENT_PRIVATE_KEY=... VAULT_ADDRESS=0x... python agent/agent.py
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

from web3 import Web3

sys.path.insert(0, str(Path(__file__).resolve().parent))
from model import SentinelModel  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MODEL = ROOT / "training/weights.json"

ABI = [
    {
        "anonymous": False,
        "inputs": [
            {"indexed": True, "name": "requestId", "type": "uint256"},
            {"indexed": True, "name": "tickId", "type": "uint256"},
            {"indexed": False, "name": "features", "type": "int256[6]"},
            {"indexed": False, "name": "requestedAt", "type": "uint64"},
        ],
        "name": "RiskAssessmentRequested",
        "type": "event",
    },
    {
        "inputs": [
            {"name": "requestId", "type": "uint256"},
            {"name": "scoreBps", "type": "uint16"},
            {"name": "modelHash", "type": "bytes32"},
        ],
        "name": "submitRiskScore",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "inputs": [{"name": "requestId", "type": "uint256"}],
        "name": "getRequest",
        "outputs": [
            {"name": "tickId", "type": "uint256"},
            {"name": "features", "type": "int256[6]"},
            {"name": "requestedAt", "type": "uint64"},
            {"name": "scored", "type": "bool"},
            {"name": "applied", "type": "bool"},
        ],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "riskScoreBps",
        "outputs": [{"name": "", "type": "uint16"}],
        "stateMutability": "view",
        "type": "function",
    },
]


def load_env_file(path: str | None) -> None:
    if not path:
        return
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip())


@dataclass
class State:
    last_block: int = 0
    handled: list[int] = field(default_factory=list)

    @classmethod
    def load(cls, path: Path, start_block: int) -> "State":
        if path.exists():
            raw = json.loads(path.read_text())
            return cls(last_block=int(raw.get("last_block", start_block)), handled=list(raw.get("handled", [])))
        return cls(last_block=start_block, handled=[])

    def save(self, path: Path) -> None:
        path.write_text(
            json.dumps({"last_block": self.last_block, "handled": self.handled[-1000:]}, indent=2)
            + "\n"
        )


class Agent:
    def __init__(self, args, model: SentinelModel):
        self.args = args
        self.model = model
        self.w3 = Web3(Web3.HTTPProvider(args.rpc_url, request_kwargs={"timeout": 30}))
        if not self.w3.is_connected():
            raise SystemExit(f"cannot reach RPC {args.rpc_url}")
        if args.expected_chain_id and self.w3.eth.chain_id != int(args.expected_chain_id):
            raise SystemExit(
                f"RPC chain {self.w3.eth.chain_id} != expected {args.expected_chain_id}; "
                "check RPC_ORIGIN and ORIGIN_CHAIN_ID"
            )
        self.vault = self.w3.eth.contract(address=Web3.to_checksum_address(args.vault), abi=ABI)
        self.state = State.load(Path(args.state), args.start_block)
        if args.start_block == 0 and not Path(args.state).exists():
            # avoid scanning an entire testnet from genesis on first run
            self.state.last_block = max(0, self.w3.eth.block_number - 50_000)
            print(json.dumps({"event": "start_block_auto", "block": self.state.last_block}), flush=True)
        self.account = None
        if not args.dry_run:
            if args.unlocked:
                accounts = self.w3.eth.accounts
                if not accounts:
                    raise SystemExit("--unlocked requires the node to expose an account")
                addr = args.from_address or accounts[0]
                self.account = type("A", (), {"address": Web3.to_checksum_address(addr)})()
            else:
                key = os.environ.get("AGENT_PRIVATE_KEY")
                if not key:
                    raise SystemExit("AGENT_PRIVATE_KEY is required unless --dry-run or --unlocked is used")
                self.account = self.w3.eth.account.from_key(key)
        self.running = True

    # ------------------------------------------------------------------ #
    def stop(self, *_):
        self.running = False

    def log(self, **kw) -> None:
        kw["ts"] = int(time.time())
        line = json.dumps(kw, sort_keys=True)
        print(line, flush=True)
        if not self.args.dry_run:
            with open(self.args.audit, "a") as fh:
                fh.write(line + "\n")

    # ------------------------------------------------------------------ #
    def fetch(self, from_block: int, to_block: int):
        # Public RPCs are load-balanced and their heads can move backwards
        # between the run-loop read and this call; never ask for a block past
        # the head this connection currently sees.
        head = self.w3.eth.block_number
        if from_block > head:
            return []
        to_block = min(to_block, head)
        topic0 = self.vault.events.RiskAssessmentRequested().topic
        return self.w3.eth.get_logs(
            {
                "address": self.vault.address,
                "fromBlock": from_block,
                "toBlock": to_block,
                "topics": [topic0],
            }
        )

    def process(self, log) -> None:
        ev = self.vault.events.RiskAssessmentRequested().process_log(log)
        request_id = int(ev["args"]["requestId"])
        if request_id in self.state.handled:
            return

        request = self.vault.functions.getRequest(request_id).call()
        _, features, _, scored, applied = request
        if scored or applied:
            self.state.handled.append(request_id)
            return

        features = [int(v) for v in features]
        score = self.model.score_bps(features)
        self.log(
            event="assessment",
            request_id=request_id,
            tick_id=int(ev["args"]["tickId"]),
            features=features,
            score_bps=score,
            model_hash=self.model.model_hash,
            dry_run=self.args.dry_run,
        )
        if self.args.dry_run:
            return

        if not self.send_score(request_id, score):
            return
        self.state.handled.append(request_id)

    def send_score(self, request_id: int, score: int) -> bool:
        fn = self.vault.functions.submitRiskScore(
            request_id, score, bytes.fromhex(self.model.model_hash[2:])
        )
        try:
            fn.call({"from": self.account.address})
        except Exception as exc:  # already scored, wrong hash, or a real bug
            self.log(event="simulation_failed", request_id=request_id, error=str(exc)[:300])
            return False

        try:
            gas = int(fn.estimate_gas({"from": self.account.address}) * 1.3) + 20_000
            base = self.w3.eth.get_block("latest").get("baseFeePerGas", self.w3.eth.gas_price)
            priority = self.w3.to_wei(0.01, "gwei")
            nonce = self.w3.eth.get_transaction_count(self.account.address, "pending")
            tx = fn.build_transaction(
                {
                    "from": self.account.address,
                    "nonce": nonce,
                    "chainId": self.w3.eth.chain_id,
                    "gas": gas,
                    "maxFeePerGas": int(base * 2 + priority),
                    "maxPriorityFeePerGas": priority,
                }
            )
            if self.args.unlocked:
                tx_hash = self.w3.eth.send_transaction(tx)
            else:
                signed = self.w3.eth.account.sign_transaction(tx, os.environ["AGENT_PRIVATE_KEY"])
                raw = getattr(signed, "raw_transaction", None) or getattr(signed, "rawTransaction")
                tx_hash = self.w3.eth.send_raw_transaction(raw)
            receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
            if receipt.status != 1:
                self.log(event="reverted", request_id=request_id, tx=tx_hash.hex())
                return False
            self.log(
                event="submitted",
                request_id=request_id,
                score_bps=score,
                tx=tx_hash.hex(),
                block=receipt.blockNumber,
                gas_used=receipt.gasUsed,
            )
            return True
        except Exception as exc:
            self.log(event="send_failed", request_id=request_id, error=str(exc)[:300])
            return False

    # ------------------------------------------------------------------ #
    def run(self) -> None:
        signal.signal(signal.SIGINT, self.stop)
        signal.signal(signal.SIGTERM, self.stop)
        self.log(
            event="start",
            chain_id=self.w3.eth.chain_id,
            vault=self.vault.address,
            agent=self.account.address if self.account else None,
            model_hash=self.model.model_hash,
            start_block=self.state.last_block,
        )

        while self.running:
            latest = self.w3.eth.block_number
            if latest >= self.state.last_block:
                start = self.state.last_block
                while start <= latest:
                    end = min(start + self.args.chunk - 1, latest)
                    for log in self.fetch(start, end):
                        self.process(log)
                    self.state.last_block = end + 1
                    if not self.args.dry_run:
                        self.state.save(Path(self.args.state))
                    start = end + 1
            if self.args.once:
                break
            time.sleep(self.args.poll)

        if not self.args.dry_run:
            self.state.save(Path(self.args.state))
        self.log(event="stop", last_block=self.state.last_block, handled=len(self.state.handled))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rpc-url", default=None)
    ap.add_argument("--expected-chain-id", default=None)
    ap.add_argument("--vault", default=os.environ.get("VAULT_ADDRESS"))
    ap.add_argument("--model", default=str(DEFAULT_MODEL))
    ap.add_argument("--state", default=str(ROOT / "agent/state.json"))
    ap.add_argument("--audit", default=str(ROOT / "agent/audit.jsonl"))
    ap.add_argument("--start-block", type=int, default=int(os.environ.get("START_BLOCK", "0")))
    ap.add_argument("--poll", type=float, default=3.0)
    ap.add_argument("--chunk", type=int, default=2000)
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--unlocked", action="store_true", help="let the node sign (local Anvil only)")
    ap.add_argument("--from-address", help="account to use with --unlocked")
    ap.add_argument("--env-file")
    ap.add_argument("--score", help="score a comma-separated feature vector and exit")
    args = ap.parse_args()

    load_env_file(args.env_file)
    args.rpc_url = (
        args.rpc_url
        or os.environ.get("RPC_ORIGIN")
        or os.environ.get("RPC_URL")
        or "https://ethereum-sepolia-rpc.publicnode.com"
    )
    args.expected_chain_id = args.expected_chain_id or os.environ.get("ORIGIN_CHAIN_ID") or None
    if not args.expected_chain_id:
        args.expected_chain_id = {
            "sepolia": 11155111,
            "base-sepolia": 84532,
        }.get(os.environ.get("ORIGIN_CHAIN", ""), None)
    if args.expected_chain_id:
        args.expected_chain_id = int(args.expected_chain_id)
    model = SentinelModel.load(args.model)

    if args.score:
        features = [int(v) for v in args.score.split(",")]
        print(
            json.dumps(
                {
                    "features": features,
                    "logit": model.forward(features) / model.scale,
                    "score_bps": model.score_bps(features),
                    "model_hash": model.model_hash,
                },
                indent=2,
            )
        )
        return

    if not args.vault:
        raise SystemExit("VAULT_ADDRESS (or --vault) is required")

    Agent(args, model).run()


if __name__ == "__main__":
    main()

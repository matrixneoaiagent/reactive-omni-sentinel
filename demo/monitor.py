#!/usr/bin/env python3
"""Terminal dashboard for the Sentinel demo.

    python demo/monitor.py --vault 0x... --feed 0x... --once
    python demo/monitor.py --vault 0x... --feed 0x...          # refresh loop
"""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path

from web3 import Web3

ABI = [
    {"anonymous": False, "inputs": [
        {"indexed": True, "name": "tickId", "type": "uint256"},
        {"indexed": False, "name": "price", "type": "uint256"},
        {"indexed": False, "name": "timestamp", "type": "uint256"}],
     "name": "PriceTick", "type": "event"},
    {"anonymous": False, "inputs": [
        {"indexed": True, "name": "requestId", "type": "uint256"},
        {"indexed": True, "name": "tickId", "type": "uint256"},
        {"indexed": False, "name": "features", "type": "int256[6]"},
        {"indexed": False, "name": "requestedAt", "type": "uint64"}],
     "name": "RiskAssessmentRequested", "type": "event"},
    {"anonymous": False, "inputs": [
        {"indexed": True, "name": "requestId", "type": "uint256"},
        {"indexed": True, "name": "tickId", "type": "uint256"},
        {"indexed": False, "name": "scoreBps", "type": "uint16"},
        {"indexed": False, "name": "modelHash", "type": "bytes32"},
        {"indexed": True, "name": "agent", "type": "address"}],
     "name": "RiskScoreSubmitted", "type": "event"},
    {"anonymous": False, "inputs": [
        {"indexed": True, "name": "requestId", "type": "uint256"},
        {"indexed": False, "name": "mode", "type": "uint8"},
        {"indexed": False, "name": "scoreBps", "type": "uint16"}],
     "name": "PolicyApplied", "type": "event"},
    {"anonymous": False, "inputs": [
        {"indexed": False, "name": "from", "type": "uint8"},
        {"indexed": False, "name": "to", "type": "uint8"}],
     "name": "ModeChanged", "type": "event"},
    {"anonymous": False, "inputs": [
        {"indexed": True, "name": "requestId", "type": "uint256"},
        {"indexed": False, "name": "mode", "type": "uint8"}],
     "name": "FallbackApplied", "type": "event"},
    {"inputs": [], "name": "mode", "outputs": [{"name": "", "type": "uint8"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "riskScoreBps", "outputs": [{"name": "", "type": "uint16"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "lastTickId", "outputs": [{"name": "", "type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "lastRequestId", "outputs": [{"name": "", "type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "totalDeposits", "outputs": [{"name": "", "type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "tickId", "outputs": [{"name": "", "type": "uint256"}], "stateMutability": "view", "type": "function"},
]

GREEN = "\033[92m"
RED = "\033[91m"
DIM = "\033[2m"
BOLD = "\033[1m"
RESET = "\033[0m"


def load_env(path: str | None) -> None:
    if not path:
        return
    for line in Path(path).read_text().splitlines():
        if "=" in line and not line.strip().startswith("#"):
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rpc", default=None)
    ap.add_argument("--vault", default=os.environ.get("VAULT_ADDRESS"))
    ap.add_argument("--feed", default=os.environ.get("PRICE_FEED"))
    ap.add_argument("--lookback", type=int, default=9000)
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--env-file", default="deploy/config.env")
    args = ap.parse_args()

    load_env(args.env_file if Path(args.env_file).exists() else None)
    args.rpc = (
        args.rpc
        or os.environ.get("RPC_ORIGIN")
        or os.environ.get("RPC_URL")
        or "https://ethereum-sepolia-rpc.publicnode.com"
    )
    deployment = Path("deployments/latest.json")
    if deployment.exists():
        dep = json.loads(deployment.read_text())
        args.vault = args.vault or dep["contracts"]["vault"]
        args.feed = args.feed or dep["contracts"]["price_feed"]
        args.rpc = args.rpc or dep.get("rpc_origin")
    if not args.vault or not args.feed:
        raise SystemExit("--vault and --feed are required (or VAULT_ADDRESS / PRICE_FEED)")

    w3 = Web3(Web3.HTTPProvider(args.rpc, request_kwargs={"timeout": 30}))
    vault = w3.eth.contract(address=Web3.to_checksum_address(args.vault), abi=ABI)
    feed = w3.eth.contract(address=Web3.to_checksum_address(args.feed), abi=ABI)

    while True:
        latest = w3.eth.block_number
        start = max(0, latest - args.lookback)
        mode = vault.functions.mode().call()
        score = vault.functions.riskScoreBps().call()
        tick = vault.functions.lastTickId().call()
        feed_tick = feed.functions.tickId().call()
        deposits = vault.functions.totalDeposits().call() / 1e18

        print("\033[2J\033[H", end="")
        print(f"{BOLD}Sentinel{RESET}  chain {w3.eth.chain_id} block {latest}  feed tick {feed_tick}")
        badge = f"{GREEN}NORMAL{RESET}" if mode == 0 else f"{RED}DEFENSIVE{RESET}"
        print(f"mode {badge}   AI risk score {score}/10000   last request {tick}   deposits {deposits:.4f} ETH")
        print(f"{DIM}{args.vault}{RESET}")
        print()

        logs = []
        logs += feed.events.PriceTick().get_logs(from_block=start, to_block=latest)
        logs += vault.events.RiskAssessmentRequested().get_logs(from_block=start, to_block=latest)
        logs += vault.events.RiskScoreSubmitted().get_logs(from_block=start, to_block=latest)
        logs += vault.events.PolicyApplied().get_logs(from_block=start, to_block=latest)
        logs += vault.events.ModeChanged().get_logs(from_block=start, to_block=latest)
        logs += vault.events.FallbackApplied().get_logs(from_block=start, to_block=latest)
        logs.sort(key=lambda e: (e["blockNumber"], e["logIndex"]))

        for e in logs[-24:]:
            name = e["event"]
            a = e["args"]
            tx = e["transactionHash"].hex()
            if name == "PriceTick":
                print(f"  {DIM}{tx[:10]}{RESET}  tick {a['tickId']:>3}  price {a['price']/1e8:>9.2f}")
            elif name == "RiskAssessmentRequested":
                print(f"  {DIM}{tx[:10]}{RESET}  tick {a['tickId']:>3}  {BOLD}assessment requested{RESET}")
            elif name == "RiskScoreSubmitted":
                print(f"  {DIM}{tx[:10]}{RESET}  tick {a['tickId']:>3}  score {a['scoreBps']:>5}  by {a['agent'][:10]}")
            elif name == "PolicyApplied":
                tag = "NORMAL" if a["mode"] == 0 else "DEFENSIVE"
                print(f"  {DIM}{tx[:10]}{RESET}  tick {a['requestId']:>3}  policy {tag}  score {a['scoreBps']:>5}")
            elif name == "ModeChanged":
                print(f"  {DIM}{tx[:10]}{RESET}  MODE {a['from']} -> {a['to']}")
            elif name == "FallbackApplied":
                print(f"  {DIM}{tx[:10]}{RESET}  tick {a['requestId']:>3}  FALLBACK defensive")

        if args.once:
            break
        time.sleep(3)


if __name__ == "__main__":
    main()

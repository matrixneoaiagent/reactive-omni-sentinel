#!/usr/bin/env python3
"""Print the full-loop evidence table from a deployment record.

    python demo/evidence.py --deployments deployments/latest.json --blocks 20000
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from eth_abi import decode
from eth_utils import keccak
from web3 import Web3

BASE_EXPLORER = "https://sepolia.basescan.org/tx/"
LASNA_EXPLORER = "https://lasna.reactscan.net/tx/"

ABI = [
    {"anonymous": False, "inputs": [
        {"indexed": True, "name": "tickId", "type": "uint256"},
        {"indexed": False, "name": "price", "type": "uint256"},
        {"indexed": False, "name": "timestamp", "type": "uint256"}],
     "name": "PriceTick", "type": "event"},
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
    {"inputs": [{"name": "", "type": "uint256"}], "name": "getCallbacks",
     "outputs": [{"components": [
         {"name": "blockNumber", "type": "uint256"},
         {"name": "reactiveContract", "type": "address"},
         {"name": "index", "type": "uint256"},
         {"name": "destChainId", "type": "uint256"},
         {"name": "destTxHash", "type": "uint256"},
         {"name": "err", "type": "bytes"}], "name": "", "type": "tuple[]"}],
     "stateMutability": "view", "type": "function"},
]

CALLBACK_REQUEST = "0x" + keccak(text="CallbackRequest(uint256,address,address,uint8,bytes)").hex()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--deployments", default="deployments/latest.json")
    ap.add_argument("--blocks", type=int, default=20000)
    ap.add_argument("--rpc-base", default="https://sepolia.base.org")
    ap.add_argument("--rpc-lasna", default="https://lasna-rpc.rnk.dev/")
    args = ap.parse_args()

    dep = json.loads(Path(args.deployments).read_text())
    feed = Web3.to_checksum_address(dep["contracts"]["price_feed"])
    vault = Web3.to_checksum_address(dep["contracts"]["vault"])
    reactive = Web3.to_checksum_address(dep["contracts"]["reactive"])

    base = Web3(Web3.HTTPProvider(args.rpc_base, request_kwargs={"timeout": 30}))
    lasna = Web3(Web3.HTTPProvider(args.rpc_lasna, request_kwargs={"timeout": 30}))

    earliest = int(dep.get("block", 0))
    base_latest = base.eth.block_number
    lasna_latest = lasna.eth.block_number
    base_from = max(earliest, base_latest - args.blocks)
    lasna_from = max(earliest, lasna_latest - args.blocks)

    feed_c = base.eth.contract(address=feed, abi=ABI)
    vault_c = base.eth.contract(address=vault, abi=ABI)
    system = lasna.eth.contract(
        address=Web3.to_checksum_address("0x8888888888888888888888888888888888888888"), abi=ABI
    )

    ticks = feed_c.events.PriceTick().get_logs(from_block=base_from, to_block=base_latest)
    scores = vault_c.events.RiskScoreSubmitted().get_logs(from_block=base_from, to_block=base_latest)
    policies = vault_c.events.PolicyApplied().get_logs(from_block=base_from, to_block=base_latest)
    modes = vault_c.events.ModeChanged().get_logs(from_block=base_from, to_block=base_latest)
    requests = lasna.eth.get_logs({
        "address": system.address,
        "fromBlock": lasna_from,
        "toBlock": lasna_latest,
        "topics": [CALLBACK_REQUEST],
    })

    rows = []
    for e in ticks:
        rows.append((e["blockNumber"], "origin", f"PriceTick #{e['args']['tickId']} price {e['args']['price']/1e8:.2f}", BASE_EXPLORER + e["transactionHash"].hex()))
    for e in scores:
        rows.append((e["blockNumber"], "base", f"score {e['args']['scoreBps']} for request {e['args']['requestId']}", BASE_EXPLORER + e["transactionHash"].hex()))
    for e in policies:
        rows.append((e["blockNumber"], "base", f"policy mode {e['args']['mode']} score {e['args']['scoreBps']}", BASE_EXPLORER + e["transactionHash"].hex()))
    for e in modes:
        rows.append((e["blockNumber"], "base", f"ModeChanged {e['args']['from']} -> {e['args']['to']}", BASE_EXPLORER + e["transactionHash"].hex()))

    for log in requests:
        if int(log["topics"][2], 16) != int(reactive, 16):
            continue
        txh = log["transactionHash"].hex()
        version, config = decode(["uint8", "bytes"], bytes(log["data"]))
        chain_id, recipient, gas_limit, payload = decode(
            ["(uint256,address,uint64,bytes)"], config
        )[0]
        request_id = int.from_bytes(payload[4:36], "big")
        rows.append((log["blockNumber"], "lasna", f"CallbackRequest -> {recipient} (request {request_id}, {len(payload)} B, gas {gas_limit})", LASNA_EXPLORER + txh))

        try:
            recs = system.functions.getCallbacks(int(txh, 16)).call()
        except Exception:
            recs = []
        for rec in recs:
            dest = "0x" + int(rec[4]).to_bytes(32, "big").hex()
            err = rec[5]
            label = "callback ok" if not err else f"callback error {err.hex()[:20]}"
            rows.append((log["blockNumber"], "dest", f"{label} chain {rec[3]}", BASE_EXPLORER + dest))

    rows.sort(key=lambda r: r[0])
    for block, where, what, link in rows:
        print(f"{block:>10}  {where:5}  {what:<70}  {link}")


if __name__ == "__main__":
    main()

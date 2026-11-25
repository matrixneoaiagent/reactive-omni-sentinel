#!/usr/bin/env python3
"""Local end-to-end rehearsal on Anvil.

Anvil has no Reactive Network, so this script plays the two watchers the real
network provides: it forwards PriceTick logs into the reactive contract's
`react()`, and forwards RiskScoreSubmitted logs back.  Everything else --
contracts, callbacks, auth, model verification, policy -- is the production
code.

    python demo/local_loop.py tick 200000000000
    python demo/local_loop.py relay
    python demo/local_loop.py status
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from eth_abi import encode
from eth_utils import keccak
from web3 import Web3

ABI = [
    {"inputs": [{"name": "price", "type": "uint256"}], "name": "publish",
     "outputs": [{"name": "id", "type": "uint256"}], "stateMutability": "nonpayable", "type": "function"},
    {"inputs": [], "name": "tickId", "outputs": [{"name": "", "type": "uint256"}],
     "stateMutability": "view", "type": "function"},
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
    {"inputs": [{"name": "target", "type": "address"}, {"components": [
        {"name": "chainId", "type": "uint256"},
        {"name": "contractAddress", "type": "address"},
        {"name": "topic0", "type": "uint256"},
        {"name": "topic1", "type": "uint256"},
        {"name": "topic2", "type": "uint256"},
        {"name": "topic3", "type": "uint256"},
        {"name": "data", "type": "bytes"},
        {"name": "blockNumber", "type": "uint256"},
        {"name": "opCode", "type": "uint256"},
        {"name": "blockHash", "type": "uint256"},
        {"name": "txHash", "type": "uint256"},
        {"name": "logIndex", "type": "uint256"}], "name": "log_", "type": "tuple"}],
     "name": "trigger", "outputs": [], "stateMutability": "nonpayable", "type": "function"},
    {"inputs": [], "name": "mode", "outputs": [{"name": "", "type": "uint8"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "riskScoreBps", "outputs": [{"name": "", "type": "uint16"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "lastRequestId", "outputs": [{"name": "", "type": "uint256"}], "stateMutability": "view", "type": "function"},
]

PRICE_TOPIC = "0x" + keccak(text="PriceTick(uint256,uint256,uint256)").hex()
SCORE_TOPIC = "0x" + keccak(text="RiskScoreSubmitted(uint256,uint256,uint16,bytes32,address)").hex()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["tick", "relay", "status"])
    ap.add_argument("arg", nargs="?")
    ap.add_argument("--rpc", default=None)
    ap.add_argument("--addresses", default="/tmp/opencode/reactive-local.json")
    ap.add_argument("--from", dest="sender", default=None)
    args = ap.parse_args()

    addrs = json.loads(Path(args.addresses).read_text())
    rpc = args.rpc or addrs.get("rpc") or addrs.get("rpc_origin") or "http://127.0.0.1:8549"
    rpc_lasna = addrs.get("rpc_lasna") or rpc
    chain_id = int(addrs.get("chain_id", 11155111))
    w3 = Web3(Web3.HTTPProvider(rpc, request_kwargs={"timeout": 30}))
    w3l = Web3(Web3.HTTPProvider(rpc_lasna, request_kwargs={"timeout": 30}))
    sender = Web3.to_checksum_address(args.sender or w3.eth.accounts[0])
    feed = w3.eth.contract(address=Web3.to_checksum_address(addrs["feed"]), abi=ABI)
    reactive_addr = Web3.to_checksum_address(addrs["reactive"])
    vault_addr = Web3.to_checksum_address(addrs["vault"])
    vault = w3.eth.contract(address=vault_addr, abi=ABI)
    system = w3l.eth.contract(
        address=Web3.to_checksum_address("0x8888888888888888888888888888888888888888"), abi=ABI
    )

    if args.cmd == "status":
        print(json.dumps({
            "chain_id": chain_id,
            "mode": "NORMAL" if vault.functions.mode().call() == 0 else "DEFENSIVE",
            "score": vault.functions.riskScoreBps().call(),
            "last_request": vault.functions.lastRequestId().call(),
            "feed_tick": feed.functions.tickId().call(),
        }, indent=2))
        return

    if args.cmd == "tick":
        price = int(args.arg)
        tx = feed.functions.publish(price).transact({"from": sender})
        rc = w3.eth.wait_for_transaction_receipt(tx)
        tick_id = feed.functions.tickId().call()
        block = w3.eth.get_block(rc.blockNumber)
        log = (
            chain_id,
            feed.address,
            int(PRICE_TOPIC, 16),
            tick_id,
            0,
            0,
            encode(["uint256", "uint256"], [price, block["timestamp"]]),
            rc.blockNumber,
            2,
            0,
            0,
            0,
        )
        tx2 = system.functions.trigger(reactive_addr, log).transact({"from": sender})
        rc2 = w3l.eth.wait_for_transaction_receipt(tx2)
        print(f"tick {tick_id} price {price} publish {tx.hex()} react {tx2.hex()} block {rc2.blockNumber}")
        return

    if args.cmd == "relay":
        logs = vault.events.RiskScoreSubmitted().get_logs(from_block=0, to_block=w3.eth.block_number)
        if not logs:
            raise SystemExit("no score events yet")
        e = logs[-1]
        a = e["args"]
        data = encode(["uint16", "bytes32", "address"], [a["scoreBps"], a["modelHash"], a["agent"]])
        log = (
            chain_id,
            vault_addr,
            int(SCORE_TOPIC, 16),
            a["requestId"],
            a["tickId"],
            0,
            data,
            e["blockNumber"],
            3,
            0,
            0,
            0,
        )
        tx = system.functions.trigger(reactive_addr, log).transact({"from": sender})
        rc = w3l.eth.wait_for_transaction_receipt(tx)
        print(f"relayed score {a['scoreBps']} request {a['requestId']} tx {tx.hex()} block {rc.blockNumber}")
        return


if __name__ == "__main__":
    main()

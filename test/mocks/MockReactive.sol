// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IReactive } from "reactive-lib/interfaces/IReactive.sol";

/// @notice Minimal stand-in for the Reactive system contract, used only in
///         tests.  Etched at 0x8888... so the real contracts run unmodified.
contract MockSystem {
    struct Call {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    struct Subscription {
        uint256 chainId;
        address contractAddress;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    Call[] public calls;
    Subscription[] public subscriptions;
    address public proxy;
    uint256 public subscribeCount;
    uint256 public unsubscribeCount;

    function setProxy(address proxy_) external {
        proxy = proxy_;
    }

    function subscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external {
        subscriptions.push(
            Subscription({
                chainId: chainId_,
                contractAddress: contract_,
                topic0: topic0_,
                topic1: topic1_,
                topic2: topic2_,
                topic3: topic3_
            })
        );
        subscribeCount++;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        unsubscribeCount++;
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function reserves(address) external pure returns (uint256) {
        return 0;
    }

    function requestCallbackV_1_0(Call memory call_) external {
        calls.push(call_);
        if (proxy != address(0)) {
            MockProxy(proxy).deliver(call_.recipient, call_.payload, msg.sender);
        }
    }

    function trigger(address target, IReactive.LogRecord calldata log_) external {
        IReactive(payable(target)).react(log_);
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function callAt(uint256 i) external view returns (Call memory) {
        return calls[i];
    }

    function lastCall() external view returns (Call memory) {
        return calls[calls.length - 1];
    }

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function subscriptionAt(uint256 i) external view returns (Subscription memory) {
        return subscriptions[i];
    }
}

/// @notice Stand-in for the destination-chain callback proxy.  Overwrites the
///         first argument of the payload with the requesting reactive
///         contract, exactly like the production proxy.
contract MockProxy {
    error DeliveryFailed(bytes reason);

    function deliver(address recipient, bytes calldata payload, address sender) external {
        bytes memory p = payload;
        assembly {
            // preserve the 4-byte selector and replace the first argument word
            mstore(add(p, 36), sender)
        }
        (bool ok, bytes memory reason) = recipient.call(p);
        if (!ok) revert DeliveryFailed(reason);
    }
}

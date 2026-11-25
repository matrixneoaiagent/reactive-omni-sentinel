// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { BaseTest } from "./BaseTest.sol";
import { IReactive } from "reactive-lib/interfaces/IReactive.sol";
import { SentinelModel } from "../src/lib/SentinelModel.sol";
import { MockSystem } from "./mocks/MockReactive.sol";
import { SentinelReactive } from "../src/SentinelReactive.sol";
import { SentinelVault } from "../src/SentinelVault.sol";

contract ReactiveTest is BaseTest {
    bytes4 internal constant REQUEST_SELECTOR =
        bytes4(keccak256("requestRiskAssessment(address,uint256,int256[6])"));
    bytes4 internal constant POLICY_SELECTOR = bytes4(keccak256("applyPolicy(address,uint256)"));
    bytes4 internal constant FALLBACK_SELECTOR =
        bytes4(keccak256("applyFallback(address,uint256)"));

    function test_subscriptions() public view {
        // price feed subscription in the constructor + vault subscription
        assertEq(sys.subscribeCount(), 2);
        assertEq(sys.subscriptionCount(), 2);
        assertEq(reactive.owner(), address(this));
        assertEq(reactive.vault(), address(vault));
        assertEq(address(vault._SERVICE_PROVIDER()), proxy);

        MockSystem.Subscription memory priceSub = sys.subscriptionAt(0);
        assertEq(priceSub.chainId, originChain);
        assertEq(priceSub.contractAddress, address(feed));
        assertEq(priceSub.topic0, reactive.PRICE_TICK_TOPIC0());

        MockSystem.Subscription memory scoreSub = sys.subscriptionAt(1);
        assertEq(scoreSub.chainId, originChain);
        assertEq(scoreSub.contractAddress, address(vault));
        assertEq(scoreSub.topic0, reactive.RISK_SCORE_TOPIC0());
    }

    function test_reactIsSystemOnly() public {
        IReactive.LogRecord memory empty;
        vm.expectRevert();
        reactive.react(empty);
    }

    function test_firstFiveTicksDoNotCallback() public {
        pushTick(2000e8);
        pushTick(2001e8);
        pushTick(2002e8);
        pushTick(2003e8);
        pushTick(2004e8);

        assertEq(sys.callCount(), 0);
        (uint256 id,, bool active) = reactive.pending();
        assertEq(id, 0);
        assertFalse(active);
        assertEq(reactive.priceCount(), 5);
    }

    function test_sixthTickRequestsInference() public {
        for (uint256 i = 0; i < 6; i++) {
            pushTick(2000e8 + i * 1e8);
        }

        assertEq(sys.callCount(), 1);
        MockSystem.Call memory c = sys.lastCall();
        assertEq(c.chainId, originChainId());
        assertEq(c.recipient, address(vault));
        assertEq(bytes4(c.payload), REQUEST_SELECTOR);
        assertGe(c.gasLimit, 100_000);

        (uint256 requestId, uint64 at, bool active) = reactive.pending();
        assertEq(requestId, 6);
        assertGt(at, 0);
        assertTrue(active);

        (,,, bool scored,) = vault.getRequest(6);
        assertFalse(scored);
    }

    function test_scoreTriggersPolicyCallback() public {
        for (uint256 i = 0; i < 6; i++) {
            pushTick(2000e8 + i * 1e8);
        }
        uint16 score = settle();

        assertEq(sys.callCount(), 2);
        MockSystem.Call memory c = sys.lastCall();
        assertEq(bytes4(c.payload), POLICY_SELECTOR);
        assertEq(c.recipient, address(vault));

        (uint256 id,, bool active) = reactive.pending();
        assertEq(id, 6);
        assertFalse(active);
        assertEq(reactive.lastAppliedRequestId(), 6);
        assertEq(vault.riskScoreBps(), score);
        assertEq(uint8(vault.mode()), uint8(SentinelVault.Mode.NORMAL));
    }

    function test_duplicateTickIsIgnored() public {
        for (uint256 i = 1; i <= 6; i++) {
            pushTick(2000e8 + i * 1e8);
        }
        uint256 before = sys.callCount();

        // replay tick 6 exactly
        uint256 price = 2000e8 + 5e8;
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: originChain,
            contractAddress: address(feed),
            topic0: reactive.PRICE_TICK_TOPIC0(),
            topic1: 6,
            topic2: 0,
            topic3: 0,
            data: abi.encode(price, block.timestamp),
            blockNumber: block.number,
            opCode: 2,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        sys.trigger(address(reactive), log_);
        assertEq(sys.callCount(), before);
    }

    function test_staleScoreIsIgnored() public {
        for (uint256 i = 0; i < 6; i++) {
            pushTick(2000e8 + i * 1e8);
        }
        // answer request 6 but deliver the score as if it were request 5
        (bool ok,) = answerPending();
        assertTrue(ok);
        uint256 before = sys.callCount();

        uint16 score = vault.riskScoreBps();
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: originChain,
            contractAddress: address(vault),
            topic0: reactive.RISK_SCORE_TOPIC0(),
            topic1: 5,
            topic2: 5,
            topic3: 0,
            data: abi.encode(score, SentinelModel.MODEL_HASH, address(this)),
            blockNumber: block.number,
            opCode: 3,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        sys.trigger(address(reactive), log_);
        assertEq(sys.callCount(), before);
    }

    function test_fallbackWhenAgentIsSilent() public {
        for (uint256 i = 0; i < 6; i++) {
            pushTick(2000e8 + i * 1e8);
        }
        assertEq(sys.callCount(), 1);

        vm.warp(block.timestamp + 181);
        pushTick(2008e8);

        // applyFallback for the stale request, then a fresh inference request
        assertEq(sys.callCount(), 3);
        MockSystem.Call memory fb = sys.callAt(1);
        assertEq(bytes4(fb.payload), FALLBACK_SELECTOR);
        MockSystem.Call memory fresh = sys.callAt(2);
        assertEq(bytes4(fresh.payload), REQUEST_SELECTOR);

        // the fallback callback put the vault into defensive mode
        assertEq(uint8(vault.mode()), uint8(SentinelVault.Mode.DEFENSIVE));
    }

    function test_currentFeatures() public {
        vm.expectRevert(SentinelReactive.FeatureWindowTooShort.selector);
        reactive.currentFeatures();

        for (uint256 i = 0; i < 6; i++) {
            pushTick(2000e8 + i * 1e8);
        }
        int256[6] memory f = reactive.currentFeatures();
        assertEq(f[0], 9980); // ~5 bps up, x20
        assertGt(f[2], 0);
    }
}

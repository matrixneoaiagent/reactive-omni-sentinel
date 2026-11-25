// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IReactive } from "reactive-lib/interfaces/IReactive.sol";
import { IPayable } from "reactive-lib/interfaces/IPayable.sol";

import { PriceFeedOrigin } from "../src/PriceFeedOrigin.sol";
import { SentinelReactive } from "../src/SentinelReactive.sol";
import { SentinelVault } from "../src/SentinelVault.sol";
import { SentinelModel } from "../src/lib/SentinelModel.sol";
import { MockSystem, MockProxy } from "./mocks/MockReactive.sol";

/// @notice Shared fixture.  The origin/destination chain is a virtual so the
///         same suite can run against Base Sepolia and Ethereum Sepolia.
abstract contract BaseTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;

    MockSystem internal sys;
    PriceFeedOrigin internal feed;
    SentinelReactive internal reactive;
    SentinelVault internal vault;

    address internal proxy;
    uint256 internal originChain;

    /// @notice Chain where the feed and vault live, and where callbacks land.
    function originChainId() internal pure virtual returns (uint256) {
        return 84532; // Base Sepolia
    }

    /// @notice Reactive callback proxy on the origin/destination chain.
    function callbackProxy() internal pure virtual returns (address) {
        return 0x476F44b11F5C942c58f4c8E3d0300E5710743585; // Base Sepolia
    }

    function setUp() public virtual {
        originChain = originChainId();
        proxy = callbackProxy();

        vm.etch(SYSTEM_ADDR, address(new MockSystem()).code);
        vm.etch(proxy, address(new MockProxy()).code);
        sys = MockSystem(SYSTEM_ADDR);
        sys.setProxy(proxy);

        feed = new PriceFeedOrigin(address(this));
        reactive = new SentinelReactive(originChain, address(feed), originChain, address(this));
        vault = new SentinelVault(IPayable(payable(proxy)), address(reactive));
        reactive.setVault(address(vault));
    }

    /// @notice Publish a price on the origin feed and deliver the resulting log
    ///         to the reactive contract, as the network would.
    function pushTick(uint256 price) internal returns (uint256 id) {
        id = feed.publish(price);
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: originChain,
            contractAddress: address(feed),
            topic0: reactive.PRICE_TICK_TOPIC0(),
            topic1: id,
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
    }

    /// @notice The off-chain agent's job, compressed: read the request, run the
    ///         model, submit the score.
    function answerPending() internal returns (bool answered, uint16 score) {
        (uint256 requestId,, bool active) = reactive.pending();
        if (!active) return (false, 0);
        (, int256[6] memory features,,,) = vault.getRequest(requestId);
        score = SentinelModel.score(features);
        vault.submitRiskScore(requestId, score, SentinelModel.MODEL_HASH);
        answered = true;
    }

    /// @notice Deliver the vault's RiskScoreSubmitted log to the reactive
    ///         contract, which asks for the policy callback.
    function deliverScore(uint256 requestId) internal {
        uint16 score = vault.riskScoreBps();
        address agent = vault.lastAgent();
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: originChain,
            contractAddress: address(vault),
            topic0: reactive.RISK_SCORE_TOPIC0(),
            topic1: requestId,
            topic2: requestId,
            topic3: 0,
            data: abi.encode(score, SentinelModel.MODEL_HASH, agent),
            blockNumber: block.number,
            opCode: 3,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        sys.trigger(address(reactive), log_);
    }

    function settle() internal returns (uint16 score) {
        (bool answered, uint16 s) = answerPending();
        if (answered) {
            (uint256 requestId,,) = reactive.pending();
            deliverScore(requestId);
            score = s;
        }
    }

    function calmFeatures() internal pure returns (int256[6] memory) {
        return
            [int256(16000), int256(19990), int256(36800), int256(0), int256(14130), int256(-200000)];
    }

    function crashFeatures() internal pure returns (int256[6] memory) {
        return [
            int256(-300000),
            int256(-120420),
            int256(152000),
            int256(-60000),
            int256(907101),
            int256(-200000)
        ];
    }

    function recoveryFeatures() internal pure returns (int256[6] memory) {
        return [
            int256(59980),
            int256(140770),
            int256(111960),
            int256(0),
            int256(-416803),
            int256(-1000000)
        ];
    }

    function midFeatures() internal pure returns (int256[6] memory) {
        return [
            int256(60000),
            int256(-474060),
            int256(495960),
            int256(-321844),
            int256(-542942),
            int256(200000)
        ];
    }
}

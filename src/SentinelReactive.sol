// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "reactive-lib/interfaces/ISystemContract.sol";
import { IReactive } from "reactive-lib/interfaces/IReactive.sol";
import { AbstractReactive } from "reactive-lib/base/AbstractReactive.sol";
import { SentinelFeatures } from "./lib/SentinelFeatures.sol";

/// @title SentinelReactive
/// @notice Lives on Reactive Lasna.  Watches price ticks on the origin chain,
///         turns the last eight into model features, asks the vault for an AI
///         assessment, then applies the resulting policy with a second
///         callback.  If the agent misses its deadline, it applies a
///         conservative fallback instead.
contract SentinelReactive is AbstractReactive {
    struct Pending {
        uint256 requestId;
        uint64 requestedAt;
        bool active;
    }

    uint256 public constant PRICE_TICK_TOPIC0 =
        uint256(keccak256("PriceTick(uint256,uint256,uint256)"));
    uint256 public constant RISK_SCORE_TOPIC0 =
        uint256(keccak256("RiskScoreSubmitted(uint256,uint256,uint16,bytes32,address)"));

    uint256 public immutable ORIGIN_CHAIN_ID;
    address public immutable PRICE_FEED;
    uint256 public immutable DEST_CHAIN_ID;
    address public immutable owner;

    address public vault;
    uint64 public inferenceGasLimit = 500_000;
    uint64 public policyGasLimit = 300_000;
    uint256 public fallbackDelay = 180;
    uint256 public lastPriceTickId;
    uint256 public lastAppliedRequestId;
    uint256 public ticksSeen;

    uint256[8] private _prices;
    uint256 private _next;
    uint256 private _count;

    Pending public pending;

    event VaultSet(address indexed vault);
    event InferenceRequested(uint256 indexed requestId, int256[6] features);
    event PolicyRequested(uint256 indexed requestId, uint16 scoreBps);
    event FallbackRequested(uint256 indexed requestId);

    error NotOwner();
    error VaultAlreadySet();
    error ZeroAddress();
    error FeatureWindowTooShort();
    error BadDelay();

    constructor(uint256 originChainId_, address priceFeed_, uint256 destChainId_, address owner_)
        payable {
        if (priceFeed_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        ORIGIN_CHAIN_ID = originChainId_;
        PRICE_FEED = priceFeed_;
        DEST_CHAIN_ID = destChainId_;
        owner = owner_;

        SYSTEM.subscribe(
            originChainId_,
            priceFeed_,
            PRICE_TICK_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Called once, after the vault exists.  Also starts the score
    ///         subscription, which needs the vault address.
    function setVault(address vault_) external onlyOwner {
        if (vault != address(0)) revert VaultAlreadySet();
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
        SYSTEM.subscribe(
            DEST_CHAIN_ID,
            vault_,
            RISK_SCORE_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        emit VaultSet(vault_);
    }

    function setFallbackDelay(uint256 seconds_) external onlyOwner {
        if (seconds_ < 30 || seconds_ > 3600) revert BadDelay();
        fallbackDelay = seconds_;
    }

    function coverDebt() external {
        _coverDebt();
    }

    // --------------------------------------------------------------------- //
    // reactive entry point
    // --------------------------------------------------------------------- //

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        if (
            log_.chainId == ORIGIN_CHAIN_ID && log_.contractAddress == PRICE_FEED
                && log_.topic0 == PRICE_TICK_TOPIC0
        ) {
            _onPriceTick(log_);
        } else if (
            vault != address(0) && log_.chainId == DEST_CHAIN_ID && log_.contractAddress == vault
                && log_.topic0 == RISK_SCORE_TOPIC0
        ) {
            _onScore(log_);
        }
    }

    function _onPriceTick(LogRecord calldata log_) internal {
        uint256 tickId = log_.topic1;
        if (tickId <= lastPriceTickId) return; // idempotent against replays
        lastPriceTickId = tickId;

        (uint256 price,) = abi.decode(log_.data, (uint256, uint256));
        _push(price);
        ticksSeen++;

        // fail-safe: an unanswered request past its deadline becomes DEFENSIVE
        if (pending.active && block.timestamp > uint256(pending.requestedAt) + fallbackDelay) {
            uint256 stale = pending.requestId;
            pending.active = false;
            emit FallbackRequested(stale);
            _requestFallback(stale);
        }

        // one in-flight request at a time: the agent should not be flooded by
        // every tick of a fast move
        if (_count >= 6 && !pending.active) {
            int256[6] memory features = SentinelFeatures.compute(_prices, _next, _count);
            pending =
                Pending({ requestId: tickId, requestedAt: uint64(block.timestamp), active: true });
            emit InferenceRequested(tickId, features);
            _requestRiskAssessment(tickId, features);
        }
    }

    function _onScore(LogRecord calldata log_) internal {
        uint256 requestId = log_.topic1;
        if (!pending.active || pending.requestId != requestId) return;
        pending.active = false;
        lastAppliedRequestId = requestId;

        (uint16 scoreBps,,) = abi.decode(log_.data, (uint16, bytes32, address));
        emit PolicyRequested(requestId, scoreBps);
        _requestPolicy(requestId);
    }

    // --------------------------------------------------------------------- //
    // callbacks
    // --------------------------------------------------------------------- //

    function _requestRiskAssessment(uint256 requestId, int256[6] memory features) internal {
        bytes memory payload = abi.encodeWithSignature(
            "requestRiskAssessment(address,uint256,int256[6])", address(0), requestId, features
        );
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: DEST_CHAIN_ID,
                recipient: vault,
                gasLimit: inferenceGasLimit,
                payload: payload
            })
        );
    }

    function _requestPolicy(uint256 requestId) internal {
        bytes memory payload =
            abi.encodeWithSignature("applyPolicy(address,uint256)", address(0), requestId);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: DEST_CHAIN_ID, recipient: vault, gasLimit: policyGasLimit, payload: payload
            })
        );
    }

    function _requestFallback(uint256 requestId) internal {
        bytes memory payload =
            abi.encodeWithSignature("applyFallback(address,uint256)", address(0), requestId);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: DEST_CHAIN_ID, recipient: vault, gasLimit: policyGasLimit, payload: payload
            })
        );
    }

    // --------------------------------------------------------------------- //
    // ring buffer / views
    // --------------------------------------------------------------------- //

    function _push(uint256 price) internal {
        _prices[_next] = price;
        _next = (_next + 1) % 8;
        if (_count < 8) _count++;
    }

    function currentFeatures() external view returns (int256[6] memory) {
        if (_count < 6) revert FeatureWindowTooShort();
        return SentinelFeatures.compute(_prices, _next, _count);
    }

    function priceCount() external view returns (uint256) {
        return _count;
    }

    function priceAt(uint256 k) external view returns (uint256) {
        require(k < _count, "out of range");
        return _prices[(_next + 8 - 1 - k) % 8];
    }
}

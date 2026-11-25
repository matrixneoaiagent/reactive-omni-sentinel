// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "reactive-lib/interfaces/IPayable.sol";
import { AbstractCallback } from "reactive-lib/base/AbstractCallback.sol";
import { SentinelModel } from "./lib/SentinelModel.sol";

/// @title SentinelVault
/// @notice A small vault on the origin/destination chain whose risk posture is set by a neural
///         network.  The agent supplies a score, but the vault recomputes the
///         inference from the committed weights and rejects anything that does
///         not match -- the AI is trusted for liveness, not for honesty.
contract SentinelVault is AbstractCallback {
    enum Mode {
        NORMAL,
        DEFENSIVE
    }

    struct Request {
        uint256 tickId;
        int256[6] features;
        uint64 requestedAt;
        uint16 scoreBps;
        bool scored;
        bool applied;
    }

    /// @notice Score at or above this level blocks new deposits.
    uint16 public constant DEFENSIVE_THRESHOLD = 6500;
    /// @notice Score at or below this level returns the vault to normal.
    uint16 public constant RECOVERY_THRESHOLD = 4900;
    bytes32 public constant MODEL_HASH = SentinelModel.MODEL_HASH;

    Mode public mode;
    uint16 public riskScoreBps;
    uint256 public lastTickId;
    uint256 public lastRequestId;
    uint256 public totalDeposits;
    address public lastAgent;

    mapping(uint256 => Request) private _requests;
    mapping(address => uint256) public deposits;

    event RiskAssessmentRequested(
        uint256 indexed requestId, uint256 indexed tickId, int256[6] features, uint64 requestedAt
    );
    event RiskScoreSubmitted(
        uint256 indexed requestId,
        uint256 indexed tickId,
        uint16 scoreBps,
        bytes32 modelHash,
        address indexed agent
    );
    event PolicyApplied(uint256 indexed requestId, uint8 mode, uint16 scoreBps);
    event FallbackApplied(uint256 indexed requestId, uint8 mode);
    event ModeChanged(uint8 from, uint8 to);
    event GuardTriggered(uint256 indexed requestId, uint16 scoreBps);
    event Deposit(address indexed user, uint256 amount);
    event Withdrawal(address indexed user, uint256 amount);

    error UnknownRequest(uint256 requestId);
    error DuplicateRequest(uint256 requestId);
    error AlreadyScored(uint256 requestId);
    error AlreadyApplied(uint256 requestId);
    error BadModelHash();
    error ScoreMismatch(uint16 supplied, uint16 computed);
    error ScoreOutOfRange();
    error GuardActive();
    error InsufficientDeposit();

    constructor(IPayable callbackProxy_, address callbackSender_)
        AbstractCallback(callbackProxy_, callbackSender_)
    { }

    // --------------------------------------------------------------------- //
    // reactive side
    // --------------------------------------------------------------------- //

    /// @notice Callback #1: the reactive contract asks for an assessment.
    function requestRiskAssessment(
        address reactive_,
        uint256 requestId,
        int256[6] calldata features
    ) external onlyServiceProvider onlyCallbackSender(reactive_) {
        Request storage r = _requests[requestId];
        if (r.requestedAt != 0) revert DuplicateRequest(requestId);

        r.tickId = requestId;
        r.features = features;
        r.requestedAt = uint64(block.timestamp);

        lastTickId = requestId;
        lastRequestId = requestId;

        emit RiskAssessmentRequested(requestId, requestId, features, uint64(block.timestamp));
    }

    /// @notice The agent's only write.  Anyone may submit, but the score must
    ///         equal the on-chain inference for the stored features.
    function submitRiskScore(uint256 requestId, uint16 scoreBps, bytes32 modelHash) external {
        Request storage r = _requests[requestId];
        if (r.requestedAt == 0) revert UnknownRequest(requestId);
        if (r.scored) revert AlreadyScored(requestId);
        if (r.applied) revert AlreadyApplied(requestId);
        if (scoreBps > 10_000) revert ScoreOutOfRange();
        if (modelHash != MODEL_HASH) revert BadModelHash();

        int256[6] memory f = r.features;
        uint16 computed = SentinelModel.score(f);
        if (computed != scoreBps) revert ScoreMismatch(scoreBps, computed);

        r.scored = true;
        r.scoreBps = scoreBps;
        riskScoreBps = scoreBps;
        lastAgent = msg.sender;

        emit RiskScoreSubmitted(requestId, r.tickId, scoreBps, modelHash, msg.sender);
    }

    /// @notice Callback #2: the reactive contract applies the policy.
    function applyPolicy(address reactive_, uint256 requestId)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        Request storage r = _requests[requestId];
        if (r.requestedAt == 0) revert UnknownRequest(requestId);
        if (!r.scored) revert UnknownRequest(requestId);
        if (r.applied) revert AlreadyApplied(requestId);
        r.applied = true;

        uint16 s = r.scoreBps;
        Mode old = mode;
        if (s >= DEFENSIVE_THRESHOLD) {
            mode = Mode.DEFENSIVE;
        } else if (s <= RECOVERY_THRESHOLD) {
            mode = Mode.NORMAL;
        }

        if (mode != old) emit ModeChanged(uint8(old), uint8(mode));
        if (mode == Mode.DEFENSIVE) emit GuardTriggered(requestId, s);
        emit PolicyApplied(requestId, uint8(mode), s);
    }

    /// @notice Fail-safe: if the agent does not answer in time, the reactive
    ///         contract can put the vault into defensive mode without a score.
    function applyFallback(address reactive_, uint256 requestId)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        Request storage r = _requests[requestId];
        if (r.requestedAt == 0) revert UnknownRequest(requestId);
        if (r.applied) revert AlreadyApplied(requestId);
        if (r.scored) revert AlreadyScored(requestId);
        r.applied = true;

        Mode old = mode;
        mode = Mode.DEFENSIVE;
        if (mode != old) emit ModeChanged(uint8(old), uint8(mode));
        emit FallbackApplied(requestId, uint8(mode));
    }

    // --------------------------------------------------------------------- //
    // user side
    // --------------------------------------------------------------------- //

    /// @notice New risk is only accepted while the AI sees a calm market.
    function deposit() external payable {
        if (mode != Mode.NORMAL) revert GuardActive();
        deposits[msg.sender] += msg.value;
        totalDeposits += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        if (deposits[msg.sender] < amount) revert InsufficientDeposit();
        deposits[msg.sender] -= amount;
        totalDeposits -= amount;
        (bool ok,) = msg.sender.call{ value: amount }("");
        require(ok, "withdraw failed");
        emit Withdrawal(msg.sender, amount);
    }

    function coverDebt() external {
        _coverDebt();
    }

    // --------------------------------------------------------------------- //
    // views
    // --------------------------------------------------------------------- //

    function getRequest(uint256 requestId)
        external
        view
        returns (
            uint256 tickId,
            int256[6] memory features,
            uint64 requestedAt,
            bool scored,
            bool applied
        )
    {
        Request storage r = _requests[requestId];
        return (r.tickId, r.features, r.requestedAt, r.scored, r.applied);
    }

    function scoreOf(uint256 requestId) external view returns (uint16) {
        return _requests[requestId].scoreBps;
    }

    function isDefensive() external view returns (bool) {
        return mode == Mode.DEFENSIVE;
    }
}

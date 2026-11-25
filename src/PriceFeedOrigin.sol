// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title Demo price feed (origin chain)
/// @notice Emits one event per published observation.  On a production
///         deployment this role would be played by a Chainlink aggregator
///         adapter or an Aerodrome/Uniswap `Sync` subscription; the reactive
///         contract only cares about the event shape.
contract PriceFeedOrigin {
    event PriceTick(uint256 indexed tickId, uint256 price, uint256 timestamp);

    error NotPublisher();
    error InvalidPrice();

    address public immutable publisher;
    uint256 public tickId;

    constructor(address publisher_) {
        publisher = publisher_;
    }

    /// @param price Price with 8 decimals, e.g. 2000e8.
    function publish(uint256 price) external returns (uint256 id) {
        if (msg.sender != publisher) revert NotPublisher();
        if (price == 0) revert InvalidPrice();
        id = ++tickId;
        emit PriceTick(id, price, block.timestamp);
    }
}

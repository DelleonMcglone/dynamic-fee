// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function decimals() external view returns (uint8);
}

/// @notice Fetches and normalises Chainlink oracle prices to 18 decimals.
library OracleManager {
    error OracleStalePrice(address feed, uint256 updatedAt);
    error OracleInvalidPrice(address feed, int256 answer);
    error OracleRoundIncomplete(address feed);

    uint256 internal constant STALENESS_THRESHOLD = 1 hours;
    uint256 internal constant TARGET_DECIMALS = 18;

    /// @notice Returns the oracle price scaled to 18 decimals.
    /// @param feed Chainlink aggregator address.
    /// @return price Price in 18-decimal format.
    function getOraclePrice(address feed) internal view returns (uint256 price) {
        AggregatorV3Interface oracle = AggregatorV3Interface(feed);

        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) = oracle.latestRoundData();

        if (answeredInRound < roundId) revert OracleRoundIncomplete(feed);
        if (answer <= 0) revert OracleInvalidPrice(feed, answer);
        if (block.timestamp - updatedAt > STALENESS_THRESHOLD) revert OracleStalePrice(feed, updatedAt);

        uint8 feedDecimals = oracle.decimals();
        if (feedDecimals < TARGET_DECIMALS) {
            price = uint256(answer) * 10 ** (TARGET_DECIMALS - feedDecimals);
        } else {
            price = uint256(answer) / 10 ** (feedDecimals - TARGET_DECIMALS);
        }
    }
}

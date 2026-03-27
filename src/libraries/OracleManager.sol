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
///         Provides both a strict version (reverts) and a safe version (returns success bool).
library OracleManager {
    error OracleStalePrice(address feed, uint256 updatedAt);
    error OracleInvalidPrice(address feed, int256 answer);
    error OracleRoundIncomplete(address feed);

    uint256 internal constant STALENESS_THRESHOLD = 1 hours;
    uint256 internal constant TARGET_DECIMALS = 18;

    /// @notice Returns the oracle price scaled to 18 decimals. Reverts on stale/invalid data.
    function getOraclePrice(address feed) internal view returns (uint256 price) {
        AggregatorV3Interface oracle = AggregatorV3Interface(feed);

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = oracle.latestRoundData();

        if (answeredInRound < roundId) revert OracleRoundIncomplete(feed);
        if (answer <= 0) revert OracleInvalidPrice(feed, answer);
        if (block.timestamp - updatedAt > STALENESS_THRESHOLD) revert OracleStalePrice(feed, updatedAt);

        price = _normalise(oracle, answer);
    }

    /// @notice Safe version that returns false instead of reverting on oracle failure.
    ///         Catches stale data, invalid prices, incomplete rounds, and external call reverts.
    function safeGetOraclePrice(address feed) internal view returns (bool success, uint256 price) {
        AggregatorV3Interface oracle = AggregatorV3Interface(feed);

        // External call may revert if feed is unreachable
        try oracle.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (answeredInRound < roundId) return (false, 0);
            if (answer <= 0) return (false, 0);
            if (block.timestamp - updatedAt > STALENESS_THRESHOLD) return (false, 0);

            price = _normalise(oracle, answer);
            success = true;
        } catch {
            return (false, 0);
        }
    }

    function _normalise(AggregatorV3Interface oracle, int256 answer) private view returns (uint256 price) {
        uint8 feedDecimals = oracle.decimals();
        if (feedDecimals < TARGET_DECIMALS) {
            price = uint256(answer) * 10 ** (TARGET_DECIMALS - feedDecimals);
        } else {
            price = uint256(answer) / 10 ** (feedDecimals - TARGET_DECIMALS);
        }
    }
}

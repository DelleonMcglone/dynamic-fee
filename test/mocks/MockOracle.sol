// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Mock Chainlink aggregator for testing.
contract MockOracle {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;
    uint80 public answeredInRound;

    constructor(uint8 _decimals, int256 _answer) {
        decimals = _decimals;
        answer = _answer;
        updatedAt = block.timestamp;
        roundId = 1;
        answeredInRound = 1;
    }

    function setAnswer(int256 _answer) external {
        answer = _answer;
        updatedAt = block.timestamp;
        roundId++;
        answeredInRound = roundId;
    }

    function setUpdatedAt(uint256 _updatedAt) external {
        updatedAt = _updatedAt;
    }

    function setStale() external {
        // Set to 0 to guarantee staleness regardless of block.timestamp
        updatedAt = 0;
    }

    function setIncompleteRound() external {
        answeredInRound = roundId - 1;
    }

    function latestRoundData()
        external
        view
        returns (uint80 _roundId, int256 _answer, uint256 startedAt, uint256 _updatedAt, uint80 _answeredInRound)
    {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}

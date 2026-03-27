// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Calculates price deviation and classifies it into fee zones.
library DeviationMonitor {
    /// @dev Zone ordering matches the fee matrix rows.
    enum Zone {
        TIGHT,    // 0–1%
        NORMAL,   // 1–3%
        ELEVATED, // 3–5%
        HIGH,     // 5–10%
        EXTREME   // >10%
    }

    error ZeroOraclePrice();

    uint256 internal constant BPS_BASE = 10_000;

    /// @notice Computes |poolPrice − oraclePrice| / oraclePrice in basis points.
    /// @dev Reverts if oraclePrice is zero (broken oracle should never reach this point).
    function calculateDeviation(uint256 poolPrice, uint256 oraclePrice) internal pure returns (uint256 deviationBps) {
        if (oraclePrice == 0) revert ZeroOraclePrice();
        uint256 diff = poolPrice > oraclePrice ? poolPrice - oraclePrice : oraclePrice - poolPrice;
        deviationBps = (diff * BPS_BASE) / oraclePrice;
    }

    /// @notice Maps a deviation (in bps) to a Zone using the provided thresholds.
    /// @param deviationBps Deviation in basis points.
    /// @param thresholds Four ascending thresholds: [tight→normal, normal→elevated, elevated→high, high→extreme].
    ///                   Defaults: [100, 300, 500, 1000].
    function classifyZone(uint256 deviationBps, uint256[4] memory thresholds) internal pure returns (Zone) {
        if (deviationBps <= thresholds[0]) return Zone.TIGHT;
        if (deviationBps <= thresholds[1]) return Zone.NORMAL;
        if (deviationBps <= thresholds[2]) return Zone.ELEVATED;
        if (deviationBps <= thresholds[3]) return Zone.HIGH;
        return Zone.EXTREME;
    }
}

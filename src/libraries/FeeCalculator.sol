// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeviationMonitor} from "./DeviationMonitor.sol";

/// @notice Determines swap direction and calculates the asymmetric fee.
library FeeCalculator {
    enum Direction {
        TOWARD,
        AWAY
    }

    /// @dev Fee matrix: [zone][direction] in hundredths of a bip (1 bps = 100).
    ///      Row = Zone enum ordinal, Col 0 = TOWARD, Col 1 = AWAY.
    ///      Values in basis points (will be converted to hundredths-of-bip on return).
    ///
    /// | Zone     | Toward | Away |
    /// |----------|--------|------|
    /// | TIGHT    |   5    |  10  |
    /// | NORMAL   |  10    |  30  |
    /// | ELEVATED |  20    |  50  |
    /// | HIGH     |  30    | 100  |
    /// | EXTREME  |  50    | 200  |

    uint24 internal constant BPS_MULTIPLIER = 100; // 1 bps = 100 hundredths-of-bip

    /// @notice Determines whether a swap moves the pool price toward or away from the oracle.
    /// @param priceBefore Pool price before swap (18 dec).
    /// @param priceAfter  Pool price after swap (18 dec).
    /// @param oraclePrice Oracle price (18 dec).
    function determineDirection(uint256 priceBefore, uint256 priceAfter, uint256 oraclePrice)
        internal
        pure
        returns (Direction)
    {
        uint256 devBefore = priceBefore > oraclePrice ? priceBefore - oraclePrice : oraclePrice - priceBefore;
        uint256 devAfter = priceAfter > oraclePrice ? priceAfter - oraclePrice : oraclePrice - priceAfter;
        return devAfter <= devBefore ? Direction.TOWARD : Direction.AWAY;
    }

    /// @notice Calculates the fee for a swap given its zone and direction.
    /// @param zone Current deviation zone.
    /// @param direction Whether swap moves toward or away from oracle.
    /// @param maxFee Maximum fee cap in hundredths-of-bip.
    /// @return fee The fee in hundredths-of-bip, capped at maxFee.
    function calculateFee(DeviationMonitor.Zone zone, Direction direction, uint24 maxFee)
        internal
        pure
        returns (uint24 fee)
    {
        uint24 baseFee = _lookupFee(zone, direction);
        fee = baseFee > maxFee ? maxFee : baseFee;
    }

    function _lookupFee(DeviationMonitor.Zone zone, Direction direction) private pure returns (uint24) {
        // Toward fees (bps): 5, 10, 20, 30, 50
        // Away fees (bps):  10, 30, 50, 100, 200

        if (zone == DeviationMonitor.Zone.TIGHT) {
            return direction == Direction.TOWARD ? 5 * BPS_MULTIPLIER : 10 * BPS_MULTIPLIER;
        }
        if (zone == DeviationMonitor.Zone.NORMAL) {
            return direction == Direction.TOWARD ? 10 * BPS_MULTIPLIER : 30 * BPS_MULTIPLIER;
        }
        if (zone == DeviationMonitor.Zone.ELEVATED) {
            return direction == Direction.TOWARD ? 20 * BPS_MULTIPLIER : 50 * BPS_MULTIPLIER;
        }
        if (zone == DeviationMonitor.Zone.HIGH) {
            return direction == Direction.TOWARD ? 30 * BPS_MULTIPLIER : 100 * BPS_MULTIPLIER;
        }
        // EXTREME
        return direction == Direction.TOWARD ? 50 * BPS_MULTIPLIER : 200 * BPS_MULTIPLIER;
    }
}

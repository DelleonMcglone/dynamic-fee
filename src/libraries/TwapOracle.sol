// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title TwapOracle (Phase 5 P5-008 — scaffold)
/// @notice In-hook time-weighted moving average over recent pool prices.
///         Replaces the Chainlink dependency in OracleManager — the TWAP
///         is the "true" price reference the DynamicFee deviation logic
///         compares spot against.
///
/// @dev v1 scaffold: time-weighted **arithmetic** mean over the last
///      `BUFFER_CAP` observations. Each call to `record` appends an
///      observation; `consult` returns the time-weighted average over
///      the requested look-back window.
///
///      Production migration to a Uniswap-v3-style cumulative
///      accumulator (single-slot O(1) reads) is tracked under a
///      follow-up. The current shape exposes the same interface so
///      DynamicFee.sol can swap implementations without an API change.
library TwapOracle {
    /// @notice Maximum observations retained per pool.
    uint16 internal constant BUFFER_CAP = 32;

    error NoObservations();
    error WindowExceedsHistory(uint256 requestedWindow, uint256 availableWindow);

    struct Observation {
        uint64 timestamp;
        uint192 priceX18; // pool price scaled to 18 decimals
    }

    struct Buffer {
        Observation[BUFFER_CAP] data;
        uint16 head; // index of the next slot to write
        uint16 size; // number of valid observations (≤ BUFFER_CAP)
    }

    /// @notice Append a new observation. Caller is responsible for using
    ///         a monotonic, on-chain `block.timestamp`.
    function record(Buffer storage buf, uint64 timestamp, uint256 priceX18) internal {
        // Cast safety: priceX18 is bounded by sqrtPriceX96^2 / Q96 normalised;
        // 18-decimal token prices fit comfortably in uint192 across realistic ranges.
        // forge-lint: disable-next-line(unsafe-typecast)
        buf.data[buf.head] = Observation({timestamp: timestamp, priceX18: uint192(priceX18)});
        buf.head = (buf.head + 1) % BUFFER_CAP;
        if (buf.size < BUFFER_CAP) buf.size += 1;
    }

    /// @notice Time-weighted average price over the trailing `window`
    ///         seconds. Reverts if no observations exist or if the
    ///         window exceeds the stored history.
    function consult(Buffer storage buf, uint64 nowTs, uint64 window) internal view returns (uint256 twapX18) {
        uint16 size = buf.size;
        if (size == 0) revert NoObservations();
        uint64 cutoff = nowTs > window ? nowTs - window : 0;

        // Walk the circular buffer from oldest to newest.
        uint16 oldestIdx = (buf.head + BUFFER_CAP - size) % BUFFER_CAP;
        Observation memory oldestObs = buf.data[oldestIdx];

        // If the entire history is younger than the requested window,
        // the buffer doesn't have enough depth to honour the request.
        if (oldestObs.timestamp > cutoff) {
            revert WindowExceedsHistory({
                requestedWindow: window,
                availableWindow: nowTs - oldestObs.timestamp
            });
        }

        uint256 weightedSum;
        uint64 totalElapsed;
        Observation memory prev = oldestObs;

        for (uint16 i = 1; i < size; ++i) {
            Observation memory cur = buf.data[(oldestIdx + i) % BUFFER_CAP];
            if (cur.timestamp <= cutoff) {
                prev = cur;
                continue;
            }
            uint64 segStart = prev.timestamp > cutoff ? prev.timestamp : cutoff;
            uint64 segEnd = cur.timestamp;
            uint64 dt = segEnd - segStart;
            // Hold prev's price across the [segStart, segEnd) interval.
            weightedSum += uint256(prev.priceX18) * dt;
            totalElapsed += dt;
            prev = cur;
        }

        // Hold the latest observation's price across [prev.timestamp, nowTs).
        if (nowTs > prev.timestamp) {
            uint64 dt = nowTs - prev.timestamp;
            weightedSum += uint256(prev.priceX18) * dt;
            totalElapsed += dt;
        }

        if (totalElapsed == 0) {
            // All observations share a single timestamp: return the latest.
            return prev.priceX18;
        }
        twapX18 = weightedSum / totalElapsed;
    }

    /// @notice Latest recorded observation. Convenience accessor for
    ///         the spot price + sanity checks.
    function latest(Buffer storage buf) internal view returns (Observation memory) {
        if (buf.size == 0) revert NoObservations();
        uint16 lastIdx = (buf.head + BUFFER_CAP - 1) % BUFFER_CAP;
        return buf.data[lastIdx];
    }
}

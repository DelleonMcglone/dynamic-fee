// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TwapOracle} from "../src/libraries/TwapOracle.sol";

contract TwapOracleHarness {
    TwapOracle.Buffer internal buf;

    function record(uint64 ts, uint256 priceX18) external {
        TwapOracle.record(buf, ts, priceX18);
    }

    function consult(uint64 nowTs, uint64 window) external view returns (uint256) {
        return TwapOracle.consult(buf, nowTs, window);
    }

    function size() external view returns (uint16) {
        return buf.size;
    }

    function latest() external view returns (TwapOracle.Observation memory) {
        return TwapOracle.latest(buf);
    }
}

contract TwapOracleTest is Test {
    TwapOracleHarness internal h;

    function setUp() public {
        h = new TwapOracleHarness();
    }

    function test_consult_revertsWithoutObservations() public {
        vm.expectRevert(TwapOracle.NoObservations.selector);
        h.consult(1000, 60);
    }

    function test_record_storesAndReportsLatest() public {
        h.record(100, 1e18);
        h.record(200, 2e18);
        TwapOracle.Observation memory last = h.latest();
        assertEq(last.timestamp, 200);
        assertEq(last.priceX18, 2e18);
        assertEq(h.size(), 2);
    }

    function test_consult_constantPriceReturnsThatPrice() public {
        h.record(100, 1_000e18);
        h.record(200, 1_000e18);
        h.record(300, 1_000e18);
        // window covers [240, 300] — all priced at 1000.
        assertEq(h.consult(300, 60), 1_000e18);
    }

    function test_consult_arithmeticAverageOverEqualIntervals() public {
        // Three observations 60s apart, prices 100, 200, 300.
        h.record(100, 100e18);
        h.record(160, 200e18);
        h.record(220, 300e18);
        // Window covers [100, 220] = 120s, comprising two equal 60s
        // segments at prices 100 and 200. Average = 150.
        assertEq(h.consult(220, 120), 150e18);
    }

    function test_consult_holdsLatestAcrossTrailingTime() public {
        h.record(100, 100e18);
        h.record(200, 300e18);
        // nowTs=260, window=60 covers [200, 260] entirely at price 300.
        assertEq(h.consult(260, 60), 300e18);
    }

    function test_consult_revertsWhenWindowExceedsHistory() public {
        h.record(1000, 1e18);
        // Only one observation; ask for a 60s window.
        vm.expectRevert(
            abi.encodeWithSelector(TwapOracle.WindowExceedsHistory.selector, uint256(60), uint256(0))
        );
        h.consult(1000, 60);
    }

    function test_record_circularBufferOverwritesOldest() public {
        // Fill past the cap and verify the oldest entries get overwritten.
        for (uint64 i = 0; i < 40; ++i) {
            h.record(i, uint256(i + 1) * 1e18);
        }
        assertEq(h.size(), 32);
        // Latest is index 39 (price = 40e18).
        TwapOracle.Observation memory last = h.latest();
        assertEq(last.timestamp, 39);
        assertEq(last.priceX18, 40e18);
    }
}

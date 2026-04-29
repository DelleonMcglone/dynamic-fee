// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "./base/BaseHook.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

import {DeviationMonitor} from "./libraries/DeviationMonitor.sol";
import {FeeCalculator} from "./libraries/FeeCalculator.sol";
import {TwapOracle} from "./libraries/TwapOracle.sol";

/// @title DynamicFee Hook
/// @notice Implements Nezlobin's directional fee framework for volatile pairs.
///         Charges asymmetric fees: lower when a swap moves the pool price
///         toward its recent time-weighted moving average, higher when it
///         moves away. The reference price is the pool's own TWAP over a
///         configurable trailing window — no external oracle dependency.
///         (P5-008: Chainlink dropped from v2 scope.)
contract DynamicFee is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using DeviationMonitor for uint256;

    // ── Structs ──

    struct PoolConfig {
        uint64 twapWindow; // trailing window in seconds for the TWAP consult
        uint24 maxFee; // Max fee in hundredths-of-bip (default 20_000 = 200 bps)
        uint24 fallbackFee; // Fee to use while the TWAP buffer is warming up (hundredths-of-bip)
        int8 decimalDiff; // token0Decimals - token1Decimals (normalises sqrtPriceX96 to 18-decimal price)
        uint256[4] zoneThresholds; // [tight, normal, elevated, high] in bps
        bool initialized;
    }

    // ── Events ──

    event PoolConfigured(PoolId indexed poolId, uint64 twapWindow, uint24 maxFee, uint24 fallbackFee, int8 decimalDiff);
    event ZoneTransition(PoolId indexed poolId, DeviationMonitor.Zone from, DeviationMonitor.Zone to);
    event FeeApplied(
        PoolId indexed poolId,
        DeviationMonitor.Zone zone,
        FeeCalculator.Direction direction,
        uint24 fee
    );
    event TwapWarmup(PoolId indexed poolId, uint24 fallbackFee);
    event TwapObservation(PoolId indexed poolId, uint64 timestamp, uint256 priceX18);

    // ── Errors ──

    error PoolNotConfigured(PoolId poolId);
    error InvalidTwapWindow();
    error InvalidMaxFee();
    error InvalidThresholds();
    error InvalidFallbackFee();

    // ── Constants ──

    uint24 public constant DEFAULT_MAX_FEE = 20_000; // 200 bps in hundredths-of-bip
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant PRICE_PRECISION = 1e18;

    // ── State ──

    mapping(PoolId => PoolConfig) public configs;
    mapping(PoolId => DeviationMonitor.Zone) public currentZones;
    /// @dev Per-pool circular buffer of (timestamp, priceX18) observations.
    ///      Populated by `afterSwap`; consulted by `_computeFee`.
    mapping(PoolId => TwapOracle.Buffer) internal twapBuffers;

    // ── Constructor ──

    constructor(IPoolManager _poolManager, address _owner) BaseHook(_poolManager) Ownable(_owner) {}

    // ── Hook Permissions ──

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ── Admin ──

    /// @notice Configure a pool's TWAP window and fee parameters.
    /// @param poolId The pool to configure.
    /// @param twapWindow Trailing window for the TWAP consult, in seconds.
    /// @param maxFee Maximum dynamic fee (hundredths-of-bip).
    /// @param fallbackFee Fee charged while the TWAP buffer is still
    ///                    warming up (hundredths-of-bip).
    /// @param decimalDiff token0Decimals − token1Decimals (e.g. 12 for WETH(18)/USDC(6)).
    /// @param thresholds Ascending zone boundaries in bps: [tight, normal, elevated, high].
    function configurePool(
        PoolId poolId,
        uint64 twapWindow,
        uint24 maxFee,
        uint24 fallbackFee,
        int8 decimalDiff,
        uint256[4] calldata thresholds
    ) external onlyOwner {
        if (twapWindow == 0) revert InvalidTwapWindow();
        if (maxFee == 0 || maxFee > LPFeeLibrary.MAX_LP_FEE) revert InvalidMaxFee();
        if (fallbackFee == 0 || fallbackFee > maxFee) revert InvalidFallbackFee();
        if (thresholds[0] >= thresholds[1] || thresholds[1] >= thresholds[2] || thresholds[2] >= thresholds[3]) {
            revert InvalidThresholds();
        }

        configs[poolId] = PoolConfig({
            twapWindow: twapWindow,
            maxFee: maxFee,
            fallbackFee: fallbackFee,
            decimalDiff: decimalDiff,
            zoneThresholds: thresholds,
            initialized: true
        });

        emit PoolConfigured(poolId, twapWindow, maxFee, fallbackFee, decimalDiff);
    }

    // ── Hook Implementations ──

    /// @notice Returns ZERO_DELTA and the dynamic fee with OVERRIDE_FEE_FLAG.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee = _computeFee(key, params.zeroForOne);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev Computes the dynamic fee for a swap, emitting the FeeApplied event.
    ///      Falls back to a conservative flat fee while the TWAP buffer
    ///      is still warming up (no observations / window > available history).
    function _computeFee(PoolKey calldata key, bool zeroForOne) internal returns (uint24 fee) {
        PoolId poolId = key.toId();
        PoolConfig storage config = configs[poolId];
        if (!config.initialized) revert PoolNotConfigured(poolId);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint256 poolPrice = _sqrtPriceX96ToPrice(sqrtPriceX96, config.decimalDiff);

        TwapOracle.Buffer storage buf = twapBuffers[poolId];
        if (!TwapOracle.available(buf, uint64(block.timestamp), config.twapWindow)) {
            emit TwapWarmup(poolId, config.fallbackFee);
            return config.fallbackFee;
        }
        uint256 twapPrice = TwapOracle.consult(buf, uint64(block.timestamp), config.twapWindow);

        DeviationMonitor.Zone zone = DeviationMonitor.classifyZone(
            DeviationMonitor.calculateDeviation(poolPrice, twapPrice), config.zoneThresholds
        );
        FeeCalculator.Direction direction = _estimateDirection(poolPrice, twapPrice, zeroForOne);
        fee = FeeCalculator.calculateFee(zone, direction, config.maxFee);

        emit FeeApplied(poolId, zone, direction, fee);
    }

    /// @notice After swap: record the new pool price into the TWAP buffer
    ///         and emit a zone transition if the deviation band changed.
    ///         Recording happens unconditionally (the buffer must populate
    ///         to ever have a TWAP); zone update is skipped while the
    ///         buffer is still warming up.
    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        PoolConfig storage config = configs[poolId];

        if (config.initialized) {
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
            uint256 poolPrice = _sqrtPriceX96ToPrice(sqrtPriceX96, config.decimalDiff);

            TwapOracle.Buffer storage buf = twapBuffers[poolId];
            TwapOracle.record(buf, uint64(block.timestamp), poolPrice);
            emit TwapObservation(poolId, uint64(block.timestamp), poolPrice);

            if (TwapOracle.available(buf, uint64(block.timestamp), config.twapWindow)) {
                uint256 twapPrice = TwapOracle.consult(buf, uint64(block.timestamp), config.twapWindow);
                uint256 deviationBps = DeviationMonitor.calculateDeviation(poolPrice, twapPrice);
                DeviationMonitor.Zone newZone = DeviationMonitor.classifyZone(deviationBps, config.zoneThresholds);

                DeviationMonitor.Zone oldZone = currentZones[poolId];
                if (newZone != oldZone) {
                    currentZones[poolId] = newZone;
                    emit ZoneTransition(poolId, oldZone, newZone);
                }
            }
        }

        return (IHooks.afterSwap.selector, 0);
    }

    // ── View Functions ──

    /// @notice Get the current zone and deviation for a pool. Returns
    ///         `twapPrice = 0` if the buffer hasn't filled the window yet.
    function getPoolStatus(PoolKey calldata key)
        external
        view
        returns (DeviationMonitor.Zone zone, uint256 deviationBps, uint256 poolPrice, uint256 twapPrice)
    {
        PoolId poolId = key.toId();
        PoolConfig storage config = configs[poolId];
        if (!config.initialized) revert PoolNotConfigured(poolId);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        poolPrice = _sqrtPriceX96ToPrice(sqrtPriceX96, config.decimalDiff);

        TwapOracle.Buffer storage buf = twapBuffers[poolId];
        if (!TwapOracle.available(buf, uint64(block.timestamp), config.twapWindow)) {
            return (DeviationMonitor.Zone.TIGHT, 0, poolPrice, 0);
        }
        twapPrice = TwapOracle.consult(buf, uint64(block.timestamp), config.twapWindow);
        deviationBps = DeviationMonitor.calculateDeviation(poolPrice, twapPrice);
        zone = DeviationMonitor.classifyZone(deviationBps, config.zoneThresholds);
    }

    /// @notice Preview the fee for a hypothetical swap. Returns the
    ///         configured fallback fee while the TWAP is warming up.
    function previewFee(PoolKey calldata key, bool zeroForOne)
        external
        view
        returns (uint24 fee, DeviationMonitor.Zone zone, FeeCalculator.Direction direction)
    {
        PoolId poolId = key.toId();
        PoolConfig storage config = configs[poolId];
        if (!config.initialized) revert PoolNotConfigured(poolId);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint256 poolPrice = _sqrtPriceX96ToPrice(sqrtPriceX96, config.decimalDiff);

        TwapOracle.Buffer storage buf = twapBuffers[poolId];
        if (!TwapOracle.available(buf, uint64(block.timestamp), config.twapWindow)) {
            return (config.fallbackFee, DeviationMonitor.Zone.TIGHT, FeeCalculator.Direction.AWAY);
        }
        uint256 twapPrice = TwapOracle.consult(buf, uint64(block.timestamp), config.twapWindow);

        uint256 deviationBps = DeviationMonitor.calculateDeviation(poolPrice, twapPrice);
        zone = DeviationMonitor.classifyZone(deviationBps, config.zoneThresholds);
        direction = _estimateDirection(poolPrice, twapPrice, zeroForOne);
        fee = FeeCalculator.calculateFee(zone, direction, config.maxFee);
    }

    // ── Internal Helpers ──

    /// @notice Converts sqrtPriceX96 to a price with 18 decimals, normalised for token decimals.
    /// @dev price = (sqrtPriceX96 / 2^96)^2 * 10^(token0Decimals - token1Decimals) * 1e18
    ///      Uses FullMath.mulDiv for overflow-safe 512-bit intermediate math.
    function _sqrtPriceX96ToPrice(uint160 sqrtPriceX96, int8 decimalDiff) internal pure returns (uint256) {
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        // price = sqrtPrice^2 * PRICE_PRECISION / Q96^2  (overflow-safe via FullMath)
        uint256 priceX96 = FullMath.mulDiv(sqrtPrice, sqrtPrice, Q96);
        uint256 rawPrice = FullMath.mulDiv(priceX96, PRICE_PRECISION, Q96);

        // Normalise for token decimal difference (token0Decimals - token1Decimals)
        if (decimalDiff > 0) {
            rawPrice = rawPrice * 10 ** uint8(decimalDiff);
        } else if (decimalDiff < 0) {
            rawPrice = rawPrice / 10 ** uint8(-decimalDiff);
        }
        return rawPrice;
    }

    /// @notice Estimates swap direction relative to the TWAP reference.
    /// @dev zeroForOne pushes price down (token0→token1 = selling token0).
    ///      If pool spot > TWAP and swap pushes price down → TOWARD (mean-reverting).
    ///      If pool spot < TWAP and swap pushes price up → TOWARD.
    ///      If spot == TWAP, any swap increases deviation → AWAY (conservative).
    function _estimateDirection(uint256 poolPrice, uint256 twapPrice, bool zeroForOne)
        internal
        pure
        returns (FeeCalculator.Direction)
    {
        // At parity any movement increases deviation — charge the higher fee
        if (poolPrice == twapPrice) return FeeCalculator.Direction.AWAY;

        bool priceAboveTwap = poolPrice > twapPrice;
        bool swapPushesDown = zeroForOne;

        // Moving toward the TWAP when:
        // - Spot above TWAP AND swap pushes price down, OR
        // - Spot below TWAP AND swap pushes price up
        if ((priceAboveTwap && swapPushesDown) || (!priceAboveTwap && !swapPushesDown)) {
            return FeeCalculator.Direction.TOWARD;
        }
        return FeeCalculator.Direction.AWAY;
    }
}

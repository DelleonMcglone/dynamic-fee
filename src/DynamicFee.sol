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
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {OracleManager} from "./libraries/OracleManager.sol";
import {DeviationMonitor} from "./libraries/DeviationMonitor.sol";
import {FeeCalculator} from "./libraries/FeeCalculator.sol";

/// @title DynamicFee Hook
/// @notice Implements Nezlobin's directional fee framework for volatile pairs.
///         Charges asymmetric fees: lower when swaps move price toward the oracle,
///         higher when swaps move price away.
contract DynamicFee is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using OracleManager for address;
    using DeviationMonitor for uint256;

    // ── Structs ──

    struct PoolConfig {
        address oracle; // Chainlink price feed
        uint24 maxFee; // Max fee in hundredths-of-bip (default 20_000 = 200 bps)
        uint256[4] zoneThresholds; // [tight, normal, elevated, high] in bps
        bool initialized;
    }

    // ── Events ──

    event PoolConfigured(PoolId indexed poolId, address oracle, uint24 maxFee);
    event ZoneTransition(PoolId indexed poolId, DeviationMonitor.Zone from, DeviationMonitor.Zone to);
    event FeeApplied(
        PoolId indexed poolId,
        DeviationMonitor.Zone zone,
        FeeCalculator.Direction direction,
        uint24 fee
    );

    // ── Errors ──

    error PoolNotConfigured(PoolId poolId);
    error InvalidOracleAddress();
    error InvalidMaxFee();
    error InvalidThresholds();

    // ── Constants ──

    uint24 public constant DEFAULT_MAX_FEE = 20_000; // 200 bps in hundredths-of-bip
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant PRICE_PRECISION = 1e18;

    // ── State ──

    mapping(PoolId => PoolConfig) public configs;
    mapping(PoolId => DeviationMonitor.Zone) public currentZones;

    // ── Constructor ──

    constructor(IPoolManager _poolManager, address _owner) BaseHook(_poolManager) Ownable(_owner) {}

    // ── Hook Permissions ──

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
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

    /// @notice Configure a pool's oracle and fee parameters. Can be called before
    ///         pool initialization or updated later by the owner.
    function configurePool(
        PoolId poolId,
        address oracle,
        uint24 maxFee,
        uint256[4] calldata thresholds
    ) external onlyOwner {
        if (oracle == address(0)) revert InvalidOracleAddress();
        if (maxFee == 0 || maxFee > LPFeeLibrary.MAX_LP_FEE) revert InvalidMaxFee();
        if (thresholds[0] >= thresholds[1] || thresholds[1] >= thresholds[2] || thresholds[2] >= thresholds[3]) {
            revert InvalidThresholds();
        }

        configs[poolId] = PoolConfig({
            oracle: oracle,
            maxFee: maxFee,
            zoneThresholds: thresholds,
            initialized: true
        });

        emit PoolConfigured(poolId, oracle, maxFee);
    }

    // ── Hook Implementations ──

    /// @notice Called before pool initialization. Decodes hookData to configure pool.
    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        // hookData is optional during initialize — pool can also be configured via configurePool
        return IHooks.beforeInitialize.selector;
    }

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
    function _computeFee(PoolKey calldata key, bool zeroForOne) internal returns (uint24 fee) {
        PoolId poolId = key.toId();
        PoolConfig storage config = configs[poolId];
        if (!config.initialized) revert PoolNotConfigured(poolId);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint256 poolPrice = _sqrtPriceX96ToPrice(sqrtPriceX96);
        uint256 oraclePrice = config.oracle.getOraclePrice();

        DeviationMonitor.Zone zone = DeviationMonitor.classifyZone(
            DeviationMonitor.calculateDeviation(poolPrice, oraclePrice), config.zoneThresholds
        );
        FeeCalculator.Direction direction = _estimateDirection(poolPrice, oraclePrice, zeroForOne);
        fee = FeeCalculator.calculateFee(zone, direction, config.maxFee);

        emit FeeApplied(poolId, zone, direction, fee);
    }

    /// @notice After swap: recalculate zone and emit transition if changed.
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
            uint256 poolPrice = _sqrtPriceX96ToPrice(sqrtPriceX96);
            uint256 oraclePrice = config.oracle.getOraclePrice();

            uint256 deviationBps = DeviationMonitor.calculateDeviation(poolPrice, oraclePrice);
            DeviationMonitor.Zone newZone = DeviationMonitor.classifyZone(deviationBps, config.zoneThresholds);

            DeviationMonitor.Zone oldZone = currentZones[poolId];
            if (newZone != oldZone) {
                currentZones[poolId] = newZone;
                emit ZoneTransition(poolId, oldZone, newZone);
            }
        }

        return (IHooks.afterSwap.selector, 0);
    }

    // ── View Functions ──

    /// @notice Get the current zone and deviation for a pool.
    function getPoolStatus(PoolKey calldata key)
        external
        view
        returns (DeviationMonitor.Zone zone, uint256 deviationBps, uint256 poolPrice, uint256 oraclePrice)
    {
        PoolId poolId = key.toId();
        PoolConfig storage config = configs[poolId];
        if (!config.initialized) revert PoolNotConfigured(poolId);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        poolPrice = _sqrtPriceX96ToPrice(sqrtPriceX96);
        oraclePrice = config.oracle.getOraclePrice();
        deviationBps = DeviationMonitor.calculateDeviation(poolPrice, oraclePrice);
        zone = DeviationMonitor.classifyZone(deviationBps, config.zoneThresholds);
    }

    /// @notice Preview the fee for a hypothetical swap.
    function previewFee(PoolKey calldata key, bool zeroForOne)
        external
        view
        returns (uint24 fee, DeviationMonitor.Zone zone, FeeCalculator.Direction direction)
    {
        PoolId poolId = key.toId();
        PoolConfig storage config = configs[poolId];
        if (!config.initialized) revert PoolNotConfigured(poolId);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint256 poolPrice = _sqrtPriceX96ToPrice(sqrtPriceX96);
        uint256 oraclePrice = config.oracle.getOraclePrice();

        uint256 deviationBps = DeviationMonitor.calculateDeviation(poolPrice, oraclePrice);
        zone = DeviationMonitor.classifyZone(deviationBps, config.zoneThresholds);
        direction = _estimateDirection(poolPrice, oraclePrice, zeroForOne);
        fee = FeeCalculator.calculateFee(zone, direction, config.maxFee);
    }

    // ── Internal Helpers ──

    /// @notice Converts sqrtPriceX96 to a price with 18 decimals.
    /// @dev price = (sqrtPriceX96 / 2^96)^2 * 1e18
    ///      = sqrtPriceX96^2 * 1e18 / 2^192
    ///      Represents price of token0 in terms of token1.
    function _sqrtPriceX96ToPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        // To avoid overflow: split multiplication
        // price = sqrtPrice^2 * PRICE_PRECISION / Q96^2
        // = (sqrtPrice * sqrtPrice / Q96) * PRICE_PRECISION / Q96
        uint256 priceX96 = (sqrtPrice * sqrtPrice) / Q96;
        return (priceX96 * PRICE_PRECISION) / Q96;
    }

    /// @notice Estimates swap direction relative to oracle.
    /// @dev zeroForOne pushes price down (token0→token1 = selling token0).
    ///      If pool price > oracle and swap pushes price down → TOWARD.
    ///      If pool price < oracle and swap pushes price up → TOWARD.
    function _estimateDirection(uint256 poolPrice, uint256 oraclePrice, bool zeroForOne)
        internal
        pure
        returns (FeeCalculator.Direction)
    {
        bool priceAboveOracle = poolPrice > oraclePrice;
        bool swapPushesDown = zeroForOne; // zeroForOne = sell token0 = price goes down

        // Moving toward oracle when:
        // - Price above oracle AND swap pushes price down, OR
        // - Price below oracle AND swap pushes price up
        if ((priceAboveOracle && swapPushesDown) || (!priceAboveOracle && !swapPushesDown)) {
            return FeeCalculator.Direction.TOWARD;
        }
        return FeeCalculator.Direction.AWAY;
    }
}

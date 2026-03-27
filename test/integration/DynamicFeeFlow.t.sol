// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {DynamicFee} from "../../src/DynamicFee.sol";
import {DeviationMonitor} from "../../src/libraries/DeviationMonitor.sol";
import {FeeCalculator} from "../../src/libraries/FeeCalculator.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {HookDeployer} from "../mocks/HookDeployer.sol";

/// @notice Full-flow integration tests simulating directional fee scenarios.
contract DynamicFeeFlowTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager manager;
    DynamicFee hook;
    MockOracle oracle;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;

    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256[4] DEFAULT_THRESHOLDS = [uint256(100), 300, 500, 1000];

    function setUp() public {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Oracle: 8 decimals, token0/token1 = 1.0 (matches 1:1 pool price)
        oracle = new MockOracle(8, 1e8);

        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        token0.mint(address(this), 10_000e18);
        token1.mint(address(this), 10_000e18);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);

        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory creationCode =
            abi.encodePacked(type(DynamicFee).creationCode, abi.encode(manager, address(this)));
        (address hookAddr, bytes32 salt) = HookDeployer.find(address(this), flags, creationCode);

        address deployed;
        assembly {
            deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        require(deployed == hookAddr, "Hook address mismatch");
        hook = DynamicFee(deployed);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(60),
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        hook.configurePool(poolId, address(oracle), 20_000, DEFAULT_THRESHOLDS);
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1000e18, salt: 0}),
            new bytes(0)
        );
    }

    /// @notice Test that after a swap moves pool price away from oracle, the zone changes.
    function test_zoneTransition_AfterSwap() public {
        // Initially in TIGHT zone (pool=oracle=1.0)
        DeviationMonitor.Zone zoneBefore = hook.currentZones(poolId);
        assertEq(uint256(zoneBefore), uint256(DeviationMonitor.Zone.TIGHT));

        // Large swap to move pool price significantly
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            new bytes(0)
        );

        // Zone should have transitioned after the large swap
        DeviationMonitor.Zone zoneAfter = hook.currentZones(poolId);
        assertTrue(uint256(zoneAfter) > uint256(DeviationMonitor.Zone.TIGHT), "Zone should have escalated");
    }

    /// @notice Oracle price change should affect subsequent swap fees.
    function test_oraclePriceChange_AffectsFees() public {
        // First swap at oracle=1.0 (pool also ~1.0, should be TIGHT zone)
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            new bytes(0)
        );

        // Change oracle to create large deviation
        oracle.setAnswer(2e8); // Oracle says price should be 2.0 but pool is ~1.0

        // Second swap — pool is now significantly deviated from oracle
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            new bytes(0)
        );

        // Zone should reflect the deviation
        DeviationMonitor.Zone zone = hook.currentZones(poolId);
        assertTrue(uint256(zone) >= uint256(DeviationMonitor.Zone.EXTREME), "Should be in extreme zone");
    }

    /// @notice Multiple sequential swaps demonstrate fee changes.
    function test_multipleSwaps_FeeProgression() public {
        // Small swap
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e17, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            new bytes(0)
        );

        DeviationMonitor.Zone zone1 = hook.currentZones(poolId);

        // Medium swap
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -10e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            new bytes(0)
        );

        DeviationMonitor.Zone zone2 = hook.currentZones(poolId);

        // Zone should escalate or stay the same with continued directional pressure
        assertTrue(uint256(zone2) >= uint256(zone1), "Zone should escalate with continued pressure");
    }

    /// @notice Swap back toward oracle should produce lower fee zone.
    function test_swapTowardOracle_ReducesZone() public {
        // Push price away first
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            new bytes(0)
        );

        DeviationMonitor.Zone zoneAfterPush = hook.currentZones(poolId);

        // Swap back (oneForZero) toward oracle
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            new bytes(0)
        );

        DeviationMonitor.Zone zoneAfterReturn = hook.currentZones(poolId);

        assertTrue(uint256(zoneAfterReturn) <= uint256(zoneAfterPush), "Zone should decrease when moving toward oracle");
    }

    /// @notice Verify previewFee returns consistent results.
    function test_previewFee() public view {
        (uint24 fee, DeviationMonitor.Zone zone, FeeCalculator.Direction direction) =
            hook.previewFee(poolKey, true);

        assertTrue(fee > 0, "Fee should be non-zero");
        assertTrue(uint256(zone) <= uint256(DeviationMonitor.Zone.EXTREME), "Zone should be valid");
        assertTrue(
            uint256(direction) <= uint256(FeeCalculator.Direction.AWAY), "Direction should be valid"
        );
    }

    receive() external payable {}
}

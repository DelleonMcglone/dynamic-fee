// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {DynamicFee} from "../src/DynamicFee.sol";
import {DeviationMonitor} from "../src/libraries/DeviationMonitor.sol";
import {FeeCalculator} from "../src/libraries/FeeCalculator.sol";
import {HookDeployer} from "./mocks/HookDeployer.sol";

contract DynamicFeeTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    IPoolManager manager;
    DynamicFee hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;

    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1

    uint256[4] DEFAULT_THRESHOLDS = [uint256(100), 300, 500, 1000];
    uint64 constant DEFAULT_TWAP_WINDOW = 60; // 60s window
    uint24 constant DEFAULT_MAX_FEE = 20_000; // 200 bps
    uint24 constant DEFAULT_FALLBACK_FEE = 3000; // 30 bps
    int8 constant DEFAULT_DECIMAL_DIFF = 0; // both 18 decimals

    function setUp() public {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        token0.mint(address(this), 1000e18);
        token1.mint(address(this), 1000e18);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Mine a hook address with BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
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

        hook.configurePool(
            poolId,
            DEFAULT_TWAP_WINDOW,
            DEFAULT_MAX_FEE,
            DEFAULT_FALLBACK_FEE,
            DEFAULT_DECIMAL_DIFF,
            DEFAULT_THRESHOLDS
        );

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 100e18, salt: 0}),
            new bytes(0)
        );
    }

    // ═══════════════════════ Pure-library Tests (still apply) ═══════════════════════

    function test_calculateDeviation() public pure {
        uint256 dev = DeviationMonitor.calculateDeviation(3030e18, 3000e18);
        assertEq(dev, 100, "Deviation should be 100 bps");

        dev = DeviationMonitor.calculateDeviation(2850e18, 3000e18);
        assertEq(dev, 500, "Deviation should be 500 bps");

        dev = DeviationMonitor.calculateDeviation(3000e18, 3000e18);
        assertEq(dev, 0, "Deviation should be 0");
    }

    function test_classifyZone_AllZones() public pure {
        uint256[4] memory t = [uint256(100), 300, 500, 1000];

        assertEq(uint256(DeviationMonitor.classifyZone(50, t)), uint256(DeviationMonitor.Zone.TIGHT));
        assertEq(uint256(DeviationMonitor.classifyZone(100, t)), uint256(DeviationMonitor.Zone.TIGHT));
        assertEq(uint256(DeviationMonitor.classifyZone(200, t)), uint256(DeviationMonitor.Zone.NORMAL));
        assertEq(uint256(DeviationMonitor.classifyZone(300, t)), uint256(DeviationMonitor.Zone.NORMAL));
        assertEq(uint256(DeviationMonitor.classifyZone(400, t)), uint256(DeviationMonitor.Zone.ELEVATED));
        assertEq(uint256(DeviationMonitor.classifyZone(500, t)), uint256(DeviationMonitor.Zone.ELEVATED));
        assertEq(uint256(DeviationMonitor.classifyZone(700, t)), uint256(DeviationMonitor.Zone.HIGH));
        assertEq(uint256(DeviationMonitor.classifyZone(1000, t)), uint256(DeviationMonitor.Zone.HIGH));
        assertEq(uint256(DeviationMonitor.classifyZone(1500, t)), uint256(DeviationMonitor.Zone.EXTREME));
    }

    function test_calculateFee_AllCombinations() public pure {
        uint24 max = 20_000;

        assertEq(FeeCalculator.calculateFee(DeviationMonitor.Zone.TIGHT, FeeCalculator.Direction.TOWARD, max), 500);
        assertEq(FeeCalculator.calculateFee(DeviationMonitor.Zone.TIGHT, FeeCalculator.Direction.AWAY, max), 1000);
        assertEq(FeeCalculator.calculateFee(DeviationMonitor.Zone.NORMAL, FeeCalculator.Direction.TOWARD, max), 1000);
        assertEq(FeeCalculator.calculateFee(DeviationMonitor.Zone.NORMAL, FeeCalculator.Direction.AWAY, max), 3000);
        assertEq(FeeCalculator.calculateFee(DeviationMonitor.Zone.ELEVATED, FeeCalculator.Direction.TOWARD, max), 2000);
        assertEq(FeeCalculator.calculateFee(DeviationMonitor.Zone.ELEVATED, FeeCalculator.Direction.AWAY, max), 5000);
        assertEq(FeeCalculator.calculateFee(DeviationMonitor.Zone.HIGH, FeeCalculator.Direction.TOWARD, max), 3000);
        assertEq(FeeCalculator.calculateFee(DeviationMonitor.Zone.HIGH, FeeCalculator.Direction.AWAY, max), 10_000);
        assertEq(FeeCalculator.calculateFee(DeviationMonitor.Zone.EXTREME, FeeCalculator.Direction.TOWARD, max), 5000);
        assertEq(FeeCalculator.calculateFee(DeviationMonitor.Zone.EXTREME, FeeCalculator.Direction.AWAY, max), 20_000);
    }

    function test_fee_RespectsMaxCap() public pure {
        uint24 smallMax = 5000;
        uint24 fee =
            FeeCalculator.calculateFee(DeviationMonitor.Zone.EXTREME, FeeCalculator.Direction.AWAY, smallMax);
        assertEq(fee, smallMax, "Fee should be capped at maxFee");
    }

    // ═══════════════════════ Hook Config Tests ═══════════════════════

    function test_configurePool_OnlyOwner() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        hook.configurePool(
            poolId,
            DEFAULT_TWAP_WINDOW,
            DEFAULT_MAX_FEE,
            DEFAULT_FALLBACK_FEE,
            DEFAULT_DECIMAL_DIFF,
            DEFAULT_THRESHOLDS
        );
    }

    function test_configurePool_InvalidTwapWindow() public {
        vm.expectRevert(DynamicFee.InvalidTwapWindow.selector);
        hook.configurePool(
            poolId, 0, DEFAULT_MAX_FEE, DEFAULT_FALLBACK_FEE, DEFAULT_DECIMAL_DIFF, DEFAULT_THRESHOLDS
        );
    }

    function test_configurePool_InvalidMaxFee() public {
        vm.expectRevert(DynamicFee.InvalidMaxFee.selector);
        hook.configurePool(
            poolId, DEFAULT_TWAP_WINDOW, 0, DEFAULT_FALLBACK_FEE, DEFAULT_DECIMAL_DIFF, DEFAULT_THRESHOLDS
        );
    }

    function test_configurePool_InvalidFallbackFee() public {
        vm.expectRevert(DynamicFee.InvalidFallbackFee.selector);
        hook.configurePool(
            poolId, DEFAULT_TWAP_WINDOW, DEFAULT_MAX_FEE, 0, DEFAULT_DECIMAL_DIFF, DEFAULT_THRESHOLDS
        );

        vm.expectRevert(DynamicFee.InvalidFallbackFee.selector);
        hook.configurePool(
            poolId,
            DEFAULT_TWAP_WINDOW,
            DEFAULT_MAX_FEE,
            DEFAULT_MAX_FEE + 1, // > maxFee
            DEFAULT_DECIMAL_DIFF,
            DEFAULT_THRESHOLDS
        );
    }

    function test_configurePool_InvalidThresholds() public {
        uint256[4] memory bad = [uint256(300), 100, 500, 1000];
        vm.expectRevert(DynamicFee.InvalidThresholds.selector);
        hook.configurePool(
            poolId, DEFAULT_TWAP_WINDOW, DEFAULT_MAX_FEE, DEFAULT_FALLBACK_FEE, DEFAULT_DECIMAL_DIFF, bad
        );
    }

    function test_configurePool_StoresCorrectly() public view {
        // Auto-generated getter skips the `zoneThresholds[4]` array field.
        (uint64 window, uint24 maxFee, uint24 fbFee, int8 decDiff, bool initialized) =
            hook.configs(poolId);
        assertEq(window, DEFAULT_TWAP_WINDOW);
        assertEq(maxFee, DEFAULT_MAX_FEE);
        assertEq(fbFee, DEFAULT_FALLBACK_FEE);
        assertEq(decDiff, DEFAULT_DECIMAL_DIFF);
        assertTrue(initialized);
    }

    // ═══════════════════════ TWAP Warmup Tests ═══════════════════════

    function test_previewFee_FallsBackWhenTwapNotWarm() public view {
        // No swaps yet → buffer empty → fallback fee
        (uint24 fee,,) = hook.previewFee(poolKey, true);
        assertEq(fee, DEFAULT_FALLBACK_FEE, "Should use fallback fee when TWAP not warm");
    }

    function test_getPoolStatus_ZeroTwapWhenNotWarm() public view {
        (DeviationMonitor.Zone zone, uint256 dev, uint256 spotPrice, uint256 twapPrice) =
            hook.getPoolStatus(poolKey);
        assertEq(uint256(zone), uint256(DeviationMonitor.Zone.TIGHT));
        assertEq(dev, 0);
        assertGt(spotPrice, 0, "Spot is observable from PoolManager.getSlot0");
        assertEq(twapPrice, 0, "TWAP unavailable until window has elapsed");
    }

    // ═══════════════════════ Hook Permissions ═══════════════════════

    function test_getHookPermissions() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.beforeInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
    }

    // ═══════════════════════ TWAP Integration (deep) ═══════════════════════

    /// @dev Deep TWAP-driven fee tests — drive multiple swaps with vm.warp
    /// in between, confirm fee transitions across zones — pending a
    /// dedicated test fixture that tightens slippage so each swap leaves
    /// a predictable price imprint. Tracked under P5-010 in the parent
    /// repo's integration test suite. Stub for layout only.
    function test_swap_warmsBufferThenAdjustsFee() public {
        vm.skip(true);
    }
}

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
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {DynamicFee} from "../../src/DynamicFee.sol";
import {DeviationMonitor} from "../../src/libraries/DeviationMonitor.sol";
import {FeeCalculator} from "../../src/libraries/FeeCalculator.sol";
import {HookDeployer} from "../mocks/HookDeployer.sol";

/// @title End-to-end TWAP integration test
/// @notice Drives swaps through the hook to confirm the TWAP buffer
///         populates, the fee falls back during warmup, and zone updates
///         take effect once the window has elapsed.
contract DynamicFeeFlowTest is Test {
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

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint64 constant TWAP_WINDOW = 60;
    uint256[4] DEFAULT_THRESHOLDS = [uint256(100), 300, 500, 1000];

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

        token0.mint(address(this), 10_000e18);
        token1.mint(address(this), 10_000e18);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);

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

        hook.configurePool(poolId, TWAP_WINDOW, 20_000, 3000, int8(0), DEFAULT_THRESHOLDS);
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1000e18, salt: 0}),
            new bytes(0)
        );

        // Anchor the test clock so vm.warp deltas are predictable.
        vm.warp(1_000_000);
    }

    function _swap(bool zeroForOne, int256 amount) internal {
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            new bytes(0)
        );
    }

    function test_previewFee_FallsBackDuringWarmup() public {
        // No observations yet → fallback fee.
        (uint24 fee,,) = hook.previewFee(poolKey, true);
        assertEq(fee, 3000, "Fallback fee while TWAP buffer is empty");

        // First swap seeds one observation but window hasn't elapsed.
        _swap(true, -1e16);
        (uint24 feeAfter1,,) = hook.previewFee(poolKey, true);
        assertEq(feeAfter1, 3000, "Still falling back - only one observation");
    }

    function test_zoneStaysTight_WhenWarmupComplete_NoVolatility() public {
        // Seed an observation, warp past the window, take another reading.
        _swap(true, -1e16);
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        _swap(true, -1e16);

        // Buffer now spans > window. Spot price is still very close to
        // the seeded price, so deviation should be small (TIGHT zone).
        DeviationMonitor.Zone zone = hook.currentZones(poolId);
        assertEq(uint256(zone), uint256(DeviationMonitor.Zone.TIGHT));
    }

    function test_zoneTransition_AfterLargeSwap_PostWarmup() public {
        // Seed buffer, advance past window.
        _swap(true, -1e16);
        vm.warp(block.timestamp + TWAP_WINDOW + 1);

        // Drive a large swap that pushes price meaningfully off the
        // (still-anchored) TWAP. Zone should escalate.
        _swap(true, -50e18);
        DeviationMonitor.Zone zoneAfter = hook.currentZones(poolId);
        assertTrue(
            uint256(zoneAfter) > uint256(DeviationMonitor.Zone.TIGHT),
            "Zone should escalate after large swap pushes spot away from TWAP"
        );
    }

    /// @dev Fine-grained zone transition assertions (TIGHT → NORMAL →
    /// ELEVATED → HIGH → EXTREME boundary checks) require a more
    /// surgical test fixture that controls swap size to land within
    /// each band. Tracked under P5-010 in the parent repo. Stub for
    /// layout only.
    function test_meanReverting_ReducesZone() public {
        vm.skip(true);
    }

    receive() external payable {}
}

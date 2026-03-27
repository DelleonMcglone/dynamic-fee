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

import {DynamicFee} from "../src/DynamicFee.sol";
import {OracleManager} from "../src/libraries/OracleManager.sol";
import {DeviationMonitor} from "../src/libraries/DeviationMonitor.sol";
import {FeeCalculator} from "../src/libraries/FeeCalculator.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {HookDeployer} from "./mocks/HookDeployer.sol";

contract DynamicFeeTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

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

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price

    uint256[4] DEFAULT_THRESHOLDS = [uint256(100), 300, 500, 1000];
    uint24 constant DEFAULT_MAX_FEE = 20_000; // 200 bps

    function setUp() public {
        // Deploy PoolManager
        manager = new PoolManager(address(this));

        // Deploy routers
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Deploy oracle — 8 decimals, $3000 ETH price
        oracle = new MockOracle(8, 3000e8);

        // Deploy tokens
        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        // Mint tokens
        token0.mint(address(this), 1000e18);
        token1.mint(address(this), 1000e18);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Deploy hook to address with correct flag bits
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory creationCode =
            abi.encodePacked(type(DynamicFee).creationCode, abi.encode(manager, address(this)));
        (address hookAddr, bytes32 salt) = HookDeployer.find(address(this), flags, creationCode);

        // Deploy via CREATE2
        address deployed;
        assembly {
            deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        require(deployed == hookAddr, "Hook address mismatch");
        hook = DynamicFee(deployed);

        // Configure pool
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(60),
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        // Configure hook for this pool
        hook.configurePool(poolId, address(oracle), DEFAULT_MAX_FEE, DEFAULT_THRESHOLDS);

        // Initialize pool at 1:1 price
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Add liquidity — wide range
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 100e18, salt: 0}),
            new bytes(0)
        );
    }

    // ═══════════════════════════ Oracle Tests ═══════════════════════════

    function test_getOraclePrice_Success() public view {
        uint256 price = OracleManager.getOraclePrice(address(oracle));
        assertEq(price, 3000e18, "Price should be 3000 * 1e18");
    }

    function test_getOraclePrice_Stale() public {
        vm.warp(2 hours + 1); // ensure block.timestamp is large enough
        oracle.setStale();
        vm.expectRevert();
        this.externalGetOraclePrice(address(oracle));
    }

    function test_getOraclePrice_Invalid() public {
        oracle.setAnswer(-1);
        vm.expectRevert();
        this.externalGetOraclePrice(address(oracle));
    }

    function test_getOraclePrice_IncompleteRound() public {
        oracle.setIncompleteRound();
        vm.expectRevert();
        this.externalGetOraclePrice(address(oracle));
    }

    /// @dev External wrapper so vm.expectRevert can catch internal library reverts.
    function externalGetOraclePrice(address feed) external view returns (uint256) {
        return OracleManager.getOraclePrice(feed);
    }

    // ═══════════════════════════ Deviation Tests ═══════════════════════════

    function test_calculateDeviation() public pure {
        // Pool at 3030 vs oracle at 3000 = 1% = 100 bps
        uint256 dev = DeviationMonitor.calculateDeviation(3030e18, 3000e18);
        assertEq(dev, 100, "Deviation should be 100 bps");

        // Pool at 2850 vs oracle at 3000 = 5% = 500 bps
        dev = DeviationMonitor.calculateDeviation(2850e18, 3000e18);
        assertEq(dev, 500, "Deviation should be 500 bps");

        // Pool = oracle = 0 deviation
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

    // ═══════════════════════════ Direction Tests ═══════════════════════════

    function test_determineDirection_Toward() public pure {
        // Pool above oracle, price drops → toward
        assertEq(
            uint256(FeeCalculator.determineDirection(3100e18, 3050e18, 3000e18)),
            uint256(FeeCalculator.Direction.TOWARD)
        );
        // Pool below oracle, price rises → toward
        assertEq(
            uint256(FeeCalculator.determineDirection(2900e18, 2950e18, 3000e18)),
            uint256(FeeCalculator.Direction.TOWARD)
        );
    }

    function test_determineDirection_Away() public pure {
        // Pool above oracle, price rises → away
        assertEq(
            uint256(FeeCalculator.determineDirection(3100e18, 3150e18, 3000e18)),
            uint256(FeeCalculator.Direction.AWAY)
        );
        // Pool below oracle, price drops → away
        assertEq(
            uint256(FeeCalculator.determineDirection(2900e18, 2850e18, 3000e18)),
            uint256(FeeCalculator.Direction.AWAY)
        );
    }

    // ═══════════════════════════ Fee Calculation Tests ═══════════════════════════

    function test_calculateFee_AllCombinations() public pure {
        uint24 max = 20_000;

        // TIGHT zone
        assertEq(FeeCalculator.calculateFee(DeviationMonitor.Zone.TIGHT, FeeCalculator.Direction.TOWARD, max), 500);
        assertEq(FeeCalculator.calculateFee(DeviationMonitor.Zone.TIGHT, FeeCalculator.Direction.AWAY, max), 1000);

        // NORMAL zone
        assertEq(FeeCalculator.calculateFee(DeviationMonitor.Zone.NORMAL, FeeCalculator.Direction.TOWARD, max), 1000);
        assertEq(FeeCalculator.calculateFee(DeviationMonitor.Zone.NORMAL, FeeCalculator.Direction.AWAY, max), 3000);

        // ELEVATED zone
        assertEq(
            FeeCalculator.calculateFee(DeviationMonitor.Zone.ELEVATED, FeeCalculator.Direction.TOWARD, max), 2000
        );
        assertEq(FeeCalculator.calculateFee(DeviationMonitor.Zone.ELEVATED, FeeCalculator.Direction.AWAY, max), 5000);

        // HIGH zone
        assertEq(FeeCalculator.calculateFee(DeviationMonitor.Zone.HIGH, FeeCalculator.Direction.TOWARD, max), 3000);
        assertEq(FeeCalculator.calculateFee(DeviationMonitor.Zone.HIGH, FeeCalculator.Direction.AWAY, max), 10_000);

        // EXTREME zone
        assertEq(
            FeeCalculator.calculateFee(DeviationMonitor.Zone.EXTREME, FeeCalculator.Direction.TOWARD, max), 5000
        );
        assertEq(FeeCalculator.calculateFee(DeviationMonitor.Zone.EXTREME, FeeCalculator.Direction.AWAY, max), 20_000);
    }

    function test_fee_RespectsMaxCap() public pure {
        // Max fee = 5000 (50 bps) — EXTREME AWAY would be 20_000 but capped
        uint24 smallMax = 5000;
        uint24 fee =
            FeeCalculator.calculateFee(DeviationMonitor.Zone.EXTREME, FeeCalculator.Direction.AWAY, smallMax);
        assertEq(fee, smallMax, "Fee should be capped at maxFee");
    }

    // ═══════════════════════════ Hook Config Tests ═══════════════════════════

    function test_configurePool_OnlyOwner() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        hook.configurePool(poolId, address(oracle), DEFAULT_MAX_FEE, DEFAULT_THRESHOLDS);
    }

    function test_configurePool_InvalidOracle() public {
        vm.expectRevert(DynamicFee.InvalidOracleAddress.selector);
        hook.configurePool(poolId, address(0), DEFAULT_MAX_FEE, DEFAULT_THRESHOLDS);
    }

    function test_configurePool_InvalidThresholds() public {
        uint256[4] memory bad = [uint256(300), 100, 500, 1000]; // not ascending
        vm.expectRevert(DynamicFee.InvalidThresholds.selector);
        hook.configurePool(poolId, address(oracle), DEFAULT_MAX_FEE, bad);
    }

    // ═══════════════════════════ Swap Integration Tests ═══════════════════════════

    function test_fullSwap_AppliesFee() public {
        // Simple swap should succeed with dynamic fee applied
        BalanceDelta delta = swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            new bytes(0)
        );
        assertTrue(delta.amount0() != 0, "Swap should execute");
    }

    function test_fullSwap_BothDirections() public {
        // Swap zeroForOne
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            new bytes(0)
        );

        // Swap oneForZero
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            new bytes(0)
        );
    }

    function test_unconfiguredPool_Reverts() public {
        // Create a new pool key with a different tick spacing so it's a different pool
        PoolKey memory unconfiguredKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(10),
            hooks: IHooks(address(hook))
        });
        PoolId unconfiguredId = unconfiguredKey.toId();

        manager.initialize(unconfiguredKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            unconfiguredKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 100e18, salt: 0}),
            new bytes(0)
        );

        vm.expectRevert();
        swapRouter.swap(
            unconfiguredKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            new bytes(0)
        );
    }

    // ═══════════════════════════ Fuzz Tests ═══════════════════════════

    function testFuzz_calculateDeviation(uint256 poolPrice, uint256 oraclePrice) public pure {
        // Bound to reasonable ranges
        poolPrice = bound(poolPrice, 1e18, 1e22);
        oraclePrice = bound(oraclePrice, 1e18, 1e22);

        uint256 dev = DeviationMonitor.calculateDeviation(poolPrice, oraclePrice);
        // Max deviation is bounded: |p-o|/o * 10000. With our bounds, max ratio is 10000x → 99990000 bps
        // Just verify it doesn't revert and returns something reasonable
        assertTrue(dev <= 10_000 * 10_000, "Deviation calculation should not overflow");
    }

    function testFuzz_classifyZone(uint256 deviationBps) public pure {
        deviationBps = bound(deviationBps, 0, 50_000);
        uint256[4] memory t = [uint256(100), 300, 500, 1000];
        DeviationMonitor.Zone zone = DeviationMonitor.classifyZone(deviationBps, t);
        assertTrue(uint256(zone) <= uint256(DeviationMonitor.Zone.EXTREME));
    }

    function testFuzz_calculateFee(uint8 zoneRaw, bool isToward) public pure {
        uint8 zoneIdx = zoneRaw % 5;
        DeviationMonitor.Zone zone = DeviationMonitor.Zone(zoneIdx);
        FeeCalculator.Direction dir =
            isToward ? FeeCalculator.Direction.TOWARD : FeeCalculator.Direction.AWAY;
        uint24 fee = FeeCalculator.calculateFee(zone, dir, 20_000);
        assertTrue(fee > 0 && fee <= 20_000, "Fee should be within bounds");
    }

    // Helper to receive ETH
    receive() external payable {}
}

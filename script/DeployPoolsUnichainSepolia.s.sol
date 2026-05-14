// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {DynamicFee} from "../src/DynamicFee.sol";
import {MockToken} from "./MockToken.sol";

/// @notice Deploys mock tokens (tWETH, tUSDC, tLINK) on Unichain Sepolia,
///         configures three pools on the existing DynamicFee hook, initializes
///         each pool on the PoolManager, and seeds them with full-range
///         liquidity. Reuses Unichain Sepolia's canonical PoolModifyLiquidityTest
///         router rather than deploying a new one.
contract DeployPoolsUnichainSepolia is Script {
    using PoolIdLibrary for PoolKey;

    // Unichain Sepolia
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant LIQ_ROUTER   = 0x5fa728C0A5cfd51BEe4B060773f50554c0C8A7AB;

    // Already-deployed DynamicFee hook on Unichain Sepolia
    address constant HOOK = 0xa5eCBF949D964760f3F7805f59eb4AAc1f2500c0;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint64  constant TWAP_WINDOW    = 1 hours;

    MockToken public tWETH;
    MockToken public tUSDC;
    MockToken public tLINK;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        _deployTokens(deployer);
        _approveRouter();
        _createPools();
        vm.stopBroadcast();

        _printSummary();
    }

    function _deployTokens(address deployer) internal {
        tWETH = new MockToken("Test WETH", "tWETH", 18);
        tUSDC = new MockToken("Test USDC", "tUSDC", 18);
        tLINK = new MockToken("Test LINK", "tLINK", 18);
        tWETH.mint(deployer, 1_000_000e18);
        tUSDC.mint(deployer, 1_000_000e18);
        tLINK.mint(deployer, 1_000_000e18);
        console2.log("tWETH:", address(tWETH));
        console2.log("tUSDC:", address(tUSDC));
        console2.log("tLINK:", address(tLINK));
    }

    function _approveRouter() internal {
        tWETH.approve(LIQ_ROUTER, type(uint256).max);
        tUSDC.approve(LIQ_ROUTER, type(uint256).max);
        tLINK.approve(LIQ_ROUTER, type(uint256).max);
    }

    function _createPools() internal {
        IPoolManager manager = IPoolManager(POOL_MANAGER);
        PoolModifyLiquidityTest liq = PoolModifyLiquidityTest(LIQ_ROUTER);
        DynamicFee hook = DynamicFee(HOOK);
        uint256[4] memory t = [uint256(100), 300, 500, 1000];
        ModifyLiquidityParams memory lp = ModifyLiquidityParams({
            tickLower: -887220, tickUpper: 887220, liquidityDelta: 10_000e18, salt: bytes32(0)
        });

        PoolKey memory k1 = _key(address(tWETH), address(tUSDC));
        hook.configurePool(k1.toId(), TWAP_WINDOW, 20_000, 3000, int8(0), t);
        manager.initialize(k1, SQRT_PRICE_1_1);
        liq.modifyLiquidity(k1, lp, "");
        console2.log("ETH/USDC pool created");

        PoolKey memory k2 = _key(address(tLINK), address(tUSDC));
        hook.configurePool(k2.toId(), TWAP_WINDOW, 20_000, 3000, int8(0), t);
        manager.initialize(k2, SQRT_PRICE_1_1);
        liq.modifyLiquidity(k2, lp, "");
        console2.log("LINK/USDC pool created");

        PoolKey memory k3 = _key(address(tWETH), address(tLINK));
        hook.configurePool(k3.toId(), TWAP_WINDOW, 20_000, 3000, int8(0), t);
        manager.initialize(k3, SQRT_PRICE_1_1);
        liq.modifyLiquidity(k3, lp, "");
        console2.log("ETH/LINK pool created");
    }

    function _key(address a, address b) internal pure returns (PoolKey memory) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(60),
            hooks: IHooks(HOOK)
        });
    }

    function _printSummary() internal view {
        console2.log("");
        console2.log("=== POOL DEPLOY SUMMARY ===");
        console2.log("Network:    Unichain Sepolia (1301)");
        console2.log("Hook:      ", HOOK);
        console2.log("tWETH:     ", address(tWETH));
        console2.log("tUSDC:     ", address(tUSDC));
        console2.log("tLINK:     ", address(tLINK));
        console2.log("LiqRouter: ", LIQ_ROUTER);
        console2.log("===========================");
    }
}

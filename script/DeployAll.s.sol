// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {DynamicFee} from "../src/DynamicFee.sol";
import {MockToken} from "./MockToken.sol";
import {MockOracleDeploy} from "./MockOracleDeploy.sol";

contract DeployAll is Script {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant HOOK_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    // Deployed addresses — filled during run()
    MockToken public tWETH;
    MockToken public tUSDC;
    MockToken public tLINK;
    MockOracleDeploy public ethOracle;
    MockOracleDeploy public linkOracle;
    DynamicFee public hook;
    PoolModifyLiquidityTest public liqRouter;
    PoolSwapTest public swapRouter;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        _deployContracts(deployer);
        _createPools();
        _executeSwaps();
        vm.stopBroadcast();

        _printSummary();
    }

    function _deployContracts(address deployer) internal {
        IPoolManager manager = IPoolManager(POOL_MANAGER);

        // Mock tokens
        tWETH = new MockToken("Test WETH", "tWETH", 18);
        tUSDC = new MockToken("Test USDC", "tUSDC", 18);
        tLINK = new MockToken("Test LINK", "tLINK", 18);
        tWETH.mint(deployer, 1_000_000e18);
        tUSDC.mint(deployer, 1_000_000e18);
        tLINK.mint(deployer, 1_000_000e18);
        console2.log("tWETH:", address(tWETH));
        console2.log("tUSDC:", address(tUSDC));
        console2.log("tLINK:", address(tLINK));

        // Mock oracles
        ethOracle = new MockOracleDeploy(8, 3000e8);
        linkOracle = new MockOracleDeploy(8, 15e8);
        console2.log("ETH Oracle:", address(ethOracle));
        console2.log("LINK Oracle:", address(linkOracle));

        // Hook via CREATE2
        bytes memory code = abi.encodePacked(type(DynamicFee).creationCode, abi.encode(address(manager), deployer));
        (, bytes32 salt) = _mineSalt(CREATE2_PROXY, HOOK_FLAGS, code);
        hook = new DynamicFee{salt: salt}(manager, deployer);
        console2.log("Hook:", address(hook));

        // Routers
        liqRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
        console2.log("LiqRouter:", address(liqRouter));
        console2.log("SwapRouter:", address(swapRouter));

        // Approvals
        tWETH.approve(address(liqRouter), type(uint256).max);
        tUSDC.approve(address(liqRouter), type(uint256).max);
        tLINK.approve(address(liqRouter), type(uint256).max);
        tWETH.approve(address(swapRouter), type(uint256).max);
        tUSDC.approve(address(swapRouter), type(uint256).max);
        tLINK.approve(address(swapRouter), type(uint256).max);
    }

    function _createPools() internal {
        IPoolManager manager = IPoolManager(POOL_MANAGER);
        uint256[4] memory t = [uint256(100), 300, 500, 1000];
        ModifyLiquidityParams memory lp = ModifyLiquidityParams({
            tickLower: -887220, tickUpper: 887220, liquidityDelta: 10_000e18, salt: bytes32(0)
        });

        // Pool 1: ETH/USDC
        PoolKey memory k1 = _key(address(tWETH), address(tUSDC));
        hook.configurePool(k1.toId(), address(ethOracle), 20_000, 3000, int8(0), t);
        manager.initialize(k1, SQRT_PRICE_1_1);
        liqRouter.modifyLiquidity(k1, lp, "");
        console2.log("ETH/USDC pool created + liquidity");

        // Pool 2: LINK/USDC
        PoolKey memory k2 = _key(address(tLINK), address(tUSDC));
        hook.configurePool(k2.toId(), address(linkOracle), 20_000, 3000, int8(0), t);
        manager.initialize(k2, SQRT_PRICE_1_1);
        liqRouter.modifyLiquidity(k2, lp, "");
        console2.log("LINK/USDC pool created + liquidity");

        // Pool 3: ETH/LINK
        PoolKey memory k3 = _key(address(tWETH), address(tLINK));
        hook.configurePool(k3.toId(), address(ethOracle), 20_000, 3000, int8(0), t);
        manager.initialize(k3, SQRT_PRICE_1_1);
        liqRouter.modifyLiquidity(k3, lp, "");
        console2.log("ETH/LINK pool created + liquidity");
    }

    function _executeSwaps() internal {
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        _swapPool(address(tWETH), address(tUSDC), s, "ETH/USDC");
        _swapPool(address(tLINK), address(tUSDC), s, "LINK/USDC");
        _swapPool(address(tWETH), address(tLINK), s, "ETH/LINK");
    }

    function _swapPool(address a, address b, PoolSwapTest.TestSettings memory s, string memory label) internal {
        PoolKey memory k = _key(a, b);

        swapRouter.swap(k, SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), s, "");
        console2.log(string.concat(label, " swap 1 (small)"));

        swapRouter.swap(k, SwapParams({zeroForOne: true, amountSpecified: -10e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), s, "");
        console2.log(string.concat(label, " swap 2 (medium)"));

        swapRouter.swap(k, SwapParams({zeroForOne: false, amountSpecified: -5e18, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}), s, "");
        console2.log(string.concat(label, " swap 3 (reverse)"));
    }

    function _key(address a, address b) internal view returns (PoolKey memory) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(60),
            hooks: IHooks(address(hook))
        });
    }

    function _printSummary() internal view {
        console2.log("");
        console2.log("=== DEPLOYMENT SUMMARY ===");
        console2.log("Network:      Base Sepolia (84532)");
        console2.log("tWETH:       ", address(tWETH));
        console2.log("tUSDC:       ", address(tUSDC));
        console2.log("tLINK:       ", address(tLINK));
        console2.log("ETH Oracle:  ", address(ethOracle));
        console2.log("LINK Oracle: ", address(linkOracle));
        console2.log("Hook:        ", address(hook));
        console2.log("LiqRouter:   ", address(liqRouter));
        console2.log("SwapRouter:  ", address(swapRouter));
        console2.log("PoolManager: ", POOL_MANAGER);
        console2.log("==========================");
    }

    function _mineSalt(address deployer, uint160 flags, bytes memory bytecode)
        internal pure returns (address, bytes32)
    {
        uint160 mask = uint160(Hooks.ALL_HOOK_MASK);
        bytes32 h = keccak256(bytecode);
        for (uint256 i; i < 500_000; i++) {
            bytes32 s = bytes32(i);
            address a = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, s, h)))));
            if (uint160(a) & mask == flags) return (a, s);
        }
        revert("Salt not found");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {DynamicFee} from "../src/DynamicFee.sol";
import {MockToken} from "./MockToken.sol";

/// @notice Full DynamicFee deployment for Arc Testnet (chain id 5042002).
///
///         Uniswap v4 is not deployed on Arc testnet, so this script first
///         stands up the v4 core (PoolManager) plus the two test routers, then
///         deploys freely-mintable mock USDC (6 dp) and mock cirBTC (8 dp) to
///         mirror Circle's canonical tokens. The DynamicFee hook is mined to a
///         CREATE2 address carrying the beforeSwap/afterSwap permission bits,
///         a single USDC/cirBTC dynamic-fee pool is created and seeded with
///         full-range liquidity, and a few test swaps are run to warm the TWAP.
///
///         Arc uses USDC as its native gas token — the deployer only needs a
///         native USDC balance (from https://faucet.circle.com); no ETH.
contract DeployArc is Script {
    using PoolIdLibrary for PoolKey;

    // CREATE2 deterministic-deployment proxy — present on Arc testnet.
    address constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant HOOK_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    // 1-hour trailing TWAP window — matches the production default elsewhere.
    uint64 constant TWAP_WINDOW = 1 hours;

    // Deployed addresses — filled during run().
    PoolManager public manager;
    PoolModifyLiquidityTest public liqRouter;
    PoolSwapTest public swapRouter;
    MockToken public usdc;
    MockToken public cirBTC;
    DynamicFee public hook;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        _deployCore(deployer);
        _deployTokens(deployer);
        _deployHook(deployer);
        _createPool();
        _executeSwaps();
        vm.stopBroadcast();

        _printSummary();
    }

    function _deployCore(address deployer) internal {
        manager = new PoolManager(deployer); // protocol-fee controller = deployer
        liqRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        console2.log("PoolManager:", address(manager));
        console2.log("LiqRouter:  ", address(liqRouter));
        console2.log("SwapRouter: ", address(swapRouter));
    }

    function _deployTokens(address deployer) internal {
        usdc = new MockToken("Mock USDC", "USDC", 6);
        cirBTC = new MockToken("Mock Circle Wrapped BTC", "cirBTC", 8);
        // Mint generous raw balances for full-range liquidity + swaps (mocks
        // only). Full-range liquidityDelta of 10_000e18 pulls ~1e22 raw units
        // of each token regardless of decimals, so mint well above that.
        usdc.mint(deployer, 1e28);
        cirBTC.mint(deployer, 1e28);
        console2.log("USDC (6dp):  ", address(usdc));
        console2.log("cirBTC (8dp):", address(cirBTC));

        usdc.approve(address(liqRouter), type(uint256).max);
        cirBTC.approve(address(liqRouter), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);
        cirBTC.approve(address(swapRouter), type(uint256).max);
    }

    function _deployHook(address deployer) internal {
        bytes memory code =
            abi.encodePacked(type(DynamicFee).creationCode, abi.encode(address(manager), deployer));
        (address predicted, bytes32 salt) = _mineSalt(CREATE2_PROXY, HOOK_FLAGS, code);
        console2.log("Predicted hook:", predicted);
        hook = new DynamicFee{salt: salt}(IPoolManager(address(manager)), deployer);
        require(address(hook) == predicted, "hook address mismatch");
        console2.log("Hook:", address(hook));
    }

    function _createPool() internal {
        uint256[4] memory thresholds = [uint256(100), 300, 500, 1000];
        ModifyLiquidityParams memory lp = ModifyLiquidityParams({
            tickLower: -887220, tickUpper: 887220, liquidityDelta: 10_000e18, salt: bytes32(0)
        });

        PoolKey memory key = _key(address(usdc), address(cirBTC));

        // decimalDiff = token0Decimals - token1Decimals, by sorted pool ordering.
        int8 decimalDiff = address(usdc) < address(cirBTC) ? int8(6 - 8) : int8(8 - 6);

        hook.configurePool(key.toId(), TWAP_WINDOW, 20_000, 3000, decimalDiff, thresholds);
        manager.initialize(key, SQRT_PRICE_1_1);
        liqRouter.modifyLiquidity(key, lp, "");
        console2.log("USDC/cirBTC pool created + liquidity (decimalDiff):");
        console2.logInt(decimalDiff);
    }

    function _executeSwaps() internal {
        PoolSwapTest.TestSettings memory s =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        PoolKey memory key = _key(address(usdc), address(cirBTC));

        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            s,
            ""
        );
        console2.log("swap 1 (zeroForOne, small)");

        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -10e6, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            s,
            ""
        );
        console2.log("swap 2 (zeroForOne, medium)");

        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -5e6, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            s,
            ""
        );
        console2.log("swap 3 (oneForZero, reverse)");
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

    function _mineSalt(address deployer, uint160 flags, bytes memory bytecode)
        internal
        view
        returns (address, bytes32)
    {
        uint160 mask = uint160(Hooks.ALL_HOOK_MASK);
        bytes32 h = keccak256(bytecode);
        for (uint256 i; i < 500_000; i++) {
            bytes32 s = bytes32(i);
            address a = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, s, h)))));
            if (uint160(a) & mask == flags && a.code.length == 0) return (a, s);
        }
        revert("Salt not found");
    }

    function _printSummary() internal view {
        console2.log("");
        console2.log("=== ARC TESTNET DEPLOYMENT SUMMARY ===");
        console2.log("Network:      Arc Testnet (5042002)");
        console2.log("PoolManager: ", address(manager));
        console2.log("LiqRouter:   ", address(liqRouter));
        console2.log("SwapRouter:  ", address(swapRouter));
        console2.log("USDC (mock): ", address(usdc));
        console2.log("cirBTC(mock):", address(cirBTC));
        console2.log("Hook:        ", address(hook));
        console2.log("======================================");
    }
}

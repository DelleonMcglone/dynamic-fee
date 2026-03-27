// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {DynamicFee} from "../src/DynamicFee.sol";
import {DeviationMonitor} from "../src/libraries/DeviationMonitor.sol";
import {FeeCalculator} from "../src/libraries/FeeCalculator.sol";

/// @notice Executes test swaps on deployed pools and logs fee information.
contract TestSwap is Script {
    using PoolIdLibrary for PoolKey;

    function run() external {
        address hookAddr = vm.envAddress("HOOK_ADDRESS");
        address swapRouterAddr = vm.envAddress("SWAP_ROUTER");
        address weth = vm.envAddress("WETH");
        address usdc = vm.envAddress("USDC");

        DynamicFee hook = DynamicFee(hookAddr);

        // Build ETH/USDC pool key
        (address t0, address t1) = weth < usdc ? (weth, usdc) : (usdc, weth);
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(60),
            hooks: IHooks(hookAddr)
        });

        // Preview fees before swapping
        (uint24 feeZeroForOne, DeviationMonitor.Zone zone0, FeeCalculator.Direction dir0) =
            hook.previewFee(poolKey, true);
        (uint24 feeOneForZero, DeviationMonitor.Zone zone1, FeeCalculator.Direction dir1) =
            hook.previewFee(poolKey, false);

        console.log("=== ETH/USDC Pool ===");
        console.log("ZeroForOne fee (hundredths-bip):", feeZeroForOne);
        console.log("ZeroForOne zone:", uint256(zone0));
        console.log("ZeroForOne direction:", uint256(dir0));
        console.log("OneForZero fee (hundredths-bip):", feeOneForZero);
        console.log("OneForZero zone:", uint256(zone1));
        console.log("OneForZero direction:", uint256(dir1));

        vm.startBroadcast();

        // Small swap: sell token0
        console.log("\n--- Small Swap (0.01 ETH equivalent) ---");
        _executeSwap(swapRouterAddr, poolKey, true, -0.01 ether);

        // Medium swap
        console.log("\n--- Medium Swap (0.1 ETH equivalent) ---");
        _executeSwap(swapRouterAddr, poolKey, true, -0.1 ether);

        // Large swap
        console.log("\n--- Large Swap (1 ETH equivalent) ---");
        _executeSwap(swapRouterAddr, poolKey, true, -1 ether);

        vm.stopBroadcast();
    }

    function _executeSwap(address router, PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified) internal {
        uint160 priceLimit =
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        // Call swap on the router (interface depends on your router)
        (bool success,) = router.call(
            abi.encodeWithSignature(
                "swap((address,address,uint24,int24,address),(bool,int256,uint160),bytes)",
                poolKey,
                SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: priceLimit}),
                ""
            )
        );
        require(success, "Swap failed");
        console.log("Swap executed successfully");
    }
}

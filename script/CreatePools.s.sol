// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {DynamicFee} from "../src/DynamicFee.sol";

/// @notice Creates 3 test pools (ETH/USDC, LINK/USDC, ETH/LINK) with the DynamicFee hook.
contract CreatePools is Script {
    using PoolIdLibrary for PoolKey;

    uint256[4] internal thresholds = [uint256(100), 300, 500, 1000];
    uint24 internal constant MAX_FEE = 20_000;
    uint24 internal constant FALLBACK_FEE = 3000; // 30 bps

    function run() external {
        IPoolManager mgr = IPoolManager(vm.envAddress("POOL_MANAGER"));
        DynamicFee hook = DynamicFee(vm.envAddress("HOOK_ADDRESS"));
        IHooks hooks = IHooks(address(hook));

        address weth = vm.envAddress("WETH");
        address usdc = vm.envAddress("USDC");
        address link = vm.envAddress("LINK");

        vm.startBroadcast();

        // WETH(18dec)/USDC(6dec): decimalDiff = 12
        _createPool(mgr, hook, hooks, weth, usdc, vm.envAddress("CHAINLINK_ETH_USD"), int8(12), 4339505376871019468404402984534016);
        // LINK(18dec)/USDC(6dec): decimalDiff = 12
        _createPool(mgr, hook, hooks, link, usdc, vm.envAddress("CHAINLINK_LINK_USD"), int8(12), 316227766016837933199889);
        // WETH(18dec)/LINK(18dec): decimalDiff = 0
        _createPool(mgr, hook, hooks, weth, link, vm.envAddress("CHAINLINK_ETH_USD"), int8(0), 1371958028948904769498980352);

        vm.stopBroadcast();
    }

    function _createPool(
        IPoolManager mgr,
        DynamicFee hook,
        IHooks hooks,
        address tokenA,
        address tokenB,
        address oracleFeed,
        int8 decimalDiff,
        uint160 sqrtPrice
    ) internal {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(60),
            hooks: hooks
        });
        PoolId poolId = poolKey.toId();

        hook.configurePool(poolId, oracleFeed, MAX_FEE, FALLBACK_FEE, decimalDiff, thresholds);
        mgr.initialize(poolKey, sqrtPrice);

        console.log("Pool created. PoolId:");
        console.logBytes32(PoolId.unwrap(poolId));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {DynamicFee} from "../src/DynamicFee.sol";

/// @notice Redeploys DynamicFee hook at a fresh CREATE2 address, reusing the
///         existing tokens / oracles / routers from the prior DeployAll run.
///         Creates 3 new pools (ETH/USDC, LINK/USDC, ETH/LINK) bound to the
///         new hook and seeds them with full-range liquidity.
contract RedeployHook is Script {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER  = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant HOOK_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    address constant OLD_HOOK    = 0xB52ed7864E737C0D701dB2f741637992920600C0;
    address constant TWETH       = 0x839Cc782708f1768F0F7591eA0c7D08290ba2a3c;
    address constant TUSDC       = 0x8b6de320b93c2f8dEE5C9392A001E03CE6cc8Fe6;
    address constant TLINK       = 0x16538c37818d580F7f919D4583D7935C8624567E;
    address constant ETH_ORACLE  = 0x178eda13C9992B755940C3F85ef094b566D72099;
    address constant LINK_ORACLE = 0xcbE2770BC2c72d59b5ED8373587c69160Bf02f9C;
    address constant LIQ_ROUTER  = 0x9f12E9d064398e07153Ca7E1401C71343edB772B;

    DynamicFee public hook;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        _deployHook(deployer);
        _approveRouters();
        _createPools();
        vm.stopBroadcast();

        _printSummary();
    }

    function _deployHook(address deployer) internal {
        IPoolManager manager = IPoolManager(POOL_MANAGER);
        bytes memory code = abi.encodePacked(type(DynamicFee).creationCode, abi.encode(address(manager), deployer));
        (address predicted, bytes32 salt) = _mineSalt(CREATE2_PROXY, HOOK_FLAGS, code);
        console2.log("Predicted hook:", predicted);
        console2.log("Salt:", uint256(salt));
        require(predicted != OLD_HOOK, "predicted equals old hook");
        hook = new DynamicFee{salt: salt}(manager, deployer);
        require(address(hook) == predicted, "address mismatch");
        console2.log("Hook deployed:", address(hook));
    }

    function _approveRouters() internal {
        IERC20(TWETH).approve(LIQ_ROUTER, type(uint256).max);
        IERC20(TUSDC).approve(LIQ_ROUTER, type(uint256).max);
        IERC20(TLINK).approve(LIQ_ROUTER, type(uint256).max);
    }

    function _createPools() internal {
        IPoolManager manager = IPoolManager(POOL_MANAGER);
        PoolModifyLiquidityTest liq = PoolModifyLiquidityTest(LIQ_ROUTER);
        uint256[4] memory t = [uint256(100), 300, 500, 1000];
        ModifyLiquidityParams memory lp = ModifyLiquidityParams({
            tickLower: -887220, tickUpper: 887220, liquidityDelta: 10_000e18, salt: bytes32(0)
        });

        PoolKey memory k1 = _key(TWETH, TUSDC);
        hook.configurePool(k1.toId(), ETH_ORACLE, 20_000, 3000, int8(0), t);
        manager.initialize(k1, SQRT_PRICE_1_1);
        liq.modifyLiquidity(k1, lp, "");
        console2.log("ETH/USDC pool created");

        PoolKey memory k2 = _key(TLINK, TUSDC);
        hook.configurePool(k2.toId(), LINK_ORACLE, 20_000, 3000, int8(0), t);
        manager.initialize(k2, SQRT_PRICE_1_1);
        liq.modifyLiquidity(k2, lp, "");
        console2.log("LINK/USDC pool created");

        PoolKey memory k3 = _key(TWETH, TLINK);
        hook.configurePool(k3.toId(), ETH_ORACLE, 20_000, 3000, int8(0), t);
        manager.initialize(k3, SQRT_PRICE_1_1);
        liq.modifyLiquidity(k3, lp, "");
        console2.log("ETH/LINK pool created");
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
        internal view returns (address, bytes32)
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
        console2.log("=== REDEPLOY SUMMARY ===");
        console2.log("Network:    Base Sepolia (84532)");
        console2.log("New Hook:  ", address(hook));
        console2.log("Old Hook:  ", OLD_HOOK, "(replaced; pools bound to it remain functional but stale)");
        console2.log("=========================");
    }
}

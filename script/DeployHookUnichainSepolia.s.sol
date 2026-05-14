// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {DynamicFee} from "../src/DynamicFee.sol";

/// @notice Deploys the DynamicFee hook to Unichain Sepolia (chain id 1301).
///         Mines a CREATE2 salt whose resulting address encodes the
///         beforeSwap + afterSwap permission flags, then deploys via the
///         canonical CREATE2 factory.
contract DeployHookUnichainSepolia is Script {
    // Unichain Sepolia Uniswap v4 PoolManager
    address constant POOL_MANAGER  = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant HOOK_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    DynamicFee public hook;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        IPoolManager manager = IPoolManager(POOL_MANAGER);
        bytes memory code = abi.encodePacked(type(DynamicFee).creationCode, abi.encode(address(manager), deployer));
        (address predicted, bytes32 salt) = _mineSalt(CREATE2_PROXY, HOOK_FLAGS, code);
        console2.log("Predicted hook:", predicted);
        console2.log("Salt:", uint256(salt));

        vm.startBroadcast(pk);
        hook = new DynamicFee{salt: salt}(manager, deployer);
        vm.stopBroadcast();

        require(address(hook) == predicted, "address mismatch");

        console2.log("");
        console2.log("=== DEPLOYMENT SUMMARY ===");
        console2.log("Network:     Unichain Sepolia (1301)");
        console2.log("Hook:       ", address(hook));
        console2.log("PoolManager:", POOL_MANAGER);
        console2.log("Deployer:   ", deployer);
        console2.log("==========================");
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
}

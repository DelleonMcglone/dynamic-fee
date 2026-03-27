// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {DynamicFee} from "../src/DynamicFee.sol";

/// @notice Deploys the DynamicFee hook to an address with the correct flag bits.
///         Uses CREATE2 salt mining to ensure the address encodes the required hook permissions.
contract DeployDynamicFee is Script {
    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address owner = vm.envAddress("OWNER");

        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        uint160 flagsMask = uint160(Hooks.ALL_HOOK_MASK);

        bytes memory creationCode =
            abi.encodePacked(type(DynamicFee).creationCode, abi.encode(IPoolManager(poolManager), owner));
        bytes32 codeHash = keccak256(creationCode);

        // Mine CREATE2 salt
        address hookAddr;
        bytes32 salt;
        for (uint256 i = 0; i < 100_000; i++) {
            salt = bytes32(i);
            hookAddr = _computeCreate2(msg.sender, salt, codeHash);
            if (uint160(hookAddr) & flagsMask == flags) break;
        }
        require(uint160(hookAddr) & flagsMask == flags, "Salt mining failed");

        console.log("Deployer:", msg.sender);
        console.log("Hook will deploy to:", hookAddr);
        console.log("Salt:", uint256(salt));

        vm.startBroadcast();
        address deployed;
        assembly {
            deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        vm.stopBroadcast();

        require(deployed == hookAddr, "Deployment address mismatch");
        console.log("DynamicFee Hook deployed at:", deployed);
    }

    function _computeCreate2(address deployer, bytes32 _salt, bytes32 _codeHash)
        internal
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, _salt, _codeHash)))));
    }
}

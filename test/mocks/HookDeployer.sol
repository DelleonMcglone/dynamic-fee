// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/libraries/Hooks.sol";

/// @notice Deploys a contract to an address with the required hook flag bits set.
///         Uses CREATE2 with a salt search to find an address matching the flags.
library HookDeployer {
    /// @notice Mines a salt that produces an address with the required hook permission bits.
    /// @param deployer The address that will call CREATE2.
    /// @param flags The required hook flag bits (least-significant 14 bits of the address).
    /// @param creationCode The contract creation bytecode (including constructor args).
    /// @return hookAddress The address the contract will be deployed to.
    /// @return salt The salt to use with CREATE2.
    function find(address deployer, uint160 flags, bytes memory creationCode)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        uint160 flagsMask = uint160(Hooks.ALL_HOOK_MASK);
        bytes32 codeHash = keccak256(creationCode);

        for (uint256 i = 0; i < 100_000; i++) {
            salt = bytes32(i);
            hookAddress = _computeAddress(deployer, salt, codeHash);
            if (uint160(hookAddress) & flagsMask == flags) {
                return (hookAddress, salt);
            }
        }
        revert("HookDeployer: could not find salt");
    }

    function _computeAddress(address deployer, bytes32 salt, bytes32 codeHash)
        private
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, codeHash)))));
    }
}

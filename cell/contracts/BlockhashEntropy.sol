// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./IEntropyProvider.sol";

/// @notice Testnet-grade entropy: blockhash(n-1) mixed with salt (sequencer-influenceable).
contract BlockhashEntropy is IEntropyProvider {
    function seed(bytes32 salt) external view returns (bytes32) {
        return keccak256(abi.encode(blockhash(block.number - 1), salt));
    }
}

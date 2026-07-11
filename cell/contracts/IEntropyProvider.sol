// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @notice Swappable dispute/arbiter assignment entropy (construction-manual §6 option A).
interface IEntropyProvider {
    function seed(bytes32 salt) external view returns (bytes32);
}

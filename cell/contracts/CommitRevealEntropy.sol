// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./IEntropyProvider.sol";

/// @notice NOT MAINNET-READY — minimal test seam only.
/// @dev Placeholder commit-reveal provider for wiring/tests. Full un-influenceable CR rounds
///      are a mainnet prerequisite (see RealDeal/notebook/6-flows/book/09-mainnet-gates.md).
contract CommitRevealEntropy is IEntropyProvider {
    bytes32 public committed;
    bytes32 public revealed;
    bool public revealOpen;

    function commit(bytes32 commitment) external {
        committed = commitment;
        revealed = bytes32(0);
        revealOpen = false;
    }

    function reveal(bytes32 value, bytes32 nonce) external {
        require(keccak256(abi.encode(value, nonce)) == committed, "Commit mismatch");
        revealed = value;
        revealOpen = true;
    }

    function seed(bytes32 salt) external view returns (bytes32) {
        require(revealOpen, "Reveal pending");
        return keccak256(abi.encode(revealed, salt));
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./WithdrawCreditsV1.sol";

/// @dev Off-library probe — `type(L).runtimeCode` cannot be read from inside library L (Solc 7813).
library WithdrawCreditsV1ArtifactProbe {
    function artifactHash() public pure returns (bytes32) {
        return keccak256(type(WithdrawCreditsV1).runtimeCode);
    }
}

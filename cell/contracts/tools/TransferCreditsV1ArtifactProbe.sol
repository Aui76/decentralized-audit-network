// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./TransferCreditsV1.sol";

library TransferCreditsV1ArtifactProbe {
    function artifactHash() public pure returns (bytes32) {
        return keccak256(type(TransferCreditsV1).runtimeCode);
    }
}

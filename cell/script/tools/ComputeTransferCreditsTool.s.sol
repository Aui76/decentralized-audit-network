// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../../contracts/tools/TransferCreditsV1.sol";
import "../../contracts/tools/TransferCreditsV1ArtifactProbe.sol";

contract ComputeTransferCreditsTool is Script {
    function run() external pure {
        bytes32 probe = TransferCreditsV1ArtifactProbe.artifactHash();
        console2.log("probe runtime bytecode");
        console2.logBytes32(probe);
        console2.log("declared TOOL_ARTIFACT_HASH");
        console2.logBytes32(TransferCreditsV1.toolArtifactHash());
        console2.log("toolId transfer-credits 1.0.0");
        console2.logBytes32(TransferCreditsV1.toolId());
        console2.log("specHash");
        console2.logBytes32(TransferCreditsV1.specHash());
        console2.log("contextRoot");
        console2.logBytes32(TransferCreditsV1.contextRoot());
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../../contracts/tools/WithdrawCreditsV1.sol";
import "../../contracts/tools/WithdrawCreditsV1ArtifactProbe.sol";

/// @dev L-02 recipe: set TOOL_ARTIFACT_HASH to bytes32(0), rebuild, run once — that probe output is the normative hash.
///      After publishing the hash constant, `match` vs live probe will be false (embedded metadata); manifest uses declared constant.
contract ComputeToolArtifactHash is Script {
    function run() external pure {
        bytes32 probe = WithdrawCreditsV1ArtifactProbe.artifactHash();
        console2.log("probe (current build runtime bytecode)");
        console2.logBytes32(probe);
        console2.log("declared TOOL_ARTIFACT_HASH (zero-slot normative)");
        console2.logBytes32(WithdrawCreditsV1.toolArtifactHash());
        console2.log("toolId withdraw-credits 1.1.0");
        console2.logBytes32(WithdrawCreditsV1.toolId());
    }
}

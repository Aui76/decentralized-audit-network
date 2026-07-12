// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../../contracts/tools/WithdrawCreditsV1.sol";

/// @dev Print AUDIT_SPEC_V1 + tool constants for Life/specs/withdraw-credits-v1.md
contract ComputeSpecHash is Script {
    function run() external pure {
        console2.log("INVARIANT_WITHDRAW_DECREMENTS_CREDITS_V1");
        console2.logBytes32(WithdrawCreditsV1.specInvariantId());
        console2.log("specId genesis.spec.withdraw-credits.v1");
        console2.logBytes32(WithdrawCreditsV1.specId());
        console2.log("specHash (submitAudit)");
        console2.logBytes32(WithdrawCreditsV1.specHash());
        console2.log("toolArtifactHash (runtime bytecode, L-02)");
        console2.logBytes32(WithdrawCreditsV1.toolArtifactHash());
        console2.log("toolId (registerTool) withdraw-credits 1.1.0");
        console2.logBytes32(WithdrawCreditsV1.toolId());
        console2.log("contextRoot");
        console2.logBytes32(WithdrawCreditsV1.contextRoot());
    }
}

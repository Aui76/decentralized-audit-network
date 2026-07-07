// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "genesis-tools/AuditResultV1.sol";

/// @dev F-83 Part A: witness binding + resultRoot composition (AUDIT_RESULT_V1).
library WitnessClaimLib {
    struct Binding {
        bytes32 evaluatorToolId;
        bytes32 invariantId;
        bytes32 locationCommitment;
        bytes32 witnessCommitment;
        bytes32 contextRoot;
    }

    function findingsRoot(Binding memory b) internal pure returns (bytes32) {
        return AuditResultV1.findingsRoot(b.invariantId, b.locationCommitment, b.witnessCommitment);
    }

    function resultRoot(Binding memory b, bytes32 artifactHash, bytes32 specHash, uint8 verdict)
        internal
        pure
        returns (bytes32)
    {
        return AuditResultV1.resultRoot(
            b.evaluatorToolId, artifactHash, specHash, b.contextRoot, verdict, findingsRoot(b)
        );
    }

    function matchesResultRoot(
        bytes32 resultRoot_,
        Binding memory b,
        bytes32 artifactHash,
        bytes32 specHash,
        uint8 verdict
    ) internal pure returns (bool) {
        return resultRoot_ == resultRoot(b, artifactHash, specHash, verdict);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./WitnessClaimLib.sol";
import "genesis-tools/AuditResultV1.sol";

/// @dev F-83 Part B: non-destructive spec-adequacy overlay helpers (cathedral oracle).
library SpecGapLib {
    enum Status {
        None,
        Filed,
        Confirmed,
        False,
        Adopted,
        Declined,
        Expired
    }

    struct Record {
        address filer;
        bytes32 classId;
        bytes32 finderToolId;
        bytes32 proofHash;
        bytes32 evaluatorToolId;
        bytes32 invariantId;
        bytes32 locationCommitment;
        bytes32 witnessCommitment;
        bytes32 contextRoot;
        uint256 filedAt;
        uint256 filingStake;
        uint256 contestStake;
        Status status;
        bool exists;
    }

    function toBinding(Record storage g) internal view returns (WitnessClaimLib.Binding memory) {
        return WitnessClaimLib.Binding({
            evaluatorToolId: g.evaluatorToolId,
            invariantId: g.invariantId,
            locationCommitment: g.locationCommitment,
            witnessCommitment: g.witnessCommitment,
            contextRoot: g.contextRoot
        });
    }

    function witnessFailAtOpenMemory(
        bytes32 resultRoot,
        Record memory draft,
        bytes32 artifactHash,
        bytes32 specHash
    ) internal pure returns (bool) {
        if (draft.witnessCommitment == bytes32(0)) return false;
        WitnessClaimLib.Binding memory b = WitnessClaimLib.Binding({
            evaluatorToolId: draft.evaluatorToolId,
            invariantId: draft.invariantId,
            locationCommitment: draft.locationCommitment,
            witnessCommitment: draft.witnessCommitment,
            contextRoot: draft.contextRoot
        });
        return WitnessClaimLib.matchesResultRoot(
            resultRoot, b, artifactHash, specHash, AuditResultV1.VERDICT_FAIL
        );
    }

    function witnessFailAtOpen(
        bytes32 resultRoot,
        Record storage draft,
        bytes32 artifactHash,
        bytes32 specHash
    ) internal view returns (bool) {
        if (draft.witnessCommitment == bytes32(0)) return false;
        WitnessClaimLib.Binding memory b = WitnessClaimLib.Binding({
            evaluatorToolId: draft.evaluatorToolId,
            invariantId: draft.invariantId,
            locationCommitment: draft.locationCommitment,
            witnessCommitment: draft.witnessCommitment,
            contextRoot: draft.contextRoot
        });
        return WitnessClaimLib.matchesResultRoot(
            resultRoot, b, artifactHash, specHash, AuditResultV1.VERDICT_FAIL
        );
    }

    function disputeFailReplay(
        bytes32 resultRoot,
        bool passVerdict,
        Record storage g,
        bytes32 artifactHash,
        bytes32 specHash
    ) internal view returns (bool) {
        WitnessClaimLib.Binding memory b = toBinding(g);
        return !passVerdict
            && WitnessClaimLib.matchesResultRoot(
                resultRoot, b, artifactHash, specHash, AuditResultV1.VERDICT_FAIL
            );
    }

    function disputePassReplay(
        bytes32 resultRoot,
        bool passVerdict,
        Record storage g,
        bytes32 artifactHash,
        bytes32 specHash
    ) internal view returns (bool) {
        WitnessClaimLib.Binding memory b = toBinding(g);
        return passVerdict
            && WitnessClaimLib.matchesResultRoot(
                resultRoot, b, artifactHash, specHash, AuditResultV1.VERDICT_PASS
            );
    }
}

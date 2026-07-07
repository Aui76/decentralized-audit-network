// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @dev Deterministic run bindings (declare + re-run). Shared by cell + L1 modules; not deployed on L0.
library RunDigests {
    function specRunDigest(bytes32 specHash, bytes32 specToolId, bool pass, bytes32 errorsRoot)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "AUDIT_SPEC_RUN_V1",
                specHash,
                specToolId,
                pass ? bytes1(0x01) : bytes1(0x00),
                errorsRoot
            )
        );
    }

    function verdictRunDigest(uint256 auditId, bytes32 toolId, bool pass, bytes32 resultRoot)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "AUDIT_VERDICT_RUN_V1",
                auditId,
                toolId,
                pass ? bytes1(0x01) : bytes1(0x00),
                resultRoot
            )
        );
    }

    function claimRunDigest(uint256 originalAuditId, bytes32 toolId, bytes32 resultRoot)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked("AUDIT_CLAIM_RUN_V1", originalAuditId, toolId, resultRoot));
    }
}

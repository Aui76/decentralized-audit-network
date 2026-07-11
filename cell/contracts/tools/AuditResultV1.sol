// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @dev Canonical AUDIT_RESULT_V1 encoding (LOCKED). See Genesis/audit-result-v1.md.
library AuditResultV1 {
    bytes32 internal constant DOMAIN = keccak256("AUDIT_RESULT_V1");
    bytes32 internal constant TOOL_DOMAIN = keccak256("AUDIT_TOOL_V1");
    bytes32 internal constant CONTEXT_DOMAIN = keccak256("AUDIT_CONTEXT_V1");
    bytes32 internal constant FINDINGS_DOMAIN = keccak256("AUDIT_FINDINGS_V1");

    uint8 internal constant VERDICT_PASS = 1;
    uint8 internal constant VERDICT_FAIL = 0;

    function toolId(
        string memory toolName,
        string memory toolVersion,
        bytes32 toolArtifactHash,
        string memory entrypoint
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(TOOL_DOMAIN, toolName, toolVersion, toolArtifactHash, entrypoint));
    }

    function contextRoot(
        string memory solcVersion,
        string memory evmVersion,
        uint256 optimizerRuns,
        bool viaIR,
        bytes32 toolConfigRoot,
        bytes32 seed
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(CONTEXT_DOMAIN, solcVersion, evmVersion, optimizerRuns, viaIR, toolConfigRoot, seed)
        );
    }

    function findingsRoot(bytes32 invariantId, bytes32 locationCommitment, bytes32 witnessCommitment)
        internal
        pure
        returns (bytes32)
    {
        bytes32 leaf = keccak256(abi.encode(invariantId, locationCommitment, witnessCommitment));
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = leaf;
        return keccak256(abi.encode(FINDINGS_DOMAIN, leaves));
    }

    function resultRoot(
        bytes32 toolId_,
        bytes32 artifactHash,
        bytes32 specHash,
        bytes32 contextRoot_,
        uint8 verdict,
        bytes32 findingsRoot_
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN, toolId_, artifactHash, specHash, contextRoot_, verdict, findingsRoot_)
        );
    }
}

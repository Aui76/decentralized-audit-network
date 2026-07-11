// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @dev Canonical AUDIT_CASE_V1 encoding — mirrors AuditCell._caseRootFromInputs for off-chain tests/tools.
library AuditCaseV1 {
    bytes32 internal constant DOMAIN = keccak256("AUDIT_CASE_V1");

    function sortToolIds(bytes32[] memory toolIds) internal pure returns (bytes32[] memory sorted) {
        sorted = toolIds;
        uint256 n = sorted.length;
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                if (sorted[i] > sorted[j]) {
                    bytes32 tmp = sorted[i];
                    sorted[i] = sorted[j];
                    sorted[j] = tmp;
                }
            }
        }
    }

    function caseRoot(
        bytes32 artifactHash,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specPassDigest,
        bytes32[] memory toolIdsSortedAscending
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN, artifactHash, specHash, specToolId, specPassDigest, toolIdsSortedAscending)
        );
    }
}

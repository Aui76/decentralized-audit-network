// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @dev F-83 / P1: witness + legacy claim/dispute settlement lives off-cell for EIP-170 headroom.
interface IClaimDisputeModule {
    function wire(address cell) external;

    function claimVulnerability(
        address claimant,
        uint256 originalAuditId,
        bytes32 toolId,
        bytes32 resultRoot,
        bytes calldata proof,
        bytes32 evaluatorToolId,
        bytes32 invariantId,
        bytes32 locationCommitment,
        bytes32 witnessCommitment,
        bytes32 contextRoot,
        bytes32 vulnerabilityClassId
    ) external;

    function resolveFromDispute(uint256 originalId, uint256 disputeId) external;

    function openDisputeReaudit(uint256 originalId, uint256 disputeBounty) external returns (uint256 disputeId);

    function protocolDeclineDisputeFunding(uint256 originalId) external;

    function claimantOpenDisputeReaudit(uint256 originalId, uint256 disputeBounty)
        external
        returns (uint256 disputeId);

    function claimantDisputeLaneOpen(uint256 originalId) external view returns (bool);

    function expireDispute(uint256 originalId) external;
}

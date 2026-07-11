// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @dev Cell mutators for ClaimDisputeModule — views use AuditCell public getters.
interface IClaimSettlementMutator {
    struct ClaimInput {
        address claimant;
        bytes32 toolId;
        bytes32 proofHash;
        uint256 stake;
        bool witnessPath;
        bytes32 evaluatorToolId;
        bytes32 invariantId;
        bytes32 locationCommitment;
        bytes32 witnessCommitment;
        bytes32 contextRoot;
    }

    function isDeclaredVerdictTool(uint256 auditId, bytes32 toolId) external view returns (bool);

    function settlementApplyClaimFiled(uint256 originalAuditId, ClaimInput calldata claim) external;

    function settlementResolveClaim(
        uint256 originalId,
        address claimant,
        uint256 amount,
        bool vindicated,
        bool slashAuditorFailed
    ) external;

    function settlementClearDispute(uint256 originalId) external;

    /// @param op 0 = pull stake, 1 = refund, 2 = slash to escrow (spec-gap / spec-arbiter / integrity module).
    function settlementToken(uint8 op, address from, address to, uint256 amount) external;

    function settlementPayDiscoverer(
        uint256 originalAuditId,
        address claimant,
        uint256 escrowDraw,
        bool bountyPotLocked,
        uint256 bounty
    ) external returns (uint256 paid);

    function spawnDisputeReaudit(
        uint256 originalId,
        uint256 disputeBounty,
        address lastDiscoverer,
        address extraExclude,
        bytes32 requiredTool,
        address resolverModule
    ) external returns (uint256 disputeId);

    function settlementExpireClaimDispute(uint256 originalId) external;

    /// @dev kind 0 = spec challenge, 1 = integrity review; op 0 = lock, 1 = unlock, 2 = void.
    function settlementOverlay(uint8 kind, uint8 op, uint256 auditId, address aux) external;
}

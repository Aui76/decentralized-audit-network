// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @dev Token surface used by cell storage layout (minimal bind).
interface IAuditTokenStorage {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @dev Shared types + errors inherited by AuditCell so `AuditCell.AuditState` references stay stable.
abstract contract CellTypeDefs {
    enum AuditState {
        None,
        Submitted,
        Assigned,
        InAudit,
        AwaitingWindow,
        Audited,
        InBlock,
        Claimed,
        Exploited,
        Invalidated
    }

    struct Audit {
        address protocol;
        address auditor;
        address deployedAddress;
        uint256 bounty;
        uint256 windowStart;
        uint256 auditWindow;
        AuditState state;
        bytes32 specHash;
        bytes32 artifactHash;
        bytes32 specToolId;
        bytes32 specPassDigest;
        bool specAuditorAttested;
        uint256 pickupTime;
        bool isVulnerabilityReport;
        bool isClaimDispute;
        uint256 linkedAuditId;
        AuditState stateBeforeClaim;
        address lastDiscoverer;
        bool protocolApprovedAssignment;
        uint8 protocolRejectCount;
        bytes32 caseRoot;
        uint256 supersedesAuditId;
        bool bountyEscrowed;
        /// @dev G-30 reserve (DEC-18/DEC-22, 2026-07-08): chain the audit target lives on.
        ///      0 = home chain (this cell's chainid) — no write path sets it today, by design;
        ///      only a future foreign-target seam writes nonzero. Storage-layout reserve:
        ///      un-addable post-freeze, which is the whole reason it ships on this deployment.
        ///      Read via getAudit(id).targetChainId (raw; 0 = home chain), normalized off-chain
        ///      (the on-chain auditTargetChainId view was removed 2026-07-10 for EIP-170 headroom).
        uint256 targetChainId;
    }

    struct ProtocolRecord {
        uint256 successful;
        uint256 exploited;
        uint256 auditorAssignmentsOffered;
        uint256 auditorAssignmentsRejected;
        uint256 auditorAssignmentsAccepted;
    }

    struct AuditorRecord {
        uint256 successful;
        uint256 failed;
        uint256 found;
        uint256 position;
        uint256 timeoutStreak;
        bool inQueue;
    }

    struct Tool {
        address proposer;
        bool isSpecValidationTool;
        bool isInvariantEvaluator;
        bool canonical;
        bool exists;
        uint256 successfulUses;
        uint256 failedUses;
    }

    struct VulnerabilityClaim {
        address claimant;
        bytes32 toolId;
        bytes32 proofHash;
        uint256 claimTimestamp;
        uint256 stake;
        bool resolved;
        bool exists;
        bool witnessPath;
        bytes32 evaluatorToolId;
        bytes32 invariantId;
        bytes32 locationCommitment;
        bytes32 witnessCommitment;
        bytes32 contextRoot;
    }
}

/// @title CellStorage — AppStorage layout for AuditCell.
/// @notice Stateless library invariant: never selfdestruct. `STORAGE_SLOT` is frozen with the cell;
///         linked `CellLogicLib` reads this layout by reference via delegatecall.
library CellStorage {
    bytes32 internal constant STORAGE_SLOT = keccak256("audit.cell.storage.v1");

    struct Layout {
        IAuditTokenStorage token;
        address admin;
        address treasuryEscrow;
        address claimVerifier;
        bool claimVerifierLocked;
        address issuanceModule;
        bool issuanceModuleLocked;
        address claimDisputeModule;
        address specGapModule;
        address specArbiterModule;
        address integrityReviewModule;
        address structuralUpgradeModule;
        address assignmentModule;
        bool assignmentModuleLocked;
        mapping(uint256 => address) disputeExtraExclude;
        mapping(uint256 => bytes32) disputeRequiredTool;
        mapping(uint256 => address) disputeResolver;
        uint256 nextAuditId;
        uint256 auditorCount;
        mapping(uint256 => CellTypeDefs.Audit) audits;
        mapping(address => CellTypeDefs.AuditorRecord) auditors;
        mapping(address => CellTypeDefs.ProtocolRecord) protocols;
        mapping(bytes32 => CellTypeDefs.Tool) tools;
        mapping(uint256 => CellTypeDefs.VulnerabilityClaim) vulnerabilityClaims;
        mapping(uint256 => bytes32[4]) declaredVerdictTools;
        mapping(uint256 => uint8) declaredVerdictToolLen;
        mapping(uint256 => uint256) activeFixAuditId;
        mapping(uint256 => uint256) activeDisputeAuditId;
        mapping(uint256 => bool) auditVerdictPass;
        mapping(bytes32 => bool) artifactRegistered;
        mapping(bytes32 => uint256) artifactToAuditId;
        mapping(bytes32 => bool) caseRootRegistered;
        mapping(bytes32 => uint256) caseRootToAuditId;
        address queueHead;
        address queueTail;
        uint256 queueLength;
        mapping(address => address) queueNext;
        mapping(address => address) queuePrev;
        uint256 blockHeight;
        uint256 totalSuccessfulAudits;
        bool genesisPending;
        bool genesisAuditOpen;
        uint256 genesisAuditId;
        bytes32 latestBlockHash;
        mapping(uint256 => uint256) auditBlockRewardMinted;
        mapping(uint256 => uint256) auditPositiveBlock;
        mapping(uint256 => bytes32) auditProofHash;
        mapping(uint256 => bytes32) auditVerdictToolId;
        uint256 increment;
        bool incrementLocked;
        uint256 maxBountyPerSubmit;
        bool maxBountyPerSubmitLocked;
        uint256 currentBlockSize;
        uint256 canonicalThreshold;
        uint256 minAuditWindow;
        uint256 decisionWindow;
        uint256 protocolDecisionWindow;
        uint256 claimResolutionWindow;
        uint256 claimFilingStake;
        uint256 claimStakeBps;
        uint256 inAuditWindow;
        uint256 pushOutThreshold;
        uint256 maxBoostFactor;
        uint256 discoveryCapBps;
        uint256 discoveryFloorBps;
        uint256 paramLocked;
        address entropyProvider;
        bool entropyProviderLocked;
        // G-19 re-key (2026-07-08): canonization trigger = distinct ESTABLISHED protocols, not raw uses.
        // Written only by ToolUseLib (delegatecall). canonicalThreshold is re-denominated accordingly.
        mapping(bytes32 => mapping(address => bool)) toolProtocolCounted;
        mapping(bytes32 => uint256) toolDistinctEstablishedUses;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }
}

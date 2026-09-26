// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./CellStorage.sol";
import "./IAssignmentModule.sol";
import "./AssignmentEntropyLib.sol";
import "./ToolUseLib.sol";

interface IIntegrityReviewGateLib {
    function confirmBlocked(uint256 auditId) external view returns (bool);
}

interface ISpecChallengeGateLib {
    function challengeActive(uint256 auditId) external view returns (bool);
}

interface IStructuralCellHookLib {
    function onStructuralCellHook(uint8 phase, uint256 id, bytes32 tool) external;
}

interface IStructuralKindLib {
    function isStructuralAudit(uint256 auditId) external view returns (bool);
}

interface IIssuanceModuleLib {
    function settlePositiveBlock(uint256 id, address auditor, address protocol, uint256 rawBounty)
        external
        returns (uint256 auditorMinted, uint256 treasuryMinted, uint256 reward);
    function nextPositiveBlockReward() external view returns (uint256);
    function mintToolCanonization(address to) external returns (uint256);
}

interface ITreasuryEscrowLib {
    function recordDeposit(uint256 amount) external;
}

interface IClaimDisputeAssignmentGate {
    function disputeCandidateBlocked(
        address claimant,
        address protocol,
        address auditor,
        uint256 queueLength
    ) external view returns (bool blocked);
}

interface IDisputeResolverLib {
    function resolveFromDispute(uint256 originalId, uint256 disputeAuditId) external;
}

/// @title CellLogicLib — linked delegatecall logic for AuditCell hot paths.
/// @notice Stateless: only reads/writes via `CellStorage.layout()`. Never selfdestruct.
library CellLogicLib {
    error NotAdmin();
    error ResultRootRequired();
    error NotAuditor();
    error SelfAuditDisallowed();
    error InsufficientHold();
    error WrongState();
    error InAuditWindowPassed();
    error NotGenesisAuditor();
    error DisputeReleasable();
    error ZeroThreshold();
    error SpecNotAttested();
    error SpecChallengeActive();
    error IntegrityReviewActive();
    error SingleToolPerVerdict();
    error ToolNotRegistered();
    error SpecToolNotForVerdict();
    error ToolNotDeclared();
    error DisputeToolMismatch();
    error ClaimAlreadyExists();
    error StakeTransferFailed();
    error NotAwaiting();
    error AuditWindowOpen();
    error BountyPayoutFailed();
    error NotAssigned();
    error OnlyProtocol();
    error SkipsProtocolGate();
    error AlreadyAccepted();
    error ProtocolWindowActive();
    error NotInDecisionWindow();
    error NotAssignedAuditor();
    error DecisionWindowPassed();
    error RejectCapReached();

    uint256 internal constant MAX_PROTOCOL_REJECTS_CAP = 5;
    uint256 internal constant PROTOCOL_EXPLOITED_REJECT_GRACE = 5;
    uint256 internal constant MAX_DISPUTE_SCAN = 256; // gas bound; matches AssignmentModule.MAX_SCAN

    event ProtocolAuditorRejected(uint256 indexed id, address indexed auditor);
    event ProtocolAuditorAccepted(uint256 indexed id, address indexed auditor);
    event ProtocolDecisionTimedOut(uint256 indexed id, address indexed auditor);
    event AuditDeclined(uint256 indexed id, address indexed auditor);

    event AuditStateChanged(
        uint256 indexed auditId,
        bytes32 indexed caseRoot,
        CellTypeDefs.AuditState from,
        CellTypeDefs.AuditState to
    );
    event AuditAssigned(uint256 indexed id, address indexed auditor);
    event AuditAwaitingAssignment(uint256 indexed id);
    event VerdictSubmitted(uint256 indexed id, bool pass, bytes32 indexed toolId, bytes32 proofHash);
    event VulnerabilityClaimed(
        uint256 indexed id, address indexed claimant, bytes32 indexed toolId, bytes32 proofHash, uint256 stake
    );
    event AuditConfirmed(uint256 indexed id);
    event PositiveBlockMinted(uint256 indexed height, uint256 indexed auditId, uint256 reward, bytes32 blockHash);
    event PositiveBlockSupplyExhausted(uint256 indexed height, uint256 indexed auditId);
    event ToolCanonized(bytes32 indexed toolId);
    event ToolCanonizationRewarded(
        bytes32 indexed toolId, address indexed proposer, uint256 reward, bytes32 blockHash
    );
    event ToolUseRecorded(bytes32 indexed toolId, uint256 indexed auditId, bool successful);
    event AuditCasePinned(
        uint256 indexed auditId,
        bytes32 indexed caseRoot,
        bytes32 specHash,
        bytes32 artifactHash,
        uint256 linkedAuditId,
        bool isVulnerabilityReport,
        bool isClaimDispute,
        uint256 supersedesAuditId
    );

    // ------------------------------------------------------------------ views

    function requiredHold(CellStorage.Layout storage L, address auditor) internal view returns (uint256) {
        CellTypeDefs.AuditorRecord memory r = L.auditors[auditor];
        if (r.position == 0) {
            return L.auditorCount * L.increment;
        }
        return (r.position - 1) * L.increment;
    }

    function isEligible(CellStorage.Layout storage L, address auditor) internal view returns (bool) {
        return L.token.balanceOf(auditor) >= requiredHold(L, auditor);
    }

    function isDeclaredVerdictTool(CellStorage.Layout storage L, uint256 auditId, bytes32 toolId)
        internal
        view
        returns (bool)
    {
        uint256 n = L.declaredVerdictToolLen[auditId];
        bytes32[4] storage slots = L.declaredVerdictTools[auditId];
        for (uint256 i = 0; i < n; i++) {
            if (slots[i] == toolId) return true;
        }
        return false;
    }

    function isDeclaredVerdictToolView(uint256 auditId, bytes32 toolId) external view returns (bool) {
        return isDeclaredVerdictTool(CellStorage.layout(), auditId, toolId);
    }

    function isStructuralAudit(CellStorage.Layout storage L, uint256 id) internal view returns (bool) {
        address m = L.structuralUpgradeModule;
        return m != address(0) && IStructuralKindLib(m).isStructuralAudit(id);
    }

    function computeClaimStake(CellStorage.Layout storage L, uint256 bounty) internal view returns (uint256) {
        uint256 scaled = (bounty * L.claimStakeBps) / 10_000;
        return scaled > L.claimFilingStake ? scaled : L.claimFilingStake;
    }

    function requiredClaimStakeView(uint256 auditId) external view returns (uint256) {
        CellStorage.Layout storage L = CellStorage.layout();
        return computeClaimStake(L, L.audits[auditId].bounty);
    }

    // ------------------------------------------------------------------ queue

    function appendToQueue(CellStorage.Layout storage L, address a) internal {
        L.queueNext[a] = address(0);
        L.queuePrev[a] = L.queueTail;
        if (L.queueTail == address(0)) {
            L.queueHead = a;
        } else {
            L.queueNext[L.queueTail] = a;
        }
        L.queueTail = a;
        L.queueLength += 1;
    }

    function removeFromQueue(CellStorage.Layout storage L, address a) internal {
        address p = L.queuePrev[a];
        address n = L.queueNext[a];
        if (p == address(0)) {
            L.queueHead = n;
        } else {
            L.queueNext[p] = n;
        }
        if (n == address(0)) {
            L.queueTail = p;
        } else {
            L.queuePrev[n] = p;
        }
        L.queueNext[a] = address(0);
        L.queuePrev[a] = address(0);
        L.queueLength -= 1;
    }

    function moveToTail(CellStorage.Layout storage L, address a) internal {
        if (a == L.queueTail) return;
        removeFromQueue(L, a);
        L.auditors[a].inQueue = true;
        appendToQueue(L, a);
    }

    function findEligibleAuditor(CellStorage.Layout storage L, uint256 auditId) internal returns (address) {
        address protocol = L.audits[auditId].protocol;
        address chosen = address(0);
        if (L.assignmentModule != address(0)) {
            chosen = IAssignmentModule(L.assignmentModule).pickOrdinary(auditId, protocol);
        }
        // PC-95(1) (G5, I5): VALIDATE THE MODULE'S PICK, exactly as the fallback scan below validates its own candidate.
        // The module is admin-set and lockable, so this is defence in depth - but a pick the cell does not check is a pick
        // the cell has delegated its own eligibility rules to, and an unregistered, ineligible or self-dealing address
        // took the row on the module's word alone. A bad pick now falls through to the scan rather than standing.
        if (
            chosen != address(0) && chosen != protocol && L.auditors[chosen].inQueue && isEligible(L, chosen)
        ) {
            return chosen;
        }
        uint256 scanned = 0;
        uint256 startLen = L.queueLength;
        while (scanned < startLen && L.queueHead != address(0)) {
            address candidate = L.queueHead;
            if (candidate == protocol) {
                moveToTail(L, candidate);
                scanned += 1;
                continue;
            }
            if (isEligible(L, candidate)) {
                return candidate;
            }
            moveToTail(L, candidate);
            scanned += 1;
        }
        return address(0);
    }

    function _disputeAssignmentSeed(CellStorage.Layout storage L, uint256 disputeId) internal view returns (bytes32) {
        CellTypeDefs.Audit storage a = L.audits[disputeId];
        bytes32 entropyWord = blockhash(block.number - 1);
        if (L.entropyProvider != address(0)) {
            bytes32 salt = keccak256(
                abi.encode(
                    "AUDIT_ASSIGN_V1",
                    disputeId,
                    a.protocol,
                    bytes32(0),
                    L.queueLength,
                    L.totalSuccessfulAudits
                )
            );
            entropyWord = AssignmentEntropyLib.providerSeed(L.entropyProvider, salt);
        }
        return keccak256(
            abi.encode(
                "AUDIT_ASSIGN_V1",
                disputeId,
                a.protocol,
                bytes32(0),
                entropyWord,
                L.queueLength,
                L.totalSuccessfulAudits
            )
        );
    }

    function isDisputeCandidate(
        CellStorage.Layout storage L,
        address candidate,
        uint256 originalId,
        address extraExclude,
        address extraExclude2
    ) internal view returns (bool) {
        if (candidate == address(0) || !L.auditors[candidate].inQueue || !isEligible(L, candidate)) {
            return false;
        }
        CellTypeDefs.Audit storage orig = L.audits[originalId];
        CellTypeDefs.VulnerabilityClaim storage claim = L.vulnerabilityClaims[originalId];
        if (
            candidate == orig.protocol || candidate == orig.auditor || candidate == claim.claimant
                || candidate == extraExclude || (extraExclude2 != address(0) && candidate == extraExclude2)
        ) {
            return false;
        }
        if (
            L.claimDisputeModule != address(0)
                && IClaimDisputeAssignmentGate(L.claimDisputeModule).disputeCandidateBlocked(
                    claim.claimant, orig.protocol, candidate, L.queueLength
                )
        ) {
            return false;
        }
        return true;
    }

    function findDisputeAuditor(
        CellStorage.Layout storage L,
        uint256 disputeId,
        uint256 originalId,
        address extraExclude,
        address extraExclude2
    ) internal view returns (address) {
        bytes32 seed = _disputeAssignmentSeed(L, disputeId);
        address chosen = address(0);
        uint256 eligibleCount = 0;
        address cursor = L.queueHead;
        uint256 scanned = 0;
        uint256 maxScan = L.queueLength;
        if (maxScan > MAX_DISPUTE_SCAN) maxScan = MAX_DISPUTE_SCAN;
        while (cursor != address(0) && scanned < maxScan) {
            if (isDisputeCandidate(L, cursor, originalId, extraExclude, extraExclude2)) {
                eligibleCount += 1;
                if (uint256(keccak256(abi.encode(seed, eligibleCount))) % eligibleCount == eligibleCount - 1) {
                    chosen = cursor;
                }
            }
            cursor = L.queueNext[cursor];
            scanned += 1;
        }
        return chosen;
    }

    // ------------------------------------------------------------------ state helpers

    function _requireNoSettlementBlock(CellStorage.Layout storage L, uint256 id) internal view {
        if (L.specArbiterModule != address(0) && ISpecChallengeGateLib(L.specArbiterModule).challengeActive(id)) {
            revert SpecChallengeActive();
        }
        if (L.integrityReviewModule != address(0) && IIntegrityReviewGateLib(L.integrityReviewModule).confirmBlocked(id)) {
            revert IntegrityReviewActive();
        }
    }

    /// @dev SIBLING of `_requireNoSettlementBlock`, for the ESCALATION site (`spawnDisputeReaudit`) ONLY (VD-90).
    ///      The composite guard above asks "is ANY settlement overlay active on this row"; at the spawn site its
    ///      purpose is to SERIALIZE OVERLAYS AGAINST EACH OTHER. An overlay escalating its OWN review is not a
    ///      second proceeding - it is the same proceeding continuing, and after the spawn there is still exactly
    ///      one. So this skips the block OWNED BY `caller` and enforces every FOREIGN one. Symmetric by
    ///      construction: any overlay may escalate through its own block; NONE through another's.
    ///
    ///      WHY NOT A `msg.sender` CARVE-OUT INSIDE THE HELPER ABOVE: that helper also serves `confirmAudit`,
    ///      `acceptAuditExt`, `submitVerdictAfterProof` and `settlementApplyClaimFiled`. A caller exemption
    ///      placed inside it would exempt the module EVERYWHERE - far wider than the need. WHY NOT A SECOND
    ///      `spawnBlocked` STATE PREDICATE: it would agree with `confirmBlocked` in every state at every moment
    ///      except the transient instant the owning module escalates, so the distinguishing fact is WHO IS
    ///      CALLING, not what state the row is in. `caller` is authenticated by the call site's own gate.
    function _requireNoForeignSettlementBlock(CellStorage.Layout storage L, uint256 id, address caller)
        internal
        view
    {
        address specArbiter = L.specArbiterModule;
        if (
            specArbiter != address(0) && caller != specArbiter
                && ISpecChallengeGateLib(specArbiter).challengeActive(id)
        ) {
            revert SpecChallengeActive();
        }
        address integrityReview = L.integrityReviewModule;
        if (
            integrityReview != address(0) && caller != integrityReview
                && IIntegrityReviewGateLib(integrityReview).confirmBlocked(id)
        ) {
            revert IntegrityReviewActive();
        }
    }

    /// @dev F-CELL-3 / G7: release one-shot genesis slot on terminal non-confirm exit; `genesisPending` clears only on confirm.
    function _releaseGenesisIfOpen(CellStorage.Layout storage L, uint256 id) internal {
        if (id == L.genesisAuditId) {
            L.genesisAuditId = 0;
            L.genesisAuditOpen = false;
        }
    }

    function _setAuditState(CellStorage.Layout storage L, uint256 id, CellTypeDefs.AuditState newState) internal {
        CellTypeDefs.Audit storage a = L.audits[id];
        CellTypeDefs.AuditState from = a.state;
        if (from == newState) return;
        a.state = newState;
        if (newState == CellTypeDefs.AuditState.Exploited || newState == CellTypeDefs.AuditState.Invalidated) {
            _releaseGenesisIfOpen(L, id);
        }
        emit AuditStateChanged(id, a.caseRoot, from, newState);
    }

    function _structuralHook(CellStorage.Layout storage L, uint8 phase, uint256 id, bytes32 tool) internal {
        address m = L.structuralUpgradeModule;
        if (m == address(0)) return;
        IStructuralCellHookLib(m).onStructuralCellHook(phase, id, tool);
    }

    function _assignNext(CellStorage.Layout storage L, uint256 id) internal {
        CellTypeDefs.Audit storage a = L.audits[id];
        address chosen;
        if (a.isClaimDispute) {
            chosen = findDisputeAuditor(L, id, a.linkedAuditId, L.disputeExtraExclude[id], L.disputeExtraExclude2[id]);
        } else {
            chosen = findEligibleAuditor(L, id);
        }

        if (chosen == address(0)) {
            _setAuditState(L, id, CellTypeDefs.AuditState.Submitted);
            a.auditor = address(0);
            a.pickupTime = 0;
            emit AuditAwaitingAssignment(id);
            return;
        }

        a.auditor = chosen;
        a.pickupTime = block.timestamp;
        _setAuditState(L, id, CellTypeDefs.AuditState.Assigned);
        a.protocolApprovedAssignment =
            a.isVulnerabilityReport || a.isClaimDispute || isStructuralAudit(L, id);
        if (!a.isVulnerabilityReport && !a.isClaimDispute && !isStructuralAudit(L, id)) {
            L.protocols[a.protocol].auditorAssignmentsOffered += 1;
        }

        moveToTail(L, chosen);
        emit AuditAssigned(id, chosen);
    }

    // ------------------------------------------------------------------ linked external stubs (delegatecall from cell)

    function setAuditStateExt(uint256 id, CellTypeDefs.AuditState newState) external {
        _setAuditState(CellStorage.layout(), id, newState);
    }

    function assignNextExt(uint256 id) external {
        _assignNext(CellStorage.layout(), id);
    }

    function appendToQueueExt(address a) external {
        appendToQueue(CellStorage.layout(), a);
    }

    function removeFromQueueExt(address a) external {
        removeFromQueue(CellStorage.layout(), a);
    }

    function requireNoSettlementBlockExt(uint256 id) external view {
        _requireNoSettlementBlock(CellStorage.layout(), id);
    }

    // ------------------------------------------------------------------ dispute spawn intake

    /// @dev Shared field-wise intake for dispute rows. No bounty transfer here: the spawning module pulled the funds into
    ///      the cell BEFORE the spawn, so the row is escrowed from birth (G1, VD-199 D1 option A).
    function initDisputeRow(
        CellStorage.Layout storage L,
        CellTypeDefs.Audit storage orig,
        uint256 originalId,
        uint256 disputeBounty,
        address lastDiscoverer
    ) internal returns (uint256 id) {
        id = L.nextAuditId++;
        CellTypeDefs.Audit storage a = L.audits[id];
        a.protocol = orig.protocol;
        a.auditor = address(0);
        a.deployedAddress = orig.deployedAddress;
        a.bounty = disputeBounty;
        // PC-87 (G1, VD-199 D1 option A): THE CELL PAYS A DISPUTE ROW'S BOUNTY AT CONFIRM. Unset, `confirmAudit`'s
        // `if (a.bountyEscrowed)` skipped it, neither resolver touched it, and every verdicted dispute left the bounty in
        // the cell owed to no one while the drawn auditor worked unpaid (DisputeBountyStranded.t.sol, 2026-09-15). Every
        // other exit of the row - expiry on all three lanes, void - now refunds the FUNDER and clears this flag where
        // custody ends (VD-101), so the flag can never outlive the tokens it describes.
        a.bountyEscrowed = true;
        a.windowStart = block.timestamp;
        a.auditWindow = orig.auditWindow;
        a.state = CellTypeDefs.AuditState.None;
        a.specHash = orig.specHash;
        a.artifactHash = orig.artifactHash;
        a.specToolId = orig.specToolId;
        a.specPassDigest = orig.specPassDigest;
        a.specAuditorAttested = false;
        a.pickupTime = 0;
        a.isVulnerabilityReport = false;
        a.isClaimDispute = true;
        a.linkedAuditId = originalId;
        a.stateBeforeClaim = CellTypeDefs.AuditState.None;
        a.lastDiscoverer = lastDiscoverer;
        a.protocolApprovedAssignment = false;
        a.protocolRejectCount = 0;
        a.caseRoot = orig.caseRoot;
        a.supersedesAuditId = 0;
    }

    // ------------------------------------------------------------------ external entrypoints (delegatecall)

    function provePass(uint256 id, bytes32 toolId, bytes32 resultRoot) external {
        if (!(resultRoot != bytes32(0))) revert ResultRootRequired();
        CellStorage.Layout storage L = CellStorage.layout();
        _structuralHook(L, 1, id, toolId);
        bytes32[] memory tu = new bytes32[](1);
        tu[0] = toolId;
        submitVerdictAfterProof(L, id, true, tu, resultRoot);
    }

    function proveFail(uint256 id, bytes32 toolId, bytes32 resultRoot) external {
        if (!(resultRoot != bytes32(0))) revert ResultRootRequired();
        CellStorage.Layout storage L = CellStorage.layout();
        _structuralHook(L, 2, id, toolId);
        bytes32[] memory tu = new bytes32[](1);
        tu[0] = toolId;
        submitVerdictAfterProof(L, id, false, tu, resultRoot);
    }

    function submitVerdictAfterProof(
        CellStorage.Layout storage L,
        uint256 id,
        bool pass,
        bytes32[] memory toolsUsed,
        bytes32 proofHash
    ) internal {
        CellTypeDefs.Audit storage a = L.audits[id];
        if (!(msg.sender == a.auditor)) revert NotAuditor();
        if (!(a.protocol != msg.sender)) revert SelfAuditDisallowed();
        if (!(isEligible(L, msg.sender))) revert InsufficientHold();
        if (!(a.state == CellTypeDefs.AuditState.InAudit)) revert WrongState();
        // PC-91 bug_004 (G3, I2): the verdict closes where the permissionless timeout opens (`advanceInAuditExt`,
        // `block.timestamp > pickupTime + inAuditWindow`), so the two intervals partition time and ordering decides nothing.
        if (block.timestamp > a.pickupTime + L.inAuditWindow) revert InAuditWindowPassed();
        if (!(a.specAuditorAttested)) revert SpecNotAttested();
        _requireNoSettlementBlock(L, id);
        if (!(toolsUsed.length == 1)) revert SingleToolPerVerdict();
        if (!(proofHash != bytes32(0))) revert ResultRootRequired();

        bytes32 citedTool = toolsUsed[0];
        CellTypeDefs.Tool storage cited = L.tools[citedTool];
        if (!(cited.exists)) revert ToolNotRegistered();
        if (!(!cited.isSpecValidationTool)) revert SpecToolNotForVerdict();
        if (!a.isClaimDispute && !a.isVulnerabilityReport && !isStructuralAudit(L, id)) {
            if (!isDeclaredVerdictTool(L, id, citedTool)) revert ToolNotDeclared();
        }

        if (a.isClaimDispute) {
            bytes32 req = L.disputeRequiredTool[id];
            if (!(citedTool == req)) revert DisputeToolMismatch();
        }

        L.auditProofHash[id] = proofHash;
        L.auditVerdictPass[id] = pass;
        L.auditVerdictToolId[id] = citedTool;

        if (pass) {
            _setAuditState(L, id, CellTypeDefs.AuditState.AwaitingWindow);
            a.windowStart = block.timestamp;
        } else if (a.isClaimDispute) {
            _setAuditState(L, id, CellTypeDefs.AuditState.AwaitingWindow);
            a.windowStart = block.timestamp;
        } else {
            // VD-218(3) (VD-216(4) widened): ONE SELF-CLAIM PER AUDITOR PER ROW. Refused while a claim is OPEN, or when the
            // resolved claim was THIS auditor's; another auditor's resolved claim does not bind. On `exists` alone - which
            // no exit clears - a redrawn auditor could never report a failure on a row an earlier auditor had self-claimed.
            CellTypeDefs.VulnerabilityClaim storage prior = L.vulnerabilityClaims[id];
            if (prior.exists && (!prior.resolved || prior.claimant == msg.sender)) revert ClaimAlreadyExists();
            uint256 stake = computeClaimStake(L, a.bounty);
            CellTypeDefs.VulnerabilityClaim storage c = L.vulnerabilityClaims[id];
            c.claimant = msg.sender;
            c.toolId = citedTool;
            c.proofHash = proofHash;
            c.claimTimestamp = block.timestamp;
            c.stake = stake;
            c.resolved = false;
            c.exists = true;
            c.witnessPath = false;
            c.evaluatorToolId = bytes32(0);
            c.invariantId = bytes32(0);
            c.locationCommitment = bytes32(0);
            c.witnessCommitment = bytes32(0);
            c.contextRoot = bytes32(0);
            if (stake > 0) {
                if (!(L.token.transferFrom(msg.sender, address(this), stake))) revert StakeTransferFailed();
            }
            a.stateBeforeClaim = CellTypeDefs.AuditState.InAudit;
            _setAuditState(L, id, CellTypeDefs.AuditState.Claimed);
            _releaseGenesisIfOpen(L, id);
            emit VulnerabilityClaimed(id, msg.sender, citedTool, proofHash, stake);
        }
        emit VerdictSubmitted(id, pass, citedTool, proofHash);
    }

    /// @notice G-10 / G-15: confirm pays bounty + positive block (non-dispute) or dispute resolve only.
    ///         No structural probation, no claim settlement on linked O from fix path.
    function confirmAudit(uint256 id) external {
        CellStorage.Layout storage L = CellStorage.layout();
        CellTypeDefs.Audit storage a = L.audits[id];
        if (a.state != CellTypeDefs.AuditState.AwaitingWindow) revert NotAwaiting();
        _requireNoSettlementBlock(L, id);
        if (block.timestamp < a.windowStart + a.auditWindow) revert AuditWindowOpen();
        // PC-98 (G4(c), I2) and its spec-gap sibling (VD-218(4) F1): a verdicted dispute row of the CLAIM lane (the row its
        // original's dispute slot names) or the SPEC-GAP lane (resolver = the spec-gap module) left unconfirmed for one
        // resolution window past its audit window is released by its lane's expiry, and confirm closes at that same
        // instant, so the two exits partition time. The integrity lane keeps its own rule (its expiry refuses a verdict).
        if (
            a.isClaimDispute
                && (L.activeDisputeAuditId[a.linkedAuditId] == id || L.disputeResolver[id] == L.specGapModule)
                && block.timestamp >= a.windowStart + a.auditWindow + L.claimResolutionWindow
        ) revert DisputeReleasable();

        _setAuditState(L, id, CellTypeDefs.AuditState.InBlock);

        // PAY ONLY WHAT WAS ESCROWED (bug_101 / bug_301, fixed 2026-09-04; proposal section A).
        // This asked the LATCH - `isGenesisConfirm = L.genesisAuditOpen && L.genesisAuditId == id` - a
        // per-SLOT fact, and never the row's own `a.bountyEscrowed`, which every OTHER consumer of
        // `a.bounty` already checks (AuditCell._voidAuditRow, SpecArbiterModule._payoutAndVoid).
        // The latch is released on a NON-TERMINAL exit - proveFail sets the row to Claimed and calls
        // _releaseGenesisIfOpen - while the row lives on and walks back out of Claimed when the claim
        // resolves. A later confirm then saw isGenesisConfirm == false and paid a bounty THE CELL NEVER
        // RECEIVED, out of other protocols' escrowed funds, repeatably: genesisPending is cleared only
        // in the branch below, so the slot reopens each time.
        //
        // THE RETRY THAT RELEASES THE LATCH IS DELIBERATE AND IS NOT WHAT CHANGED. A failed genesis must
        // not brick the cell (test_genesis_fail_releases_lock_allows_retry pins exactly that state). Two
        // correct intentions with one wrong predicate between them; only the predicate moved.
        //
        // Genesis rows are created with skipBountyEscrow = true, so they are excluded by this test just
        // as they were by the old one - the difference is that they STAY excluded after the slot reopens.
        if (a.bountyEscrowed) {
            if (!(L.token.transfer(a.auditor, a.bounty))) revert BountyPayoutFailed();
            // VD-101: THE FLAG CLEARS WHERE CUSTODY ENDS. `bountyEscrowed` had one write site (:913,
            // submit) and ZERO clear sites in the tree, so after this payout the row went on asserting
            // escrow over tokens that had just left. `_voidAuditRow` (AuditCell:1392) reads that flag
            // and re-pays the bounty to the protocol - funded by whatever the cell happens to hold,
            // which on a confirmed-then-CLAIMED row is the claimant's stake. The `state != InBlock`
            // guard was meant to stop it; filing a claim moves the row to `Claimed` and walks around it.
            // Not stranding - taking, silently, which is why nothing noticed.
            // `a.bounty` is deliberately NOT zeroed here: the void arm zeroes it as refund bookkeeping,
            // confirm COMPLETES the promise, and the flag is the shared truth every reader keys on.
            a.bountyEscrowed = false;
        }

        if (!a.isClaimDispute) {
            L.auditors[a.auditor].successful += 1;
            if (L.genesisAuditOpen && L.genesisAuditId == id) {
                L.genesisAuditId = 0;
                L.genesisAuditOpen = false;
                L.genesisPending = false;
            }
            L.totalSuccessfulAudits += 1;
            L.protocols[a.protocol].successful += 1;
            if (
                L.assignmentModule != address(0) && !a.isVulnerabilityReport && !isStructuralAudit(L, id)
            ) {
                IAssignmentModule(L.assignmentModule).noteCompletion(a.protocol, a.auditor);
            }

            uint256 reward;
            uint256 auditorMinted;
            if (L.issuanceModule != address(0)) {
                (auditorMinted, , reward) = IIssuanceModuleLib(L.issuanceModule)
                    .settlePositiveBlock(id, a.auditor, a.protocol, a.bounty);
                L.auditBlockRewardMinted[id] = auditorMinted;
            }

            _recordToolUse(L, id, true);

            L.auditPositiveBlock[id] = L.blockHeight;
            L.blockHeight += 1;
            L.latestBlockHash =
                keccak256(abi.encode(L.latestBlockHash, "POS", L.blockHeight, id, reward, block.timestamp));

            emit PositiveBlockMinted(L.blockHeight, id, reward, L.latestBlockHash);
            if (auditorMinted == 0) {
                emit PositiveBlockSupplyExhausted(L.blockHeight, id);
            }
        }

        emit AuditConfirmed(id);

        if (a.isClaimDispute && a.linkedAuditId < L.nextAuditId) {
            IDisputeResolverLib(L.disputeResolver[id]).resolveFromDispute(a.linkedAuditId, id);
        }
    }

    function _recordToolUse(CellStorage.Layout storage L, uint256 auditId, bool successful) internal {
        bytes32 citedTool = L.auditVerdictToolId[auditId];
        if (citedTool != bytes32(0)) {
            _recordOneToolUse(L, citedTool, auditId, successful);
        }
        _recordSpecToolUse(L, auditId, successful);
    }

    function _recordSpecToolUse(CellStorage.Layout storage L, uint256 auditId, bool successful) internal {
        bytes32 toolId = L.audits[auditId].specToolId;
        if (toolId == bytes32(0)) return;
        _recordOneToolUse(L, toolId, auditId, successful);
    }

    /// @dev G-19 (2026-07-08): body EXTRACTED to `ToolUseLib.recordOneToolUseExt` (linked lib, delegatecall,
    ///      same storage) — the canonization trigger is re-keyed there to DISTINCT ESTABLISHED protocols.
    ///      Extraction keeps CellLogicLib under its byte margin; events re-declared topic-identical in
    ///      ToolUseLib. `L` stays in the signature so call sites are untouched.
    function _recordOneToolUse(
        CellStorage.Layout storage L,
        bytes32 toolId,
        uint256 auditId,
        bool successful
    ) internal {
        L; // storage context is shared via delegatecall; parameter kept for call-site stability
        ToolUseLib.recordOneToolUseExt(toolId, auditId, successful);
    }

    function maxProtocolRejectsForAuditExt(address protocol) external view returns (uint256) {
        return _maxProtocolRejectsForAudit(CellStorage.layout(), protocol);
    }

    function _maxProtocolRejectsForAudit(CellStorage.Layout storage L, address protocol)
        internal
        view
        returns (uint256)
    {
        CellTypeDefs.ProtocolRecord storage p = L.protocols[protocol];
        uint256 cap = 1 + p.successful / 10;
        if (cap > MAX_PROTOCOL_REJECTS_CAP) {
            cap = MAX_PROTOCOL_REJECTS_CAP;
        }
        if (p.exploited > PROTOCOL_EXPLOITED_REJECT_GRACE) {
            uint256 penalty = p.exploited - PROTOCOL_EXPLOITED_REJECT_GRACE;
            if (penalty >= cap) {
                return 0;
            }
            return cap - penalty;
        }
        return cap;
    }

    function protocolAcceptAuditorExt(uint256 id) external {
        CellStorage.Layout storage L = CellStorage.layout();
        CellTypeDefs.Audit storage a = L.audits[id];
        if (!(a.state == CellTypeDefs.AuditState.Assigned)) revert NotAssigned();
        if (!(msg.sender == a.protocol)) revert OnlyProtocol();
        if (!(!a.isVulnerabilityReport && !a.isClaimDispute)) revert SkipsProtocolGate();
        if (!(!a.protocolApprovedAssignment)) revert AlreadyAccepted();
        a.protocolApprovedAssignment = true;
        a.pickupTime = block.timestamp;
        L.protocols[msg.sender].auditorAssignmentsAccepted += 1;
        emit ProtocolAuditorAccepted(id, a.auditor);
    }

    function advanceProtocolDecisionExt(uint256 id) external {
        CellStorage.Layout storage L = CellStorage.layout();
        CellTypeDefs.Audit storage a = L.audits[id];
        if (!(a.state == CellTypeDefs.AuditState.Assigned)) revert NotAssigned();
        if (!(!a.isVulnerabilityReport && !a.isClaimDispute)) revert SkipsProtocolGate();
        if (!(!a.protocolApprovedAssignment)) revert AlreadyAccepted();
        if (!(block.timestamp > a.pickupTime + L.protocolDecisionWindow)) revert ProtocolWindowActive();
        a.protocolApprovedAssignment = true;
        a.pickupTime = block.timestamp;
        L.protocols[a.protocol].auditorAssignmentsAccepted += 1;
        emit ProtocolDecisionTimedOut(id, a.auditor);
    }

    function protocolRejectAuditorExt(uint256 id) external {
        CellStorage.Layout storage L = CellStorage.layout();
        CellTypeDefs.Audit storage a = L.audits[id];
        if (!(a.state == CellTypeDefs.AuditState.Assigned)) revert NotAssigned();
        if (!(msg.sender == a.protocol)) revert OnlyProtocol();
        if (!(!a.isVulnerabilityReport && !a.isClaimDispute)) revert SkipsProtocolGate();
        if (!(!a.protocolApprovedAssignment)) revert AlreadyAccepted();
        if (!(block.timestamp <= a.pickupTime + L.protocolDecisionWindow)) revert ProtocolWindowActive();
        uint256 maxRejects = _maxProtocolRejectsForAudit(L, a.protocol);
        if (!(uint256(a.protocolRejectCount) < maxRejects)) revert RejectCapReached();
        address rejected = a.auditor;
        if (L.assignmentModule != address(0)) {
            IAssignmentModule(L.assignmentModule).noteReject(id, rejected);
        }
        L.protocols[a.protocol].auditorAssignmentsRejected += 1;
        a.protocolRejectCount += 1;
        emit ProtocolAuditorRejected(id, rejected);
        a.auditor = address(0);
        a.pickupTime = 0;
        _setAuditState(L, id, CellTypeDefs.AuditState.Submitted);
        _assignNext(L, id);
    }

    function declineAuditExt(uint256 id) external {
        CellStorage.Layout storage L = CellStorage.layout();
        CellTypeDefs.Audit storage a = L.audits[id];
        if (!(a.state == CellTypeDefs.AuditState.Assigned)) revert NotInDecisionWindow();
        if (!(msg.sender == a.auditor)) revert NotAssignedAuditor();
        if (!(block.timestamp <= a.pickupTime + L.decisionWindow)) revert DecisionWindowPassed();
        emit AuditDeclined(id, msg.sender);
        if (L.assignmentModule != address(0) && !a.isVulnerabilityReport && !a.isClaimDispute) {
            IAssignmentModule(L.assignmentModule).noteDecline(id, msg.sender);
        }
        L.auditors[msg.sender].timeoutStreak = 0;
        a.auditor = address(0);
        a.pickupTime = 0;
        _setAuditState(L, id, CellTypeDefs.AuditState.Submitted);
        _assignNext(L, id);
    }

    /// @dev PC-99 (G5, I5): a second excluded party reaches this ONE entry point through `AuditCell.settlementSetDisputeExclude2`,
    ///      keyed on the original id AND the spawning module (VD-223(1)), and consumed below. A second spawn entry point is
    ///      the shape that reads better, and it costs the library about 1.5 KB, because `initDisputeRow` is inlined into
    ///      every external that reaches the spawn body - measured 2026-09-17 on G5's first shape, 781 bytes over EIP-170.
    function spawnDisputeReaudit(
        uint256 originalId,
        uint256 disputeBounty,
        address lastDiscoverer,
        address extraExclude,
        bytes32 requiredTool,
        address resolverModule
    ) external returns (uint256 disputeId) {
        CellStorage.Layout storage L = CellStorage.layout();
        if (
            msg.sender != L.claimDisputeModule && msg.sender != L.specGapModule
                && msg.sender != L.integrityReviewModule
        ) revert NotAdmin();
        // VD-90: the FOREIGN-block form, at this site only. See `_requireNoForeignSettlementBlock`.
        _requireNoForeignSettlementBlock(L, originalId, msg.sender);
        CellTypeDefs.Audit storage orig = L.audits[originalId];

        disputeId = initDisputeRow(L, orig, originalId, disputeBounty, lastDiscoverer);
        L.disputeExtraExclude[disputeId] = extraExclude;
        address pending2 = L.pendingDisputeExclude2[originalId][msg.sender];
        if (pending2 != address(0)) {
            L.disputeExtraExclude2[disputeId] = pending2;
            L.pendingDisputeExclude2[originalId][msg.sender] = address(0);
        }
        L.disputeRequiredTool[disputeId] = requiredTool;
        L.disputeResolver[disputeId] = resolverModule == address(0) ? L.claimDisputeModule : resolverModule;
        _setAuditState(L, disputeId, CellTypeDefs.AuditState.Submitted);
        _assignNext(L, disputeId);
        if (resolverModule == address(0)) {
            L.activeDisputeAuditId[originalId] = disputeId;
            emit AuditCasePinned(
                disputeId,
                orig.caseRoot,
                orig.specHash,
                orig.artifactHash,
                originalId,
                false,
                true,
                0
            );
        }
    }

    bytes32 internal constant AUDIT_CASE_V1 = keccak256("AUDIT_CASE_V1");
    uint256 internal constant MAX_DECLARED_VERDICT_TOOLS = 4;

    event AuditSubmitted(
        uint256 indexed id,
        address indexed protocol,
        address indexed deployedAddress,
        uint256 bounty,
        bytes32 artifactHash,
        bytes32 specToolId,
        bytes32 specPassDigest
    );

    error DeclaredToolInvalid();
    error EmptyBytecode();
    error BountyEscrowFailed();
    error CaseAlreadyAudited(uint256 existingAuditId);
    error InvalidSupersedesAuditId();
    error SupersedesSameProtocolOnly();
    error SupersedesPriorMustBeOrdinary();
    error SupersedesSameORequired();
    error SupersedesMustBeNewCaseRoot();

    function _storeDeclaredVerdictTools(CellStorage.Layout storage L, uint256 auditId, bytes32[] memory declared)
        internal
    {
        uint256 n = declared.length;
        if (n < 1 || n > MAX_DECLARED_VERDICT_TOOLS) revert DeclaredToolInvalid();
        bytes32[4] storage slots = L.declaredVerdictTools[auditId];
        for (uint256 i = 0; i < n; i++) {
            bytes32 t = declared[i];
            if (t == bytes32(0)) revert DeclaredToolInvalid();
            CellTypeDefs.Tool storage tool = L.tools[t];
            if (!tool.exists || tool.isSpecValidationTool) revert DeclaredToolInvalid();
            for (uint256 j = 0; j < i; j++) {
                if (declared[j] == t) revert DeclaredToolInvalid();
            }
            slots[i] = t;
        }
        L.declaredVerdictToolLen[auditId] = uint8(n);
    }

    function _sortToolIds(bytes32[] memory toolIds) internal pure returns (bytes32[] memory sorted) {
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

    function _caseRootFromInputs(
        bytes32 artifactHash,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specPassDigest,
        bytes32[] memory toolIdsSortedAscending
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                AUDIT_CASE_V1,
                artifactHash,
                specHash,
                specToolId,
                specPassDigest,
                toolIdsSortedAscending
            )
        );
    }

    function _initAuditRow(
        CellStorage.Layout storage L,
        address protocol,
        address deployedAddress,
        bytes32 artifactHash,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specPassDigest,
        uint256 bounty,
        uint256 auditWindow,
        bool isVulnerabilityReport,
        bool isClaimDispute,
        uint256 linkedAuditId,
        uint256 supersedesAuditId,
        bool skipBountyEscrow
    ) internal returns (uint256 id) {
        if (!(artifactHash != bytes32(0))) revert EmptyBytecode();
        if (!skipBountyEscrow) {
            if (!(L.token.transferFrom(protocol, address(this), bounty))) revert BountyEscrowFailed();
        }

        id = L.nextAuditId++;
        CellTypeDefs.Audit storage a = L.audits[id];
        a.protocol = protocol;
        a.auditor = address(0);
        a.deployedAddress = deployedAddress;
        a.bounty = bounty;
        a.windowStart = 0;
        a.auditWindow = auditWindow;
        a.state = CellTypeDefs.AuditState.None;
        a.specHash = specHash;
        a.artifactHash = artifactHash;
        a.specToolId = specToolId;
        a.specPassDigest = specPassDigest;
        a.specAuditorAttested = false;
        a.pickupTime = 0;
        a.isVulnerabilityReport = isVulnerabilityReport;
        a.isClaimDispute = isClaimDispute;
        a.linkedAuditId = linkedAuditId;
        a.stateBeforeClaim = CellTypeDefs.AuditState.None;
        a.lastDiscoverer = address(0);
        a.protocolApprovedAssignment = false;
        a.protocolRejectCount = 0;
        a.caseRoot = bytes32(0);
        a.supersedesAuditId = supersedesAuditId;
        a.bountyEscrowed = !skipBountyEscrow;
    }

    function initAuditRowExt(
        address protocol,
        address deployedAddress,
        bytes32 artifactHash,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specPassDigest,
        uint256 bounty,
        uint256 auditWindow,
        bool isVulnerabilityReport,
        bool isClaimDispute,
        uint256 linkedAuditId,
        uint256 supersedesAuditId
    ) external returns (uint256 id) {
        return _initAuditRow(
            CellStorage.layout(),
            protocol,
            deployedAddress,
            artifactHash,
            specHash,
            specToolId,
            specPassDigest,
            bounty,
            auditWindow,
            isVulnerabilityReport,
            isClaimDispute,
            linkedAuditId,
            supersedesAuditId,
            false
        );
    }

    function createAuditExt(
        address deployedAddress,
        bytes32 artifactHash,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specPassDigest,
        uint256 bounty,
        uint256 auditWindow,
        bool isVulnerabilityReport,
        bool isClaimDispute,
        uint256 linkedAuditId,
        bytes32[] memory declaredVerdictTools,
        uint256 supersedesAuditId
    ) external returns (uint256 id) {
        CellStorage.Layout storage L = CellStorage.layout();
        id = _initAuditRow(
            L,
            msg.sender,
            deployedAddress,
            artifactHash,
            specHash,
            specToolId,
            specPassDigest,
            bounty,
            auditWindow,
            isVulnerabilityReport,
            isClaimDispute,
            linkedAuditId,
            supersedesAuditId,
            false
        );
        _finalizeCreatedAudit(
            L,
            id,
            deployedAddress,
            artifactHash,
            specHash,
            specToolId,
            specPassDigest,
            bounty,
            isVulnerabilityReport,
            isClaimDispute,
            linkedAuditId,
            declaredVerdictTools,
            supersedesAuditId
        );
    }

    function createGenesisAuditExt(
        address deployedAddress,
        bytes32 artifactHash,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specPassDigest,
        uint256 bounty,
        uint256 auditWindow,
        bytes32[] memory declaredVerdictTools,
        uint256 supersedesAuditId
    ) external returns (uint256 id) {
        CellStorage.Layout storage L = CellStorage.layout();
        id = _initAuditRow(
            L,
            msg.sender,
            deployedAddress,
            artifactHash,
            specHash,
            specToolId,
            specPassDigest,
            bounty,
            auditWindow,
            false,
            false,
            0,
            supersedesAuditId,
            true
        );
        _finalizeCreatedAudit(
            L,
            id,
            deployedAddress,
            artifactHash,
            specHash,
            specToolId,
            specPassDigest,
            bounty,
            false,
            false,
            0,
            declaredVerdictTools,
            supersedesAuditId
        );
    }

    function _finalizeCreatedAudit(
        CellStorage.Layout storage L,
        uint256 id,
        address deployedAddress,
        bytes32 artifactHash,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specPassDigest,
        uint256 bounty,
        bool isVulnerabilityReport,
        bool isClaimDispute,
        uint256 linkedAuditId,
        bytes32[] memory declaredVerdictTools,
        uint256 supersedesAuditId
    ) internal {
        if (declaredVerdictTools.length > 0) {
            _storeDeclaredVerdictTools(L, id, declaredVerdictTools);
        }

        bytes32[] memory sorted = _sortToolIds(declaredVerdictTools);
        bytes32 root = _caseRootFromInputs(artifactHash, specHash, specToolId, specPassDigest, sorted);

        if (!isClaimDispute) {
            if (L.caseRootRegistered[root]) {
                revert CaseAlreadyAudited(L.caseRootToAuditId[root]);
            }
            if (supersedesAuditId != 0) {
                if (!(supersedesAuditId < id)) revert InvalidSupersedesAuditId();
                CellTypeDefs.Audit storage prior = L.audits[supersedesAuditId];
                if (!(prior.protocol == msg.sender)) revert SupersedesSameProtocolOnly();
                if (prior.isVulnerabilityReport || prior.isClaimDispute) revert SupersedesPriorMustBeOrdinary();
                if (!(prior.artifactHash == artifactHash)) revert SupersedesSameORequired();
                if (!(prior.caseRoot != root)) revert SupersedesMustBeNewCaseRoot();
            }
            L.caseRootRegistered[root] = true;
            L.caseRootToAuditId[root] = id;
        }

        L.audits[id].caseRoot = root;
        _setAuditState(L, id, CellTypeDefs.AuditState.Submitted);

        if (!isClaimDispute && !L.artifactRegistered[artifactHash]) {
            L.artifactRegistered[artifactHash] = true;
            L.artifactToAuditId[artifactHash] = id;
        }

        emit AuditSubmitted(id, msg.sender, deployedAddress, bounty, artifactHash, specToolId, specPassDigest);
        emit AuditCasePinned(
            id,
            root,
            specHash,
            artifactHash,
            linkedAuditId,
            isVulnerabilityReport,
            isClaimDispute,
            supersedesAuditId
        );

        _assignNext(L, id);
    }

    // ------------------------------------------------------------------ reclaimed views (lib bytes — not EIP-170 cell budget)

    function queueLengthView() external view returns (uint256) {
        return CellStorage.layout().queueLength;
    }

    function queueHeadView() external view returns (address) {
        return CellStorage.layout().queueHead;
    }

    function queueNextView(address a) external view returns (address) {
        return CellStorage.layout().queueNext[a];
    }

    function auditorCountView() external view returns (uint256) {
        return CellStorage.layout().auditorCount;
    }

    function incrementView() external view returns (uint256) {
        return CellStorage.layout().increment;
    }

    function activeDisputeAuditIdView(uint256 id) external view returns (uint256) {
        return CellStorage.layout().activeDisputeAuditId[id];
    }

    function activeFixAuditIdView(uint256 id) external view returns (uint256) {
        return CellStorage.layout().activeFixAuditId[id];
    }

    function auditProofHashView(uint256 id) external view returns (bytes32) {
        return CellStorage.layout().auditProofHash[id];
    }

    function auditVerdictPassView(uint256 id) external view returns (bool) {
        return CellStorage.layout().auditVerdictPass[id];
    }

    function auditVerdictToolIdView(uint256 id) external view returns (bytes32) {
        return CellStorage.layout().auditVerdictToolId[id];
    }

    function auditBlockRewardMintedView(uint256 id) external view returns (uint256) {
        return CellStorage.layout().auditBlockRewardMinted[id];
    }

    function auditPositiveBlockView(uint256 id) external view returns (uint256) {
        return CellStorage.layout().auditPositiveBlock[id];
    }

    function blockHeightView() external view returns (uint256) {
        return CellStorage.layout().blockHeight;
    }

    function latestBlockHashView() external view returns (bytes32) {
        return CellStorage.layout().latestBlockHash;
    }

    function artifactRegisteredView(bytes32 h) external view returns (bool) {
        return CellStorage.layout().artifactRegistered[h];
    }

    function artifactToAuditIdView(bytes32 h) external view returns (uint256) {
        return CellStorage.layout().artifactToAuditId[h];
    }

    function caseRootRegisteredView(bytes32 h) external view returns (bool) {
        return CellStorage.layout().caseRootRegistered[h];
    }

    function caseRootToAuditIdView(bytes32 h) external view returns (uint256) {
        return CellStorage.layout().caseRootToAuditId[h];
    }

    function currentBlockSizeView() external view returns (uint256) {
        return CellStorage.layout().currentBlockSize;
    }

    function minAuditWindowView() external view returns (uint256) {
        return CellStorage.layout().minAuditWindow;
    }

    function protocolDecisionWindowView() external view returns (uint256) {
        return CellStorage.layout().protocolDecisionWindow;
    }

    function claimResolutionWindowView() external view returns (uint256) {
        return CellStorage.layout().claimResolutionWindow;
    }

    function claimFilingStakeView() external view returns (uint256) {
        return CellStorage.layout().claimFilingStake;
    }

    function auditExistsView(uint256 id) external view returns (bool) {
        return id < CellStorage.layout().nextAuditId;
    }

    function claimProofStatementView(uint256 originalAuditId, bytes32 toolId, bytes32 resultRoot)
        external
        view
        returns (bytes32)
    {
        CellTypeDefs.Audit storage a = CellStorage.layout().audits[originalAuditId];
        return keccak256(
            abi.encodePacked("AUDIT_CLAIM_PROOF_V1", a.artifactHash, a.specHash, toolId, resultRoot)
        );
    }

    function specChallengeActiveView(uint256 id) external view returns (bool) {
        CellStorage.Layout storage L = CellStorage.layout();
        return L.specArbiterModule != address(0) && ISpecChallengeGateLib(L.specArbiterModule).challengeActive(id);
    }

    function requiredHoldView(address auditor) external view returns (uint256) {
        return _requiredHold(CellStorage.layout(), auditor);
    }

    function isEligibleView(address auditor) external view returns (bool) {
        CellStorage.Layout storage L = CellStorage.layout();
        return L.token.balanceOf(auditor) >= _requiredHold(L, auditor);
    }

    function _requiredHold(CellStorage.Layout storage L, address auditor) internal view returns (uint256) {
        CellTypeDefs.AuditorRecord memory r = L.auditors[auditor];
        if (r.position == 0) {
            return L.auditorCount * L.increment;
        }
        return (r.position - 1) * L.increment;
    }

    function auditorReputationBoostBpsView(address auditor) external view returns (uint256) {
        CellStorage.Layout storage L = CellStorage.layout();
        CellTypeDefs.AuditorRecord storage r = L.auditors[auditor];
        uint256 denom = r.successful + r.failed + r.found;
        if (denom == 0) {
            return 10_000;
        }
        uint256 gap = r.failed > r.found ? r.failed - r.found : 0;
        return 10_000 + (L.maxBoostFactor * 10_000 * gap) / denom;
    }

    error NotAwaitingAcceptance();
    error SpecRunMismatch();
    error ProtocolNotAcceptedAssignment();
    error NotInAudit();
    error InAuditWindowActive();
    error AlreadyLocked();
    error AuditWindowOutOfBounds();
    error ParamLockedErr();
    error InvalidParamId();
    error BpsOutOfBounds();
    error ClaimWindowOutOfBounds();
    error ClaimStakeTooLarge();
    error DecisionWindowNotPassed();
    error AlreadyInQueue();

    event AuditorRegistered(address indexed auditor, uint256 position);
    event AuditorRejoined(address indexed auditor);
    event AuditAccepted(uint256 indexed id, address indexed auditor);
    event AuditTimedOut(uint256 indexed id, address indexed auditor, uint256 timeoutStreak);
    event AuditorPushedOut(address indexed auditor);

    function registerExt() external {
        CellStorage.Layout storage L = CellStorage.layout();
        CellTypeDefs.AuditorRecord storage r = L.auditors[msg.sender];
        if (!(!r.inQueue)) revert AlreadyInQueue();

        if (r.position == 0) {
            uint256 newPosition = ++L.auditorCount;
            // PC-85 (G6, I6): position 1 holds nothing at any increment and is the queue head the genesis audit is drawn
            // from. When the admin has NAMED the genesis auditor, the first registration while genesis is pending must be
            // that address - a squatter can no longer take the free seat and the genesis draw with it.
            if (
                newPosition == 1 && L.genesisPending && L.genesisAuditor != address(0) && msg.sender != L.genesisAuditor
            ) revert NotGenesisAuditor();
            if (!(L.token.balanceOf(msg.sender) >= (newPosition - 1) * L.increment)) revert InsufficientHold();
            r.position = newPosition;
            emit AuditorRegistered(msg.sender, newPosition);
        } else {
            if (!(L.token.balanceOf(msg.sender) >= _requiredHold(L, msg.sender))) revert InsufficientHold();
            emit AuditorRejoined(msg.sender);
        }

        r.timeoutStreak = 0;
        r.inQueue = true;
        appendToQueue(L, msg.sender);
    }

    function _specRunDigest(bytes32 specHash, bytes32 specToolId, bool pass, bytes32 errorsRoot)
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

    function _requireProtocolAssignmentReady(CellTypeDefs.Audit storage a) internal view {
        if (!(a.protocolApprovedAssignment || a.isVulnerabilityReport)) revert ProtocolNotAcceptedAssignment();
    }

    function acceptAuditExt(uint256 id, bytes32 specErrorsRoot) external {
        CellStorage.Layout storage L = CellStorage.layout();
        CellTypeDefs.Audit storage a = L.audits[id];
        if (!(a.state == CellTypeDefs.AuditState.Assigned)) revert NotAwaitingAcceptance();
        if (!(msg.sender == a.auditor)) revert NotAssignedAuditor();
        if (!(a.protocol != msg.sender)) revert SelfAuditDisallowed();
        if (!(L.token.balanceOf(msg.sender) >= _requiredHold(L, msg.sender))) revert InsufficientHold();
        _requireProtocolAssignmentReady(a);
        if (!(block.timestamp <= a.pickupTime + L.decisionWindow)) revert DecisionWindowPassed();
        _requireNoSettlementBlock(L, id);
        if (!(_specRunDigest(a.specHash, a.specToolId, true, specErrorsRoot) == a.specPassDigest)) {
            revert SpecRunMismatch();
        }
        a.specAuditorAttested = true;
        _setAuditState(L, id, CellTypeDefs.AuditState.InAudit);
        a.pickupTime = block.timestamp;
        L.auditors[msg.sender].timeoutStreak = 0;
        emit AuditAccepted(id, msg.sender);
    }

    function _pushOutSlacker(CellStorage.Layout storage L, uint256 id, CellTypeDefs.Audit storage a) internal {
        address slacker = a.auditor;
        CellTypeDefs.AuditorRecord storage rec = L.auditors[slacker];
        rec.timeoutStreak += 1;
        emit AuditTimedOut(id, slacker, rec.timeoutStreak);
        if (rec.timeoutStreak >= L.pushOutThreshold && rec.inQueue) {
            removeFromQueue(L, slacker);
            rec.inQueue = false;
            emit AuditorPushedOut(slacker);
        }
        a.auditor = address(0);
        a.pickupTime = 0;
        _setAuditState(L, id, CellTypeDefs.AuditState.Submitted);
        _assignNext(L, id);
    }

    function advanceAssignmentExt(uint256 id) external {
        CellStorage.Layout storage L = CellStorage.layout();
        CellTypeDefs.Audit storage a = L.audits[id];
        if (!(a.state == CellTypeDefs.AuditState.Assigned)) revert NotInDecisionWindow();
        _requireProtocolAssignmentReady(a);
        if (!(block.timestamp > a.pickupTime + L.decisionWindow)) revert DecisionWindowNotPassed();
        // PC-91 bug_003 (G4(a), I3): accept refuses under a settlement overlay, so the timeout does too. The frozen time
        // is given back when the overlay ends without a void (`SubmitAuditLib.resumeClockExt`).
        _requireNoSettlementBlock(L, id);
        _pushOutSlacker(L, id, a);
    }

    function advanceInAuditExt(uint256 id) external {
        CellStorage.Layout storage L = CellStorage.layout();
        CellTypeDefs.Audit storage a = L.audits[id];
        if (!(a.state == CellTypeDefs.AuditState.InAudit)) revert NotInAudit();
        if (!(block.timestamp > a.pickupTime + L.inAuditWindow)) revert InAuditWindowActive();
        // PC-91 bug_003 (G4(a), I3): the verdict refuses under a settlement overlay, so the timeout does too.
        _requireNoSettlementBlock(L, id);
        _pushOutSlacker(L, id, a);
    }

    uint256 internal constant MIN_DECISION_WINDOW = 1 minutes;
    uint256 internal constant MAX_DECISION_WINDOW = 7 days;
    uint256 internal constant MIN_PROTOCOL_DECISION_WINDOW = 1 minutes;
    uint256 internal constant MAX_PROTOCOL_DECISION_WINDOW = 14 days;
    uint256 internal constant MIN_IN_AUDIT_WINDOW = 1 minutes;
    uint256 internal constant MAX_IN_AUDIT_WINDOW = 30 days;
    uint256 internal constant MIN_AUDIT_WINDOW = 10 minutes;
    uint256 internal constant MAX_AUDIT_WINDOW = 30 days;

    uint8 internal constant PARAM_ID_MAX = 13; // 13 = TOOL_WITNESS_FLAGS (door 16); lockParam(13) must pass
    uint8 internal constant PARAM_CLAIM_STAKE_BPS = 12;
    uint8 internal constant PARAM_MIN_AUDIT = 8;
    uint8 internal constant PARAM_DECISION = 9;
    uint8 internal constant PARAM_PROTOCOL_DECISION = 10;
    uint8 internal constant PARAM_IN_AUDIT = 11;

    uint256 internal constant MIN_CLAIM_RESOLUTION = 10 minutes;
    uint256 internal constant MAX_CLAIM_RESOLUTION = 90 days;
    uint256 internal constant MAX_CLAIM_FILING = 10_000 ether;
    uint256 internal constant MAX_BPS = 10_000;

    function _requireParamUnlocked(CellStorage.Layout storage L, uint8 id) private view {
        if ((L.paramLocked & (uint256(1) << id)) != 0) revert ParamLockedErr();
    }

    function lockParamExt(uint8 id) external {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(msg.sender == L.admin)) revert NotAdmin();
        if (id > PARAM_ID_MAX) revert InvalidParamId();
        uint256 bit = uint256(1) << id;
        if ((L.paramLocked & bit) != 0) revert AlreadyLocked();
        L.paramLocked |= bit;
    }

    function paramLockedExt(uint8 id) external view returns (bool) {
        if (id > PARAM_ID_MAX) revert InvalidParamId();
        return (CellStorage.layout().paramLocked & (uint256(1) << id)) != 0;
    }

    function setParamExt(uint8 id, uint256 v) external {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(msg.sender == L.admin)) revert NotAdmin();
        if (id > PARAM_ID_MAX || id == 6 || id == 7) revert InvalidParamId();
        _requireParamUnlocked(L, id);
        if (id == 0) {
            if (!(v >= MIN_CLAIM_RESOLUTION && v <= MAX_CLAIM_RESOLUTION)) revert ClaimWindowOutOfBounds();
            L.claimResolutionWindow = v;
        } else if (id == 1) {
            if (!(v <= MAX_CLAIM_FILING)) revert ClaimStakeTooLarge();
            L.claimFilingStake = v;
        } else if (id == 2) {
            if (!(v > 0)) revert ZeroThreshold();
            L.canonicalThreshold = v;
        } else if (id == 3) {
            if (!(v > 0)) revert ZeroThreshold();
            L.maxBoostFactor = v;
        } else if (id == 4) {
            if (!(v <= MAX_BPS)) revert BpsOutOfBounds();
            L.discoveryCapBps = v;
        } else if (id == 5) {
            if (!(v <= MAX_BPS)) revert BpsOutOfBounds();
            L.discoveryFloorBps = v;
        } else if (id == PARAM_MIN_AUDIT) {
            if (!(v >= MIN_AUDIT_WINDOW && v <= MAX_AUDIT_WINDOW)) revert AuditWindowOutOfBounds();
            L.minAuditWindow = v;
        } else if (id == PARAM_DECISION) {
            if (!(v >= MIN_DECISION_WINDOW && v <= MAX_DECISION_WINDOW)) revert AuditWindowOutOfBounds();
            L.decisionWindow = v;
        } else if (id == PARAM_PROTOCOL_DECISION) {
            if (!(v >= MIN_PROTOCOL_DECISION_WINDOW && v <= MAX_PROTOCOL_DECISION_WINDOW)) {
                revert AuditWindowOutOfBounds();
            }
            L.protocolDecisionWindow = v;
        } else if (id == PARAM_IN_AUDIT) {
            if (!(v >= MIN_IN_AUDIT_WINDOW && v <= MAX_IN_AUDIT_WINDOW)) revert AuditWindowOutOfBounds();
            L.inAuditWindow = v;
        } else if (id == PARAM_CLAIM_STAKE_BPS) {
            if (!(v <= MAX_BPS)) revert BpsOutOfBounds();
            L.claimStakeBps = v;
        } else {
            revert InvalidParamId();
        }
    }
}

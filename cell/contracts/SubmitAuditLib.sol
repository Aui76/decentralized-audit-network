// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./CellStorage.sol";
import "./CellLogicLib.sol";
import "./IClaimSettlementMutator.sol";
import "./IClaimDisputeModule.sol";

/// @dev G0 (hull window 2026-09-16): the escrow surface the claim-settlement bodies below need. Named apart from
///      AuditCell's own `ITreasuryEscrow` because AuditCell imports this file.
interface ISettlementSlashEscrow {
    function recordSlash(uint256 amount) external;
}

/// @dev Audit creation paths extracted from AuditCell for EIP-170 headroom (pre-freeze).
/// @notice Stateless delegatecall library — reads/writes via `CellStorage.layout()` only.
library SubmitAuditLib {
    error ArtifactHashMismatch();
    error ArtifactHashRequired();
    error AuditWindowTooLong();
    error NotGenesisProtocol();
    error BountyExceedsCap();
    error BountyRequired();
    error DeployedAddressRequired();
    error FixAuditAlreadyOpen();
    error GenesisAuditOpen();
    error GenesisNotPending();
    error InvalidLinkedAuditId();
    error LinkedClaimResolved();
    error LinkedNotClaimed();
    error NoAudit();
    error NoClaimOnLinked();
    error NoContractAtAddress();
    error NotSpecValidationTool();
    error OnlyLinkedProtocol();
    error SpecToolNotRegistered();
    error SpecToolRequired();
    error ZeroSpecHash();

    // G0 (hull window 2026-09-16, walkthrough VD-193 section 0): the claim-and-dispute settlement bodies moved here
    // from AuditCell for EIP-170 room. Same names and parameters as AuditCell's declarations, so every selector and
    // topic is unchanged, and a delegatecall reverts and emits exactly as the cell did.
    error ClaimAlreadyResolved();
    error DisputeOpen();
    error DisputeVerdicted();
    error DisputeWindowActive();
    error NoClaimRecord();
    error NoOpenDispute();
    error NotAdmin();
    error NotClaimed();
    error ProtocolDisputeDecisionPending();
    error ResolutionWindowActive();
    error StakeTransferFailed();
    error TransferFailed();

    event VulnerabilityClaimed(
        uint256 indexed id, address indexed claimant, bytes32 indexed toolId, bytes32 proofHash, uint256 stake
    );
    event OriginalAuditExploited(
        uint256 indexed originalAuditId, address indexed discoverer, uint256 amountPaid, address fixSubmitter
    );
    event ClaimExpired(uint256 indexed originalAuditId, address indexed claimant, uint256 amountPaid);
    // PC-110 (G1, VD-207(3)): declared in AuditCell's ABI and emitted nowhere until G1. Re-declared topic-identical here,
    // as G0's five were, so the delegatecall emits it from the cell's address under the cell's topic.
    event DisputeExpired(uint256 indexed originalAuditId, uint256 indexed disputeAuditId);
    event ClaimVindicated(uint256 indexed originalAuditId, address indexed claimant, uint256 stakeSlashed);
    event SpecInvalidated(uint256 indexed auditId, address indexed challenger, bytes32 indexed specToolId);

    function _specRunDigest(bytes32 specHash, bytes32 specToolId, bool pass, bytes32 errorsRoot)
        private
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

    function _requireValidSpecAtSubmit(
        CellStorage.Layout storage L,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot
    ) private view returns (bytes32 specPassDigest) {
        if (!(specHash != bytes32(0))) revert ZeroSpecHash();
        if (!(specToolId != bytes32(0))) revert SpecToolRequired();
        CellTypeDefs.Tool storage specTool = L.tools[specToolId];
        if (!(specTool.exists)) revert SpecToolNotRegistered();
        if (!(specTool.isSpecValidationTool)) revert NotSpecValidationTool();
        return _specRunDigest(specHash, specToolId, true, specErrorsRoot);
    }

    function _clampSubmitAuditWindow(CellStorage.Layout storage L, uint256 requested)
        private
        view
        returns (uint256)
    {
        uint256 floor = L.minAuditWindow;
        if (requested <= floor) return floor;
        // PC-90 (G4(e)): the parameter setter was bounded and the per-audit request was not, so a request near
        // `type(uint256).max` made confirm's `windowStart + auditWindow` revert for ever. A revert, not a clamp: the
        // submitter sees the refusal instead of a window it did not ask for.
        if (requested > CellLogicLib.MAX_AUDIT_WINDOW) revert AuditWindowTooLong();
        return requested;
    }

    function _submitAuditCommon(
        CellStorage.Layout storage L,
        address deployedAddress,
        bytes32 expectedCodehash,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        uint256 bounty,
        bytes32[] memory declaredVerdictTools,
        uint256 supersedesAuditId,
        uint256 auditWindow
    ) private view returns (bytes32 codehash, bytes32 specPassDigest, bytes32[] memory tools, uint256 window) {
        supersedesAuditId;
        if (!(bounty <= L.maxBountyPerSubmit)) revert BountyExceedsCap();
        if (!(deployedAddress != address(0))) revert DeployedAddressRequired();
        if (!(deployedAddress.code.length > 0)) revert NoContractAtAddress();

        codehash = deployedAddress.codehash;
        if (!(codehash == expectedCodehash)) revert ArtifactHashMismatch();

        specPassDigest = _requireValidSpecAtSubmit(L, specHash, specToolId, specErrorsRoot);
        tools = declaredVerdictTools;
        window = _clampSubmitAuditWindow(L, auditWindow);
    }

    function submitGenesisAuditExt(
        address deployedAddress,
        bytes32 expectedCodehash,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        uint256 bounty,
        bytes32[] calldata declaredVerdictTools,
        uint256 supersedesAuditId,
        uint256 auditWindow
    ) external returns (uint256 id) {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!L.genesisPending) revert GenesisNotPending();
        if (L.genesisAuditOpen) revert GenesisAuditOpen();
        // PC-89 (G6, I6): THE ONE-SHOT SLOT BELONGS TO THE BOOTSTRAPPER. It had no caller check, so a stranger holding
        // nothing opened the genesis audit and the intended protocol was refused. Closed BY DEFAULT - the admin, or the
        // genesis protocol the admin names - so the gate holds from the deploy block with no setter call to race.
        if (msg.sender != L.admin && msg.sender != L.genesisProtocol) revert NotGenesisProtocol();
        if (!(bounty > 0)) revert BountyRequired();

        (bytes32 codehash, bytes32 specPassDigest, bytes32[] memory tools, uint256 window) =
            _submitAuditCommon(
                L,
                deployedAddress,
                expectedCodehash,
                specHash,
                specToolId,
                specErrorsRoot,
                bounty,
                declaredVerdictTools,
                supersedesAuditId,
                auditWindow
            );

        id = CellLogicLib.createGenesisAuditExt(
            deployedAddress,
            codehash,
            specHash,
            specToolId,
            specPassDigest,
            bounty,
            window,
            tools,
            supersedesAuditId
        );
        L.genesisAuditId = id;
        L.genesisAuditOpen = true;
    }

    function submitAuditExt(
        address deployedAddress,
        bytes32 expectedCodehash,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        uint256 bounty,
        bytes32[] calldata declaredVerdictTools,
        uint256 supersedesAuditId,
        uint256 auditWindow
    ) external returns (uint256 id) {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(bounty > 0)) revert BountyRequired();

        (bytes32 codehash, bytes32 specPassDigest, bytes32[] memory tools, uint256 window) =
            _submitAuditCommon(
                L,
                deployedAddress,
                expectedCodehash,
                specHash,
                specToolId,
                specErrorsRoot,
                bounty,
                declaredVerdictTools,
                supersedesAuditId,
                auditWindow
            );

        id = CellLogicLib.createAuditExt(
            deployedAddress,
            codehash,
            specHash,
            specToolId,
            specPassDigest,
            bounty,
            window,
            false,
            false,
            0,
            tools,
            supersedesAuditId
        );
    }

    /// @notice Domain-agnostic intake (Pillar B). Pins a BARE `artifactHash` as O — any content-addressable
    ///         artifact, not just an EVM contract. `deployedAddress` is OPTIONAL: pass `address(0)` for a pure
    ///         off-chain artifact; pass a live address to also anchor it on-chain (then its codehash must equal
    ///         `artifactHash`). Everything downstream (caseRoot, dedupe, settlement) is already O-keyed on
    ///         `artifactHash`, so this only widens WHAT can be submitted — no settlement change.
    function submitArtifactAuditExt(
        bytes32 artifactHash,
        address deployedAddress,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        uint256 bounty,
        bytes32[] calldata declaredVerdictTools,
        uint256 supersedesAuditId,
        uint256 auditWindow
    ) external returns (uint256 id) {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(bounty > 0)) revert BountyRequired();
        if (!(bounty <= L.maxBountyPerSubmit)) revert BountyExceedsCap();
        if (!(artifactHash != bytes32(0))) revert ArtifactHashRequired();
        // Optional EVM anchor: if an address is supplied it must actually hold the pinned artifact.
        if (deployedAddress != address(0)) {
            if (!(deployedAddress.code.length > 0)) revert NoContractAtAddress();
            if (!(deployedAddress.codehash == artifactHash)) revert ArtifactHashMismatch();
        }

        bytes32 specPassDigest = _requireValidSpecAtSubmit(L, specHash, specToolId, specErrorsRoot);
        uint256 window = _clampSubmitAuditWindow(L, auditWindow);

        id = CellLogicLib.createAuditExt(
            deployedAddress,
            artifactHash,
            specHash,
            specToolId,
            specPassDigest,
            bounty,
            window,
            false,
            false,
            0,
            declaredVerdictTools,
            supersedesAuditId
        );
    }

    function submitFixAuditExt(
        address deployedFix,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        uint256 bounty,
        uint256 linkedAuditId
    ) external returns (uint256 id) {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(bounty > 0)) revert BountyRequired();
        if (!(bounty <= L.maxBountyPerSubmit)) revert BountyExceedsCap();
        if (!(deployedFix != address(0))) revert DeployedAddressRequired();
        if (!(deployedFix.code.length > 0)) revert NoContractAtAddress();
        if (!(linkedAuditId < L.nextAuditId)) revert InvalidLinkedAuditId();

        CellTypeDefs.Audit storage linked = L.audits[linkedAuditId];
        // bug_204: THE CALLER MUST BE THE LINKED ROW'S PROTOCOL. Every other precondition here describes
        // the ROW; none described the CALLER, and `AuditCell.submitFixAudit` forwards without one either.
        // A fix audit is a protocol remediating its OWN claimed row, and the slot it takes
        // (`activeFixAuditId`, :268) is one-per-claim and refuses every later filing (:248). With
        // `bounty > 0` as the only floor, ONE WEI bought a stranger the remediation slot on someone
        // else's row and locked the real protocol out for the life of the claim.
        if (!(msg.sender == linked.protocol)) revert OnlyLinkedProtocol();
        if (!(linked.state == CellTypeDefs.AuditState.Claimed)) revert LinkedNotClaimed();
        CellTypeDefs.VulnerabilityClaim storage linkedClaim = L.vulnerabilityClaims[linkedAuditId];
        if (!(linkedClaim.exists)) revert NoClaimOnLinked();
        if (!(!linkedClaim.resolved)) revert LinkedClaimResolved();
        if (!(L.activeFixAuditId[linkedAuditId] == 0)) revert FixAuditAlreadyOpen();

        bytes32 specPassDigest = _requireValidSpecAtSubmit(L, specHash, specToolId, specErrorsRoot);
        bytes32 artifactHash = deployedFix.codehash;

        bytes32[] memory emptyDeclared;
        id = CellLogicLib.createAuditExt(
            deployedFix,
            artifactHash,
            specHash,
            specToolId,
            specPassDigest,
            bounty,
            linked.auditWindow,
            true,
            false,
            linkedAuditId,
            emptyDeclared,
            0
        );
        L.activeFixAuditId[linkedAuditId] = id;
    }

    // ---------------------------------------------------------------- read-only views (re-landed 2026-07-05)
    // These were present in the Genesis cell-v2 and dropped in the satellite decomposition (backfill diff,
    // 2026-07-05). Re-landed here (library headroom) so the case-root formula stays SINGLE-SOURCE via
    // CellLogicLib._caseRootFromInputs — an integrator computing the case id off-chain gets the exact root the
    // submit path pins, with no risk of a re-implemented formula drifting.

    /// @notice Off-chain case-root preview — EVM-anchored form (deployedAddress must hold the artifact).
    function previewCaseRootExt(
        address deployedAddress,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        bytes32[] calldata declaredVerdictTools
    ) external view returns (bytes32) {
        if (!(deployedAddress != address(0))) revert DeployedAddressRequired();
        if (!(deployedAddress.code.length > 0)) revert NoContractAtAddress();
        bytes32 specPassDigest = _specRunDigest(specHash, specToolId, true, specErrorsRoot);
        return CellLogicLib._caseRootFromInputs(
            deployedAddress.codehash,
            specHash,
            specToolId,
            specPassDigest,
            CellLogicLib._sortToolIds(declaredVerdictTools)
        );
    }

    /// @notice Off-chain case-root preview from a BARE artifactHash (domain-agnostic form — no EVM contract).
    function previewCaseRootFromHashExt(
        bytes32 artifactHash,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        bytes32[] calldata declaredVerdictTools
    ) external pure returns (bytes32) {
        bytes32 specPassDigest = _specRunDigest(specHash, specToolId, true, specErrorsRoot);
        return CellLogicLib._caseRootFromInputs(
            artifactHash,
            specHash,
            specToolId,
            specPassDigest,
            CellLogicLib._sortToolIds(declaredVerdictTools)
        );
    }

    /// @notice Full declared-verdict-tool set for an audit (single-call enumerator; len + membership already
    ///         exist as separate getters). Reverts NoAudit for an unknown id.
    function declaredVerdictToolsOfExt(uint256 id)
        external
        view
        returns (bytes32[4] memory toolSlots, uint8 n)
    {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(id < L.nextAuditId)) revert NoAudit();
        n = L.declaredVerdictToolLen[id];
        bytes32[4] storage slots = L.declaredVerdictTools[id];
        for (uint256 i = 0; i < n; i++) {
            toolSlots[i] = slots[i];
        }
    }

    // ============================================ claim & dispute settlement (G0: moved from AuditCell)
    // Every caller gate below is the one AuditCell carried, checked against `msg.sender`, which a delegatecall
    // preserves. Reentrancy guards stay on the cell's entry points.

    function _settleClaimStake(CellTypeDefs.VulnerabilityClaim storage claim, bool slash) private {
        CellStorage.Layout storage L = CellStorage.layout();
        uint256 s = claim.stake;
        if (s == 0) return;
        if (slash) {
            address dest = L.treasuryEscrow != address(0) ? L.treasuryEscrow : L.admin;
            if (!L.token.transfer(dest, s)) revert TransferFailed();
            if (L.treasuryEscrow != address(0)) ISettlementSlashEscrow(L.treasuryEscrow).recordSlash(s);
        } else if (!L.token.transfer(claim.claimant, s)) {
            revert TransferFailed();
        }
    }

    function expireClaimDisputeExt(uint256 originalId) external {
        CellStorage.Layout storage L = CellStorage.layout();
        if (msg.sender != L.claimDisputeModule) revert NotAdmin();
        uint256 disputeId = L.activeDisputeAuditId[originalId];
        if (disputeId == 0) revert NoOpenDispute();
        CellTypeDefs.Audit storage d = L.audits[disputeId];
        // G4 (I3): ending the row changes its state, so a live overlay on the row freezes the expiry as it freezes confirm.
        CellLogicLib.requireNoSettlementBlockExt(disputeId);
        // PC-98 (G4(c), I4): a VERDICTED row is no longer refused outright. If nobody confirms it for one resolution window
        // past its audit window - the resolver refused, or the winner never called - it is released here, and
        // `CellLogicLib.confirmAudit` closes at that same instant (I2). Unverdicted rows keep the one window they had.
        uint256 due = d.windowStart + L.claimResolutionWindow;
        if (d.state == CellTypeDefs.AuditState.AwaitingWindow) due += d.auditWindow;
        if (block.timestamp < due) revert DisputeWindowActive();
        L.activeDisputeAuditId[originalId] = 0;
        _endDisputeRow(L, disputeId);
        emit DisputeExpired(originalId, disputeId);
        // G3 (PC-88(b)+(e)) as widened by PC-115 (G4, VD-216(3) Edge 1): a dispute that ends with no adjudication resolves
        // the claim UNADJUDICATED, WHOEVER FUNDED IT. G3 did this for a claimant-funded dispute only and left a
        // protocol-funded one's claim open, where `expireClaim` then slashed a claimant nobody had adjudicated. VD-207(2)'s
        // last clause is withdrawn: the funder test is deleted, not replaced.
        _resolveUnadjudicated(L, originalId);
    }

    /// @dev THE UNADJUDICATED RESOLUTION, one body for every way a claim's dispute ends without deciding it: the unverdicted
    ///      expiry and the grace release above, and a verdict that reproduces neither side (PC-98, reached from the claim
    ///      resolver through `resolveUnadjudicatedExt`). VD-117: no adjudicated outcome, no adjudicated loser - the stake
    ///      comes back, the fix pointer clears (I1), the row returns to its pre-claim state.
    ///
    ///      VD-216(4): when that pre-claim state is InAudit the claim was the AUDITOR'S OWN, and the in-audit clock is given
    ///      back the time the row spent Claimed - `submitVerdictAfterProof` refuses past `pickupTime + inAuditWindow`, and a
    ///      30-day claim window outlasts a 7-day in-audit window, so without this the restored row is already dead. The
    ///      bound VD-216(4) makes a condition of it is ONE SELF-CLAIM PER ROW, and it holds already: the self-claim path
    ///      refuses `ClaimAlreadyExists` on `exists`, which no exit clears. The auditor's own LAPSE (`expireClaimExt`)
    ///      gives back nothing.
    function _resolveUnadjudicated(CellStorage.Layout storage L, uint256 originalId) private {
        CellTypeDefs.VulnerabilityClaim storage claim = L.vulnerabilityClaims[originalId];
        if (!claim.exists || claim.resolved) return;
        claim.resolved = true;
        _settleClaimStake(claim, false);
        L.activeFixAuditId[originalId] = 0;
        CellTypeDefs.Audit storage o = L.audits[originalId];
        if (o.stateBeforeClaim == CellTypeDefs.AuditState.InAudit) o.pickupTime += block.timestamp - claim.claimTimestamp;
        CellLogicLib.setAuditStateExt(originalId, o.stateBeforeClaim);
        emit ClaimExpired(originalId, claim.claimant, 0);
    }

    function resolveUnadjudicatedExt(uint256 originalId) external {
        CellStorage.Layout storage L = CellStorage.layout();
        if (msg.sender != L.claimDisputeModule) revert NotAdmin();
        _resolveUnadjudicated(L, originalId);
    }

    /// @dev PC-91 bug_003 (G4(a)): a spec challenge that ends WITHOUT voiding its row gives the row's clock back the time it
    ///      was frozen. Both clocks of a live assignment run from `pickupTime` (the decision window while Assigned, the
    ///      in-audit window while InAudit), and neither timeout may fire under the freeze, so moving `pickupTime` forward by
    ///      the frozen part of the current clock is the whole cure. `frozenAt` is the challenge's OPEN time, which the
    ///      module keeps apart from `openedAt` because an arbiter reassignment resets that one.
    function resumeClockExt(uint256 auditId, uint256 frozenAt) external {
        CellStorage.Layout storage L = CellStorage.layout();
        if (msg.sender != L.specArbiterModule) revert NotAdmin();
        CellTypeDefs.Audit storage a = L.audits[auditId];
        if (
            a.pickupTime != 0
                && (a.state == CellTypeDefs.AuditState.Assigned || a.state == CellTypeDefs.AuditState.InAudit)
        ) {
            uint256 from = a.pickupTime > frozenAt ? a.pickupTime : frozenAt;
            a.pickupTime += block.timestamp - from;
        }
    }

    /// @dev G1 (PC-87's expiry half, PC-95(2), VD-199(3)): THE ONE WAY A DISPUTE ROW ENDS WITHOUT A VERDICT, shared by all
    ///      three lanes - the claim lane here, the spec-gap and integrity lanes through `settlementOverlayExt` kind 2.
    ///      Refunds the FUNDER, zeroes the field, clears the flag, and makes the row TERMINAL.
    ///
    ///      THE FUNDER, NOT `d.protocol` (bug_203/bug_302). Every lane pulls the bounty from its caller and records that
    ///      party as `lastDiscoverer`, while `d.protocol` is copied from the ORIGINAL row - the party being disputed.
    ///
    ///      ZEROED AND TERMINAL, BECAUSE G1 MADE THE FIELD PAYABLE. Before G1 an expired row kept `bounty` set and its
    ///      state live, and nothing paid it only because `bountyEscrowed` was never set (PC-87's note). With the row
    ///      escrowed from birth, a live row with a set field is a second payout waiting for its late confirm or void.
    ///      `Invalidated` is refused by `provePass`/`proveFail` (InAudit only) and by `confirmAudit` (AwaitingWindow
    ///      only), so the drawn auditor's late verdict cannot land on it. `_setAuditState` returns early on a row
    ///      already Invalidated (a void got there first), and that void already zeroed the field.
    function _endDisputeRow(CellStorage.Layout storage L, uint256 disputeId) private {
        CellTypeDefs.Audit storage d = L.audits[disputeId];
        uint256 refund = d.bounty;
        d.bounty = 0;
        d.bountyEscrowed = false;
        if (refund > 0 && !L.token.transfer(d.lastDiscoverer, refund)) revert TransferFailed();
        CellLogicLib.setAuditStateExt(disputeId, CellTypeDefs.AuditState.Invalidated);
    }

    function expireClaimExt(uint256 originalAuditId) external {
        CellStorage.Layout storage L = CellStorage.layout();
        CellTypeDefs.Audit storage a = L.audits[originalAuditId];
        CellTypeDefs.VulnerabilityClaim storage claim = L.vulnerabilityClaims[originalAuditId];
        if (a.state != CellTypeDefs.AuditState.Claimed) revert NotClaimed();
        if (!claim.exists) revert NoClaimRecord();
        if (claim.resolved) revert ClaimAlreadyResolved();
        if (L.activeDisputeAuditId[originalAuditId] != 0) revert DisputeOpen();
        if (L.claimDisputeModule != address(0)) {
            if (!IClaimDisputeModule(L.claimDisputeModule).claimantDisputeLaneOpen(originalAuditId)) {
                revert ProtocolDisputeDecisionPending();
            }
        }
        if (block.timestamp < claim.claimTimestamp + L.claimResolutionWindow) revert ResolutionWindowActive();

        claim.resolved = true;
        _settleClaimStake(claim, a.stateBeforeClaim != CellTypeDefs.AuditState.InAudit);
        L.activeFixAuditId[originalAuditId] = 0;
        CellLogicLib.setAuditStateExt(originalAuditId, a.stateBeforeClaim);
        emit ClaimExpired(originalAuditId, claim.claimant, 0);
    }

    function applyClaimFiledExt(uint256 originalAuditId, IClaimSettlementMutator.ClaimInput calldata c) external {
        CellStorage.Layout storage L = CellStorage.layout();
        if (msg.sender != L.claimDisputeModule) revert NotAdmin();
        CellTypeDefs.Audit storage a = L.audits[originalAuditId];
        a.stateBeforeClaim = a.state;
        CellLogicLib.setAuditStateExt(originalAuditId, CellTypeDefs.AuditState.Claimed);
        CellTypeDefs.VulnerabilityClaim storage claim = L.vulnerabilityClaims[originalAuditId];
        claim.claimant = c.claimant;
        claim.toolId = c.toolId;
        claim.proofHash = c.proofHash;
        claim.claimTimestamp = block.timestamp;
        claim.stake = c.stake;
        claim.resolved = false;
        claim.exists = true;
        claim.witnessPath = c.witnessPath;
        claim.evaluatorToolId = c.evaluatorToolId;
        claim.invariantId = c.invariantId;
        claim.locationCommitment = c.locationCommitment;
        claim.witnessCommitment = c.witnessCommitment;
        claim.contextRoot = c.contextRoot;
        emit VulnerabilityClaimed(originalAuditId, c.claimant, c.toolId, c.proofHash, c.stake);
    }

    function resolveClaimExt(
        uint256 originalId,
        address claimant,
        uint256 amount,
        bool vindicated,
        bool slashAuditorFailed
    ) external {
        CellStorage.Layout storage L = CellStorage.layout();
        if (msg.sender != L.claimDisputeModule) revert NotAdmin();
        CellTypeDefs.Audit storage a = L.audits[originalId];
        CellTypeDefs.VulnerabilityClaim storage claim = L.vulnerabilityClaims[originalId];
        claim.resolved = true;
        // PC-97 (G2, I1): the fix slot is one-per-CLAIM, so it clears on BOTH settlement exits, as it already did on lapse
        // (`expireClaimExt`) and on a void's release (`_releaseOpenClaim`). Left set by the vindicated branch, the next
        // claim's fix submission reverted `FixAuditAlreadyOpen` - masked until PC-81's cure let a next claim exist. The fix
        // audit row itself is NOT voided, on any exit: it is a paid audit of the protocol's fix and completes on its own.
        L.activeFixAuditId[originalId] = 0;
        if (vindicated) {
            _settleClaimStake(claim, true);
            CellLogicLib.setAuditStateExt(originalId, a.stateBeforeClaim);
            emit ClaimVindicated(originalId, claimant, amount);
            return;
        }
        _settleClaimStake(claim, false);
        if (slashAuditorFailed && a.stateBeforeClaim != CellTypeDefs.AuditState.InAudit && a.auditor != address(0)) {
            L.auditors[a.auditor].failed += 1;
        }
        if (claimant != address(0)) {
            L.auditors[claimant].found += 1;
            a.lastDiscoverer = claimant;
        }
        CellLogicLib.setAuditStateExt(originalId, CellTypeDefs.AuditState.Exploited);
        L.protocols[a.protocol].exploited += 1;
        emit OriginalAuditExploited(originalId, claimant, amount, address(0));
    }

    function settlementTokenExt(uint8 op, address from, address to, uint256 amount) external {
        CellStorage.Layout storage L = CellStorage.layout();
        if (
            msg.sender != L.claimDisputeModule && msg.sender != L.specGapModule && msg.sender != L.specArbiterModule
                && msg.sender != L.integrityReviewModule
        ) {
            revert NotAdmin();
        }
        if (op == 0) {
            if (amount > 0 && !L.token.transferFrom(from, address(this), amount)) revert StakeTransferFailed();
        } else if (op == 1) {
            if (amount > 0 && !L.token.transfer(to, amount)) revert TransferFailed();
        } else if (op == 2 && (msg.sender == L.specGapModule || msg.sender == L.specArbiterModule || msg.sender == L.integrityReviewModule)) {
            if (amount > 0 && L.treasuryEscrow != address(0)) {
                if (!L.token.transfer(L.treasuryEscrow, amount)) revert TransferFailed();
                ISettlementSlashEscrow(L.treasuryEscrow).recordSlash(amount);
            }
        }
    }

    function _voidAuditRow(CellStorage.Layout storage L, uint256 auditId, bool slashAuditorFailed) private {
        CellTypeDefs.Audit storage a = L.audits[auditId];
        if (a.bounty > 0 && a.bountyEscrowed && a.state != CellTypeDefs.AuditState.InBlock) {
            // G1: a DISPUTE row's bounty belongs to whoever funded the dispute (`lastDiscoverer`), not to the disputed
            // protocol - reachable only since G1 escrows dispute rows. The flag clears with the custody (VD-101).
            if (!L.token.transfer(a.isClaimDispute ? a.lastDiscoverer : a.protocol, a.bounty)) revert TransferFailed();
            a.bounty = 0;
            a.bountyEscrowed = false;
        }
        if (slashAuditorFailed && a.auditor != address(0)) L.auditors[a.auditor].failed += 1;
        if (a.artifactHash != bytes32(0)) {
            L.artifactRegistered[a.artifactHash] = false;
            delete L.artifactToAuditId[a.artifactHash];
        }
        CellLogicLib.setAuditStateExt(auditId, CellTypeDefs.AuditState.Invalidated);
    }

    /// @dev bug_104: voiding a row RELEASES any open claim on it, and BOTH void arms must do it.
    ///      The spec-arbiter arm always did this inline; the integrity arm did not, and after it set
    ///      `Invalidated` no path could ever return the stake. Factored here so the two arms cannot
    ///      drift apart again - the invariant is "a void settles what it voids", stated once.
    function _releaseOpenClaim(CellStorage.Layout storage L, uint256 auditId) private {
        CellTypeDefs.VulnerabilityClaim storage claim = L.vulnerabilityClaims[auditId];
        if (claim.exists && !claim.resolved) {
            if (claim.stake > 0 && !L.token.transfer(claim.claimant, claim.stake)) revert TransferFailed();
            claim.resolved = true;
            L.activeFixAuditId[auditId] = 0;
        }
    }

    function settlementOverlayExt(uint8 kind, uint8 op, uint256 auditId, address aux) external {
        CellStorage.Layout storage L = CellStorage.layout();
        if (op != 2) revert NotAdmin();
        if (kind == 0) {
            if (msg.sender != L.specArbiterModule) revert NotAdmin();
            _releaseOpenClaim(L, auditId);
            bytes32 toolId = L.audits[auditId].specToolId;
            L.audits[auditId].bounty = 0;
            // PC-95(6) / VD-187(b): `_payoutAndVoid` moved the tokens before calling here, so custody has ended and the
            // flag goes with it (VD-101). Left set, it was a custody flag that lied.
            L.audits[auditId].bountyEscrowed = false;
            if (L.audits[auditId].artifactHash != bytes32(0)) {
                L.artifactRegistered[L.audits[auditId].artifactHash] = false;
                delete L.artifactToAuditId[L.audits[auditId].artifactHash];
            }
            CellLogicLib.setAuditStateExt(auditId, CellTypeDefs.AuditState.Invalidated);
            emit SpecInvalidated(auditId, aux, toolId);
            return;
        }
        if (kind == 1) {
            if (msg.sender != L.integrityReviewModule) revert NotAdmin();
            // bug_104: release the claim BEFORE voiding. `_voidAuditRow` sets Invalidated, and every
            // stake-release route gates on `Claimed` (`expireClaim`, and ClaimDisputeModule's three
            // STATE_CLAIMED checks) - so a claim left open here is not delayed, it is UNREACHABLE.
            _releaseOpenClaim(L, auditId);
            _voidAuditRow(L, auditId, true);
            return;
        }
        if (kind == 2) {
            // G1: an UNVERDICTED dispute row's expiry, for the two lanes whose dispute pointer lives in their own module
            // (spec-gap, integrity). Only the resolver the row was spawned FOR may end it, and never once it holds a
            // verdict or has settled - each module keeps its own window check before calling.
            CellTypeDefs.Audit storage d = L.audits[auditId];
            if (
                !d.isClaimDispute || L.disputeResolver[auditId] != msg.sender
                    || (msg.sender != L.specGapModule && msg.sender != L.integrityReviewModule)
            ) revert NotAdmin();
            // VD-218(4) F1: a VERDICTED row may be ended once one resolution window has passed after its audit window - the
            // same instant `CellLogicLib.confirmAudit` closes for it. The integrity module refuses a verdicted row itself.
            if (
                d.state == CellTypeDefs.AuditState.InBlock
                    || (d.state == CellTypeDefs.AuditState.AwaitingWindow
                        && block.timestamp < d.windowStart + d.auditWindow + L.claimResolutionWindow)
            ) revert DisputeVerdicted();
            CellLogicLib.requireNoSettlementBlockExt(auditId); // G4 (I3), as on the claim lane's expiry
            _endDisputeRow(L, auditId);
            return;
        }
        revert NotAdmin();
    }
}

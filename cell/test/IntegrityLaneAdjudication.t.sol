// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./helpers/SpecValidationCellSetup.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/IntegrityReviewModule.sol";
import "../contracts/SpecArbiterModule.sol";
import "../contracts/SpecGapModule.sol";
import "../contracts/SpecGapLib.sol";
import "../contracts/WitnessClaimLib.sol";
import "genesis-tools/AuditResultV1.sol";

contract AdjudicationTarget {
    uint256 public x = 1;
}

/// @notice RED-DIRECTION ORACLE for the integrity lane's adjudication (VD-89 + VD-90, proposal section B).
///
/// THE DEFECT THIS PINS. The contest right belonged exclusively to the party a verdict PAYS. A SUSTAINED
/// integrity verdict returns the escrowed bounty to the protocol and increments the AUDITOR's `failed`, and
/// only the protocol could contest (`NotProtocol()`), so the one party harmed had no standing anywhere in the
/// lane. Nothing was at risk either: the reviewer was SELF-APPOINTED, a contest OVERWROTE the verdict with no
/// adjudication (`finalPass = contested ? contestPass : pass`), and both stakes were refunded outside any
/// outcome branch. The attack cost gas: protocol P opens through sock puppet X, sock puppet Y submits FAIL,
/// nobody contests because the only party with standing is winning, finalize - P recovers its bounty and the
/// honest auditor is unpaid and slashed.
///
/// THE RED-FIRST BASELINE, run before a line of the fix was written (HEAD e2d211b, warm cache):
///   [FAIL: NotProtocol()]                                      test_RED_auditor_has_standing_...
///   [FAIL: NotProtocol()]                                      test_RED_sockpuppet_fail_must_not_slash_...
///   [FAIL: next call did not revert as expected]               test_RED_protocol_may_not_contest_...
///   [FAIL: NotProtocol() != SpecChallengeActive()]             test_RED_escalation_cannot_pass_a_foreign_...
///   [PASS] test_GREEN_genuine_failure_still_sustains_and_voids
///   [PASS] test_GREEN_confirm_blocked_...
/// Four reds failing on their own assertions while both greens passed is what makes the later green mean
/// something: the file DISCRIMINATES, rather than being satisfiable by making the lane inert.
///
/// The tests below the PHASE 2 banner exercise capability that did not exist before the fix (the drawn
/// adjudicator, the `Contested` latch and its releases), so they could not be driven red against the old
/// module - there was nothing to call. That is stated rather than glossed.
contract IntegrityLaneAdjudicationTest is SpecValidationCellSetup {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    IntegrityReviewModule integrity;
    SpecArbiterModule specArbiter;
    SpecGapModule specGap;
    AdjudicationTarget target;

    address protocol = address(0xBEEF);
    address auditor = address(0xA11CE);
    address puppetOpener = address(0x999999);
    address puppetReviewer = address(0xE00E);
    address adjudicator = address(0xADD1);
    address challenger = address(0xCAFE);

    bytes32 specToolId = keccak256("spec-tool");
    bytes32 verdictToolId = keccak256("audit-tool");
    bytes32 integrityToolId = keccak256("integrity-tool");
    bytes32 specHash = keccak256("spec-hash");
    bytes32 resultRoot = keccak256("verdict-pass");
    bytes32 failErrorsRoot = keccak256("spec-tool-errors");
    bytes32 finderToolId = keccak256("finder-tool");
    bytes32 gapEvaluatorId = keccak256("gap-eval");
    bytes32 gapClassId = keccak256("CLASS_REENTRANCY");
    bytes32 gapInvariantId = keccak256("INVARIANT_GAP");
    bytes32 gapLocation = keccak256("loc-gap");
    bytes32 gapWitness = keccak256("witness-gap");

    uint256 bounty = 10_000 ether;
    uint256 reviewBounty = 1_000 ether;

    bool internal _extrasRegistered;

    function setUp() external {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        escrow = d.escrow;
        cell = d.cell;
        integrity = d.integrityReviewModule;
        specArbiter = d.specArbiterModule;
        specGap = d.specGapModule;
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        cell.registerTool(integrityToolId, false);
        cell.registerTool(finderToolId, false);
        cell.registerTool(gapEvaluatorId, false);
        cell.setToolWitnessFlags(gapEvaluatorId, true, true);
        specGap.registerClass(gapClassId);
        specArbiter.setSpecChallengeStake(500 ether);

        target = new AdjudicationTarget();
        token.genesisMint(protocol, 200_000 ether);
        token.genesisMint(auditor, 50_000 ether);
        token.genesisMint(puppetOpener, 50_000 ether);
        token.genesisMint(puppetReviewer, 50_000 ether);
        token.genesisMint(adjudicator, 50_000 ether);
        token.genesisMint(challenger, 50_000 ether);
        CellTestDeploy.attachMinter(d);

        // A non-zero increment gives `requiredHold` teeth, which is what `_drainBelowHold` needs in order to
        // make the adjudicator draw DETERMINISTIC instead of a coin flip between the two survivors.
        cell.setIncrement(1 ether);

        // Registered ALONE, so the original audit can only be assigned to the honest auditor.
        vm.prank(auditor);
        cell.register();
    }

    function _registerExtras() internal {
        if (_extrasRegistered) return;
        _extrasRegistered = true;
        vm.prank(puppetOpener);
        cell.register();
        vm.prank(puppetReviewer);
        cell.register();
        vm.prank(adjudicator);
        cell.register();
    }

    function _awaitingWindowAudit() internal returns (uint256 auditId) {
        bytes32[] memory tools = new bytes32[](1);
        tools[0] = verdictToolId;
        vm.startPrank(protocol);
        token.approve(address(cell), bounty);
        auditId = cell.submitAudit(
            address(target), address(target).codehash, specHash, specToolId, EMPTY_SPEC_ERRORS, bounty, tools, 0, 0
        );
        vm.stopPrank();
        assertEq(cell.auditAuditorOf(auditId), auditor, "fixture: audit must be assigned to the honest auditor");
        _registerExtras();
        _reachAwaitingWindow(cell, auditId, protocol, verdictToolId, resultRoot);
    }

    function _openReview(uint256 auditId, address opener) internal {
        vm.startPrank(opener);
        token.approve(address(cell), integrity.integrityFilingStake() + reviewBounty);
        integrity.openIntegrityReview(auditId, integrityToolId, reviewBounty);
        vm.stopPrank();
    }

    function _submitVerdict(uint256 auditId, address who, bool pass, bytes32 root) internal {
        vm.prank(who);
        integrity.submitIntegrityVerdict(auditId, pass, root);
    }

    /// G1 (VD-199(2)): a contest pulls TWO amounts - the stake this module disposes of, and the re-audit bounty the
    /// cell escrows on the dispute row and pays the drawn adjudicator at confirm. The re-audit is priced at the
    /// review's own bounty: the adjudicator re-does the review the opener priced.
    function _contest(uint256 auditId, address who, bool pass, bytes32 root) internal {
        vm.startPrank(who);
        token.approve(address(cell), integrity.integrityContestStake() + reviewBounty);
        integrity.contestIntegrityVerdict(auditId, pass, root);
        vm.stopPrank();
    }

    function _drainBelowHold(address account) internal {
        uint256 hold = cell.requiredHold(account);
        if (hold == 0) return;
        uint256 bal = token.balanceOf(account);
        if (bal > hold - 1) {
            vm.prank(account);
            token.transfer(address(0xDEAD), bal - (hold - 1));
        }
    }

    function _openChallenge(uint256 auditId) internal {
        vm.startPrank(challenger);
        token.approve(address(cell), specArbiter.specChallengeStake());
        specArbiter.challengeSpecInvalid(auditId, failErrorsRoot);
        vm.stopPrank();
        assertTrue(specArbiter.challengeActive(auditId), "fixture: spec challenge must be active");
    }

    // ------------------------------------------------------------------ RED 1: standing follows harm

    /// @notice RED. The party a SUSTAINED verdict harms - the auditor - must be able to contest it.
    ///         Against the unfixed module this reverts `NotProtocol()`: the only address with standing is the
    ///         one the verdict PAYS.
    function test_RED_auditor_has_standing_to_contest_a_sustained_verdict() external {
        uint256 auditId = _awaitingWindowAudit();
        _openReview(auditId, puppetOpener);
        _submitVerdict(auditId, puppetReviewer, false, keccak256("integrity-fail"));

        _contest(auditId, auditor, true, keccak256("auditor-contest-pass"));
    }

    /// @notice RED. The whole sock-puppet sequence must not end with the honest auditor slashed and the
    ///         protocol refunded. NOTE (deviation, see return package): the fix makes the attack CONTESTABLE,
    ///         not inert - so the sequence is driven THROUGH the auditor's contest, which is the standing the
    ///         fix creates. Against the unfixed module it stops at `NotProtocol()`.
    function test_RED_sockpuppet_fail_must_not_slash_auditor_or_refund_protocol() external {
        uint256 auditId = _awaitingWindowAudit();
        uint256 failedBefore = _auditorFailed(cell, auditor);
        uint256 protocolBefore = token.balanceOf(protocol);

        _openReview(auditId, puppetOpener);
        _submitVerdict(auditId, puppetReviewer, false, keccak256("integrity-fail"));

        _contest(auditId, auditor, true, keccak256("auditor-contest-pass"));

        assertEq(_auditorFailed(cell, auditor), failedBefore, "AUDITOR WAS SLASHED BY A SOCK-PUPPET VERDICT");
        assertEq(token.balanceOf(protocol), protocolBefore, "PROTOCOL WAS REFUNDED BY ITS OWN SOCK PUPPETS");
        assertTrue(
            _auditState(cell, auditId) != CellTypeDefs.AuditState.Invalidated, "ROW VOIDED BY AN UNADJUDICATED VERDICT"
        );
    }

    /// @notice RED. Nobody may contest a verdict in their own favour: SUSTAINED pays the protocol, so the
    ///         protocol has no standing against it. The unfixed module gives the protocol the ONLY standing.
    function test_RED_protocol_may_not_contest_a_verdict_in_its_own_favour() external {
        uint256 auditId = _awaitingWindowAudit();
        _openReview(auditId, puppetOpener);
        _submitVerdict(auditId, puppetReviewer, false, keccak256("integrity-fail"));

        vm.startPrank(protocol);
        token.approve(address(cell), integrity.integrityContestStake());
        vm.expectRevert();
        integrity.contestIntegrityVerdict(auditId, true, keccak256("protocol-contest-pass"));
        vm.stopPrank();
    }

    /// @notice RED (VD-90 (i)). An overlay may escalate through its OWN block and through NO foreign one:
    ///         with a spec challenge live on the same row, the integrity escalation must revert
    ///         `SpecChallengeActive`. The unfixed module never reaches the spawn at all.
    function test_RED_escalation_cannot_pass_a_foreign_spec_challenge() external {
        uint256 auditId = _awaitingWindowAudit();
        _openReview(auditId, puppetOpener);
        _submitVerdict(auditId, puppetReviewer, false, keccak256("integrity-fail"));
        _openChallenge(auditId);

        vm.startPrank(auditor);
        // G1: a contest pulls stake + re-audit bounty BEFORE the spawn, so approve both - otherwise this reverts on the
        // allowance and never reaches the foreign-block check it pins.
        token.approve(address(cell), integrity.integrityContestStake() + reviewBounty);
        vm.expectRevert(AuditCell.SpecChallengeActive.selector);
        integrity.contestIntegrityVerdict(auditId, true, keccak256("auditor-contest-pass"));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ GREEN: the lane must not go inert

    /// @notice GREEN before AND after. A genuine, uncontested integrity failure still sustains and still
    ///         voids the row. Without this, "make the lane safe" is satisfiable by making it toothless.
    function test_GREEN_genuine_failure_still_sustains_and_voids() external {
        uint256 auditId = _awaitingWindowAudit();
        uint256 failedBefore = _auditorFailed(cell, auditor);
        _openReview(auditId, puppetOpener);
        _submitVerdict(auditId, puppetReviewer, false, keccak256("integrity-fail"));

        vm.warp(block.timestamp + integrity.integrityContestWindow() + 1);
        integrity.finalizeIntegrityReview(auditId);

        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.Invalidated));
        assertEq(
            uint256(integrity.integrityReviewStatusOf(auditId)),
            uint256(IntegrityReviewModule.IntegrityReviewStatus.Sustained)
        );
        assertEq(_auditorFailed(cell, auditor), failedBefore + 1);
    }

    /// @notice GREEN before AND after (VD-90 (iii)). `confirmAudit`'s UNTOUCHED helper -
    ///         `_requireNoSettlementBlock`, the one the exemption was deliberately kept out of - still blocks
    ///         through Open, VerdictSubmitted AND Contested.
    function test_GREEN_confirm_blocked_through_open_verdict_and_contested() external {
        uint256 auditId = _awaitingWindowAudit();
        _openReview(auditId, puppetOpener);

        // No warp is needed: `confirmAudit` runs `_requireNoSettlementBlock` BEFORE its window check, so the
        // block is what reverts. Warping first would close the review window instead and prove nothing.
        vm.expectRevert(AuditCell.IntegrityReviewActive.selector);
        cell.confirmAudit(auditId);

        _submitVerdict(auditId, puppetReviewer, false, keccak256("integrity-fail"));
        vm.expectRevert(AuditCell.IntegrityReviewActive.selector);
        cell.confirmAudit(auditId);

        _contest(auditId, auditor, true, keccak256("auditor-contest-pass"));
        assertEq(
            uint256(integrity.integrityReviewStatusOf(auditId)),
            uint256(IntegrityReviewModule.IntegrityReviewStatus.Contested)
        );
        vm.expectRevert(AuditCell.IntegrityReviewActive.selector);
        cell.confirmAudit(auditId);
    }

    // ================================================================== PHASE 2: the adjudicated lane
    // Capability that did not exist before the fix. See the file header.

    /// @dev Returns the drawn adjudicator, asserting the property the whole design rests on: the re-auditor
    ///      is somebody NEITHER SIDE PICKED. `puppetOpener` is drained below its required hold before the
    ///      contest so exactly one candidate survives the draw and the fixture is deterministic.
    function _drawnAdjudicator(uint256 auditId) internal view returns (uint256 disputeId, address drawn) {
        disputeId = integrity.activeIntegrityDisputeId(auditId);
        assertTrue(disputeId != 0, "no re-audit row was spawned");
        drawn = cell.auditAuditorOf(disputeId);
        assertTrue(drawn != address(0), "no adjudicator was drawn");
        assertTrue(drawn != protocol, "the audited protocol may not adjudicate itself");
        assertTrue(drawn != auditor, "the audit's own auditor may not adjudicate");
        assertTrue(drawn != puppetReviewer, "the reviewer under review may not adjudicate (extraExclude)");
    }

    function _resolveReaudit(uint256 auditId, bool pass) internal returns (uint256 disputeId, address drawn) {
        (disputeId, drawn) = _drawnAdjudicator(auditId);
        vm.prank(drawn);
        cell.acceptAudit(disputeId, EMPTY_SPEC_ERRORS);
        vm.prank(drawn);
        if (pass) {
            cell.provePass(disputeId, integrityToolId, keccak256("reaudit-pass"));
        } else {
            cell.proveFail(disputeId, integrityToolId, keccak256("reaudit-fail"));
        }
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);
    }

    /// @notice THE LATCH RELEASES ON OUTCOME ONE (acceptance 4). The adjudicator upholds the contest: the
    ///         review clears, the confirm block lifts, the row confirms, and the stakes settle with a REAL
    ///         LOSER - the contester is made whole, the opener's filing stake is slashed to the escrow.
    function test_contest_upheld_clears_the_row_releases_the_latch_and_slashes_the_opener() external {
        uint256 auditId = _awaitingWindowAudit();
        uint256 failedBefore = _auditorFailed(cell, auditor);
        _openReview(auditId, puppetOpener);
        _submitVerdict(auditId, puppetReviewer, false, keccak256("integrity-fail"));
        _drainBelowHold(puppetOpener);

        uint256 filing = integrity.integrityFilingStake();
        uint256 openerBefore = token.balanceOf(puppetOpener);
        uint256 reviewerBefore = token.balanceOf(puppetReviewer);
        uint256 auditorBefore = token.balanceOf(auditor);
        uint256 escrowBefore = escrow.escrowBalance();

        _contest(auditId, auditor, true, keccak256("auditor-contest-pass"));
        assertEq(
            uint256(integrity.integrityReviewStatusOf(auditId)),
            uint256(IntegrityReviewModule.IntegrityReviewStatus.Contested)
        );
        assertTrue(integrity.confirmBlocked(auditId), "the latch must hold for the WHOLE re-audit");

        (, address drawn) = _drawnAdjudicator(auditId);
        assertEq(drawn, adjudicator, "fixture: exactly one candidate must survive the draw");
        uint256 adjudicatorBefore = token.balanceOf(adjudicator);

        _resolveReaudit(auditId, true);

        assertEq(
            uint256(integrity.integrityReviewStatusOf(auditId)),
            uint256(IntegrityReviewModule.IntegrityReviewStatus.Cleared)
        );
        assertEq(_auditorFailed(cell, auditor), failedBefore, "a false FAIL must not slash the auditor");
        assertEq(
            token.balanceOf(auditor), auditorBefore - reviewBounty,
            "the upheld contester gets its stake back and has paid for the re-audit it asked for"
        );
        assertEq(
            token.balanceOf(adjudicator), adjudicatorBefore + reviewBounty,
            "PC-87 on the integrity lane: the DRAWN adjudicator is paid for the re-audit (D1 option A)"
        );
        assertEq(token.balanceOf(puppetOpener), openerBefore, "the opener's filing stake does NOT come back");
        assertEq(escrow.escrowBalance(), escrowBefore + filing, "the filing stake is slashed to the escrow");
        assertEq(token.balanceOf(puppetReviewer), reviewerBefore + reviewBounty);

        // THE RELEASE, DRIVEN: the block is gone and the row settles the way it would have without the review.
        assertFalse(integrity.confirmBlocked(auditId), "the Contested latch must release");
        cell.confirmAudit(auditId);
        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.InBlock));
    }

    /// @notice THE LATCH RELEASES ON OUTCOME TWO (acceptance 4), and the lane keeps its teeth: the
    ///         adjudicator agrees with the reviewer, so the review still sustains, the row is still voided
    ///         and the auditor still slashed - but now it is a DRAWN verdict that did it, and the contester
    ///         who was wrong pays for it.
    function test_contest_failed_sustains_the_row_releases_the_latch_and_slashes_the_contester() external {
        uint256 auditId = _awaitingWindowAudit();
        uint256 failedBefore = _auditorFailed(cell, auditor);
        _openReview(auditId, puppetOpener);
        _submitVerdict(auditId, puppetReviewer, false, keccak256("integrity-fail"));
        _drainBelowHold(puppetOpener);

        uint256 filing = integrity.integrityFilingStake();
        uint256 stake = integrity.integrityContestStake();
        uint256 openerBefore = token.balanceOf(puppetOpener);
        uint256 reviewerBefore = token.balanceOf(puppetReviewer);
        uint256 auditorBefore = token.balanceOf(auditor);
        uint256 escrowBefore = escrow.escrowBalance();

        _contest(auditId, auditor, true, keccak256("auditor-contest-pass"));
        uint256 adjudicatorBefore = token.balanceOf(adjudicator);
        _resolveReaudit(auditId, false);

        assertEq(
            uint256(integrity.integrityReviewStatusOf(auditId)),
            uint256(IntegrityReviewModule.IntegrityReviewStatus.Sustained)
        );
        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.Invalidated));
        assertEq(_auditorFailed(cell, auditor), failedBefore + 1, "a genuine failure still slashes");
        assertEq(
            token.balanceOf(auditor), auditorBefore - stake - reviewBounty,
            "the failed contester loses its stake, and paid for the re-audit"
        );
        assertEq(
            token.balanceOf(adjudicator), adjudicatorBefore + reviewBounty,
            "the drawn adjudicator is paid for the re-audit on this outcome too"
        );
        assertEq(escrow.escrowBalance(), escrowBefore + stake, "the loser's stake is slashed to the escrow");
        assertEq(token.balanceOf(puppetOpener), openerBefore + filing, "a vindicated opener is made whole");
        assertEq(token.balanceOf(puppetReviewer), reviewerBefore + reviewBounty);
        assertFalse(integrity.confirmBlocked(auditId), "the Contested latch must release on this outcome too");
    }

    /// @notice VD-90 (ii). NO DOUBLE ESCALATION: one contest per review, whoever asks.
    function test_no_double_escalation_while_contested() external {
        uint256 auditId = _awaitingWindowAudit();
        _openReview(auditId, puppetOpener);
        _submitVerdict(auditId, puppetReviewer, false, keccak256("integrity-fail"));
        _drainBelowHold(puppetOpener);
        _contest(auditId, auditor, true, keccak256("auditor-contest-pass"));

        vm.startPrank(auditor);
        token.approve(address(cell), integrity.integrityContestStake());
        vm.expectRevert(IntegrityReviewModule.AlreadyContested.selector);
        integrity.contestIntegrityVerdict(auditId, true, keccak256("second-contest"));
        vm.stopPrank();

        vm.startPrank(protocol);
        token.approve(address(cell), integrity.integrityContestStake());
        vm.expectRevert(IntegrityReviewModule.AlreadyContested.selector);
        integrity.contestIntegrityVerdict(auditId, true, keccak256("second-contest-other-party"));
        vm.stopPrank();
    }

    /// @notice THE THIRD RELEASE (acceptance 4, the written half made runnable). A re-audit that NEVER
    ///         resolves - nobody drawable, or the drawn adjudicator silent - must not hold the row forever.
    ///         No adjudicated outcome means no adjudicated loser: every escrowed amount goes back to whoever
    ///         put it in, the audit row is NOT voided, and the block releases.
    function test_unresolved_reaudit_voids_the_contest_and_releases_the_latch() external {
        uint256 auditId = _awaitingWindowAudit();
        uint256 failedBefore = _auditorFailed(cell, auditor);
        _openReview(auditId, puppetOpener);
        _submitVerdict(auditId, puppetReviewer, false, keccak256("integrity-fail"));
        _drainBelowHold(puppetOpener);

        uint256 filing = integrity.integrityFilingStake();
        uint256 openerBefore = token.balanceOf(puppetOpener);
        uint256 reviewerBefore = token.balanceOf(puppetReviewer);
        uint256 auditorBefore = token.balanceOf(auditor);
        uint256 escrowBefore = escrow.escrowBalance();

        _contest(auditId, auditor, true, keccak256("auditor-contest-pass"));
        (uint256 disputeId,) = _drawnAdjudicator(auditId);

        // The drawn adjudicator never acts. Before the resolution window closes the row stays latched.
        vm.expectRevert(IntegrityReviewModule.ContestResolutionWindowOpen.selector);
        integrity.expireContestedIntegrityReview(auditId);

        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        integrity.expireContestedIntegrityReview(auditId);

        assertEq(
            uint256(integrity.integrityReviewStatusOf(auditId)),
            uint256(IntegrityReviewModule.IntegrityReviewStatus.Void)
        );
        assertEq(integrity.activeIntegrityDisputeId(auditId), 0, "the re-audit pointer must be cleared");
        assertEq(token.balanceOf(auditor), auditorBefore, "the contester is made whole");
        assertEq(token.balanceOf(puppetOpener), openerBefore + filing + reviewBounty, "the opener is made whole");
        assertEq(token.balanceOf(puppetReviewer), reviewerBefore, "an unadjudicated review pays nobody");
        assertEq(escrow.escrowBalance(), escrowBefore, "nobody is slashed by a non-verdict");
        assertEq(_auditorFailed(cell, auditor), failedBefore, "a non-verdict may not void the row");
        assertTrue(_auditState(cell, auditId) != CellTypeDefs.AuditState.Invalidated);

        assertFalse(integrity.confirmBlocked(auditId), "the unstick path must release the latch");
        cell.confirmAudit(auditId);
        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.InBlock));
        assertTrue(disputeId != 0);
        // G1: the re-audit row the contest spawned ENDS with the contest (I1, PC-95(2)) - its bounty went back to the
        // contester above, so the row must not keep a payable field or take a late verdict.
        assertEq(
            uint256(_auditState(cell, disputeId)), uint256(CellTypeDefs.AuditState.Invalidated),
            "the unresolved re-audit row is TERMINAL"
        );
        assertEq(cell.getAudit(disputeId).bounty, 0, "its bounty field is zeroed");
        assertFalse(cell.auditBountyEscrowed(disputeId), "the flag clears where custody ends (VD-101)");
    }

    /// @notice The unstick path may not be used to DODGE an adjudication that is about to land.
    function test_expire_refuses_while_the_reaudit_holds_a_verdict() external {
        uint256 auditId = _awaitingWindowAudit();
        _openReview(auditId, puppetOpener);
        _submitVerdict(auditId, puppetReviewer, false, keccak256("integrity-fail"));
        _drainBelowHold(puppetOpener);
        _contest(auditId, auditor, true, keccak256("auditor-contest-pass"));

        (uint256 disputeId, address drawn) = _drawnAdjudicator(auditId);
        vm.prank(drawn);
        cell.acceptAudit(disputeId, EMPTY_SPEC_ERRORS);
        vm.prank(drawn);
        cell.proveFail(disputeId, integrityToolId, keccak256("reaudit-fail"));

        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        vm.expectRevert(IntegrityReviewModule.ContestVerdicted.selector);
        integrity.expireContestedIntegrityReview(auditId);
    }

    /// @notice The other half of standing: a CLEARED verdict is the protocol's to contest, not the auditor's.
    function test_cleared_verdict_is_contestable_only_by_the_protocol() external {
        uint256 auditId = _awaitingWindowAudit();
        _openReview(auditId, puppetOpener);
        _submitVerdict(auditId, puppetReviewer, true, keccak256("integrity-cleared"));

        vm.startPrank(auditor);
        token.approve(address(cell), integrity.integrityContestStake());
        vm.expectRevert(IntegrityReviewModule.NoStanding.selector);
        integrity.contestIntegrityVerdict(auditId, false, keccak256("auditor-stall"));
        vm.stopPrank();

        _drainBelowHold(puppetOpener);
        _contest(auditId, protocol, false, keccak256("protocol-contest-fail"));
        assertEq(
            uint256(integrity.integrityReviewStatusOf(auditId)),
            uint256(IntegrityReviewModule.IntegrityReviewStatus.Contested)
        );
    }

    /// @notice THE EXEMPTION IS CALLER-SCOPED, PROVEN FROM THE OTHER SIDE (VD-90, the symmetry claim).
    ///         The rule is "any overlay may escalate through its OWN block; none through another's", so it is
    ///         not enough to show the integrity module blocked by a spec challenge - a DIFFERENT overlay must
    ///         still be blocked by the INTEGRITY module's block. Here the spec-gap overlay tries to spawn its
    ///         own re-audit on a row carrying a live integrity review and is refused.
    ///
    ///         WHAT THIS TEST DOES AND DOES NOT CATCH, so it is not read as more than it is. It catches the
    ///         obvious wrong fix - deleting or unconditionally skipping the integrity limb at the spawn site,
    ///         which would let ANY overlay walk past an integrity review. It does NOT discriminate against a
    ///         `msg.sender` carve-out placed inside `_requireNoSettlementBlock` itself: at every other call
    ///         site that helper's `msg.sender` is an auditor or a protocol, never this module, so the wider
    ///         form has no demonstrable behavioural difference today. That is exactly why VD-90 ruled on the
    ///         FORM rather than the effect - the wider version is wrong the day a new caller appears - and
    ///         the form is a diff-level fact, visible in `CellLogicLib._requireNoForeignSettlementBlock`.
    function test_a_foreign_overlay_still_cannot_spawn_past_the_integrity_block() external {
        uint256 auditId = _awaitingWindowAudit();
        bytes32 pinnedArtifact = address(target).codehash;
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(auditId);
        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.InBlock));

        // a spec gap, filed by the adjudicator address (registered, and neither protocol nor auditor)
        WitnessClaimLib.Binding memory b = WitnessClaimLib.Binding({
            evaluatorToolId: gapEvaluatorId,
            invariantId: gapInvariantId,
            locationCommitment: gapLocation,
            witnessCommitment: gapWitness,
            contextRoot: bytes32(0)
        });
        bytes32 gapFailRoot = WitnessClaimLib.resultRoot(b, pinnedArtifact, specHash, AuditResultV1.VERDICT_FAIL);
        vm.startPrank(adjudicator);
        token.approve(address(cell), cell.requiredClaimStake(auditId));
        specGap.openSpecGap(
            auditId, gapClassId, finderToolId, gapFailRoot, gapEvaluatorId, gapInvariantId, gapLocation,
            gapWitness, bytes32(0)
        );
        vm.stopPrank();

        // ... and an integrity review on the SAME row, which blocks confirm
        _openReview(auditId, puppetOpener);
        assertTrue(integrity.confirmBlocked(auditId));

        uint256 minB = (bounty * 5000) / 10_000;
        vm.startPrank(protocol);
        token.approve(address(cell), minB + 1_000 ether);
        vm.expectRevert(AuditCell.IntegrityReviewActive.selector);
        specGap.protocolContestSpecGap(auditId, gapClassId, minB);
        vm.stopPrank();
    }

    /// @notice `resolveFromDispute` is the CELL's to call. Nobody else may hand this module a verdict.
    function test_resolve_from_dispute_is_cell_only() external {
        uint256 auditId = _awaitingWindowAudit();
        _openReview(auditId, puppetOpener);
        _submitVerdict(auditId, puppetReviewer, false, keccak256("integrity-fail"));
        _drainBelowHold(puppetOpener);
        _contest(auditId, auditor, true, keccak256("auditor-contest-pass"));
        (uint256 disputeId,) = _drawnAdjudicator(auditId);

        vm.prank(protocol);
        vm.expectRevert(IntegrityReviewModule.NotCell.selector);
        integrity.resolveFromDispute(auditId, disputeId);
    }
}

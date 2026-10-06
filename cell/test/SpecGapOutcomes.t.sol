// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/SpecGapModule.sol";
import "../contracts/SpecGapLib.sol";
import "../contracts/IntegrityReviewModule.sol";
import "../contracts/WitnessClaimLib.sol";
import "genesis-tools/AuditResultV1.sol";
import "./helpers/CellTestDeploy.sol";

contract OutcomeGapTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice Every way a spec-gap dispute row can end, on both lanes, pinned as the code does it today (2026-09-30).
///         This file PINS; it does not judge. Where a row below is an open question, the test asserts the current
///         behaviour and its comment names the question, so the suite stays green and the day the rule changes the test
///         that must change is named here (the vault's Q3 answer, 2026-09-30).
///
///         The outcome table, and where each row is driven:
///           CONTEST LANE (protocolContestSpecGap)
///             C1  re-run replays the filer (FAIL)   -> Confirmed, contest stake to the filer    SpecGapDisputeCustody.t.sol
///             C2  re-run replays the protocol (PASS) -> False, filing stake slashed              SpecGapDisputeCustody.t.sol
///             C3  re-run replays neither side        -> gap Filed and latched; one exit, refund  here
///             C4  verdicted, nobody confirms         -> released at the F1 instant, both refunded here
///             C5  never verdicted                    -> expired, both refunded                    SpecGapDisputeCustody.t.sol,
///                                                       and the gap's one exit afterwards         here
///             C6  row voided BEFORE confirm          -> bounty to the funder, gap untouched       here
///             C7  row voided AFTER confirm           -> failed += 1 only, the outcome stands      here
///           DEMONSTRATION LANE (fundSpecGapDemonstration)
///             D1  FAIL -> reward to the filer; D2 PASS or neither -> reward to the funder;
///             D3  expiry -> both halves to the funder                                           SpecGapDemonstration.t.sol
///             D4  the protocol adopts WHILE a demonstration is open -> both payments land        here
///         And one side effect the voids above expose: a dispute row carries its ORIGINAL's artifact hash
///         (CellLogicLib.initDisputeRow), so voiding the dispute row unregisters the original's artifact: PC-82's
///         second route (its first is ArtifactRegistrationVoid.t.sol).                                        here
contract SpecGapOutcomesTest is Test {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    SpecGapModule specGap;
    IntegrityReviewModule integrity;

    address protocol = address(0xA11CE);
    address auditorA = address(0xB0B);
    address filer = address(0xDEAD);
    address auditorC = address(0xC0DE);
    address funder = address(0xF00D);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 finderToolId = keccak256("finder-tool");
    bytes32 gapEvaluatorId = keccak256("gap-eval");
    bytes32 integrityToolId = keccak256("integrity-tool");
    bytes32 classId = keccak256("CLASS_REENTRANCY");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");
    bytes32 invariantId = keccak256("INVARIANT_GAP");
    bytes32 locationCommitment = keccak256("loc-gap");
    bytes32 witnessCommitment = keccak256("witness-gap");

    uint256 constant BOUNTY = 40_000 ether;
    uint256 constant CONTEST_STAKE = 500 ether;
    uint256 constant REWARD = 3_000 ether;
    uint256 constant REVIEW_BOUNTY = 1_000 ether;
    uint256 nextSalt = 1;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        escrow = d.escrow;
        specGap = d.specGapModule;
        integrity = d.integrityReviewModule;
        token.genesisMint(protocol, 300_000 ether);
        token.genesisMint(filer, 100_000 ether);
        token.genesisMint(auditorC, 50 ether);
        token.genesisMint(funder, 300_000 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        cell.registerTool(finderToolId, false);
        cell.registerTool(gapEvaluatorId, false);
        cell.registerTool(integrityToolId, false);
        cell.setToolWitnessFlags(gapEvaluatorId, true, true);
        specGap.registerClass(classId);
        vm.prank(auditorA);
        cell.register();
        vm.prank(filer);
        cell.register();
        vm.prank(auditorC);
        cell.register();
    }

    // ------------------------------------------------------------------ fixture

    function _root(bytes32 pinnedArtifact, uint8 verdict) internal view returns (bytes32) {
        WitnessClaimLib.Binding memory b = WitnessClaimLib.Binding({
            evaluatorToolId: gapEvaluatorId,
            invariantId: invariantId,
            locationCommitment: locationCommitment,
            witnessCommitment: witnessCommitment,
            contextRoot: bytes32(0)
        });
        return WitnessClaimLib.resultRoot(b, pinnedArtifact, specHash, verdict);
    }

    function _minB() internal pure returns (uint256) {
        return (BOUNTY * 5000) / 10_000;
    }

    function _failed(address a) internal view returns (uint256 failed) {
        (, failed,,,,) = cell.auditors(a);
    }

    /// An InBlock original with a gap FILED on it. Returns the filing stake the filer put up.
    function _filedGap() internal returns (uint256 id, bytes32 pinned, uint256 filingStake) {
        OutcomeGapTarget target = new OutcomeGapTarget(nextSalt++);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.startPrank(protocol);
        token.approve(address(cell), BOUNTY);
        id = cell.submitAudit(address(target), address(target).codehash, specHash, specToolId, specErrors, BOUNTY, declared, 0, 0);
        vm.stopPrank();
        pinned = address(target).codehash;
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditorA);
        cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);

        filingStake = cell.requiredClaimStake(id);
        vm.startPrank(filer);
        token.approve(address(cell), filingStake);
        specGap.openSpecGap(
            id, classId, finderToolId, _root(pinned, AuditResultV1.VERDICT_FAIL), gapEvaluatorId, invariantId,
            locationCommitment, witnessCommitment, bytes32(0)
        );
        vm.stopPrank();
    }

    function _contest(uint256 id) internal returns (uint256 disputeId) {
        vm.startPrank(protocol);
        token.approve(address(cell), _minB() + CONTEST_STAKE);
        disputeId = specGap.protocolContestSpecGap(id, classId, _minB());
        vm.stopPrank();
        assertEq(cell.auditAuditorOf(disputeId), auditorC, "fixture: the only drawable re-runner");
    }

    function _fund(uint256 id) internal returns (uint256 disputeId) {
        vm.startPrank(funder);
        token.approve(address(cell), _minB() + REWARD);
        disputeId = specGap.fundSpecGapDemonstration(id, classId, _minB(), REWARD);
        vm.stopPrank();
        assertEq(cell.auditAuditorOf(disputeId), auditorC, "fixture: the only drawable re-runner");
    }

    /// The drawn re-runner submits a verdict on `root`. The row is AwaitingWindow afterwards; nobody has confirmed it.
    function _verdict(uint256 disputeId, bool fail, bytes32 root) internal {
        vm.prank(auditorC);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(auditorC);
        if (fail) cell.proveFail(disputeId, gapEvaluatorId, root);
        else cell.provePass(disputeId, gapEvaluatorId, root);
    }

    function _confirm(uint256 disputeId) internal {
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);
    }

    /// An integrity review on the DISPUTE row, opened by the filer (the party a wrong verdict harms), reviewed FAIL by
    /// auditorA, uncontested, finalized: the cell voids the row through overlay kind 1. Returns what the filer spent.
    function _integrityVoid(uint256 disputeId) internal returns (uint256 filerCost) {
        uint256 total = integrity.integrityFilingStake() + REVIEW_BOUNTY;
        uint256 filerBefore = token.balanceOf(filer);
        vm.startPrank(filer);
        token.approve(address(cell), total);
        integrity.openIntegrityReview(disputeId, integrityToolId, REVIEW_BOUNTY);
        vm.stopPrank();
        vm.prank(auditorA);
        integrity.submitIntegrityVerdict(disputeId, false, keccak256("the re-run did not replay"));
        vm.warp(block.timestamp + integrity.integrityContestWindow() + 1);
        integrity.finalizeIntegrityReview(disputeId);
        assertEq(
            uint256(cell.auditStateOf(disputeId)), uint256(CellTypeDefs.AuditState.Invalidated), "the void landed"
        );
        filerCost = filerBefore - token.balanceOf(filer);
    }

    /// A contested gap that has lost every road to Confirmed: silence, a second contest, adoption and demonstration are
    /// all refused, and `expireSpecGap` is the one exit, refunding the filer (G3, VD-186(a), VD-117).
    function _assertLatchedWithOneExit(uint256 id, uint256 filingStake) internal {
        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.Filed), "the gap is still Filed");
        assertTrue(specGap.specGapContested(id, classId), "and its one contest is spent");
        assertEq(specGap.activeSpecGapDisputeAuditId(id, classId), 0, "with no dispute open");

        vm.warp(block.timestamp + cell.protocolDecisionWindow() + 1);
        vm.expectRevert(SpecGapModule.GapContested.selector);
        specGap.confirmSpecGapSilence(id, classId);

        vm.startPrank(protocol);
        token.approve(address(cell), _minB() + CONTEST_STAKE);
        vm.expectRevert(SpecGapModule.ContestAlreadyOpen.selector);
        specGap.protocolContestSpecGap(id, classId, _minB());
        token.approve(address(cell), 1_000 ether);
        vm.expectRevert(SpecGapModule.NotConfirmable.selector);
        specGap.adoptSpecGap(id, classId, 1_000 ether);
        vm.stopPrank();

        vm.startPrank(funder);
        token.approve(address(cell), _minB() + REWARD);
        vm.expectRevert(SpecGapModule.NotDemonstrable.selector);
        specGap.fundSpecGapDemonstration(id, classId, _minB(), REWARD);
        vm.stopPrank();

        uint256 filerBefore = token.balanceOf(filer);
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        specGap.expireSpecGap(id, classId);
        assertEq(token.balanceOf(filer), filerBefore + filingStake, "the one exit refunds the filer, and pays them nothing");
        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.Expired));
    }

    // ------------------------------------------------------------------ C3: the re-run replays neither side

    /// VD-218(4) F1/(c): a neither-root is an OUTCOME. The re-runner is paid, the contest stake goes home, and the gap is
    /// left Filed with its latch set. OPEN (VD-218(4), with the operator): on this lane that does not cost one bounty, it
    /// costs a TRUE gap its confirmation - no road to Confirmed survives it. The hold-and-second-draw position would change
    /// what this test asserts; it is a later cut under VD-237(3).
    function test_C3_a_neither_root_pays_the_rerunner_and_leaves_the_gap_with_no_road_to_confirmed() public {
        (uint256 id,, uint256 filingStake) = _filedGap();
        uint256 protocolBefore = token.balanceOf(protocol);
        uint256 disputeId = _contest(id);
        uint256 runnerBefore = token.balanceOf(auditorC);
        uint256 filerBefore = token.balanceOf(filer);

        _verdict(disputeId, true, keccak256("a root that binds to nothing on file"));
        _confirm(disputeId);

        assertEq(token.balanceOf(auditorC), runnerBefore + _minB(), "the re-runner is paid the dispute bounty at confirm");
        assertEq(token.balanceOf(protocol), protocolBefore - _minB(), "the contest stake came home; the bounty was spent");
        assertEq(token.balanceOf(filer), filerBefore, "the filer is neither paid nor slashed");
        _assertLatchedWithOneExit(id, filingStake);
        assertEq(token.balanceOf(address(cell)), 0, "the cell holds nothing once the gap has left");
    }

    // ------------------------------------------------------------------ C4: verdicted, nobody confirms

    /// VD-218(4) F1: confirm and expiry partition time at windowStart + auditWindow + claimResolutionWindow. At that
    /// instant confirm is refused and expiry releases the row: the funder is refunded, the re-runner who did the work is
    /// not paid, and the gap is left exactly as C3 leaves it.
    function test_C4_an_unconfirmed_verdict_is_released_at_the_F1_instant_and_the_rerunner_is_unpaid() public {
        (uint256 id, bytes32 pinned, uint256 filingStake) = _filedGap();
        uint256 protocolBefore = token.balanceOf(protocol);
        uint256 disputeId = _contest(id);
        uint256 runnerBefore = token.balanceOf(auditorC);

        _verdict(disputeId, true, _root(pinned, AuditResultV1.VERDICT_FAIL));
        CellTypeDefs.Audit memory d = cell.getAudit(disputeId);
        vm.warp(d.windowStart + d.auditWindow + cell.claimResolutionWindow());

        vm.expectRevert(AuditCell.DisputeReleasable.selector);
        cell.confirmAudit(disputeId);
        specGap.expireSpecGapDispute(id, classId);

        assertEq(token.balanceOf(protocol), protocolBefore, "bounty and contest stake both come back to the protocol");
        assertEq(token.balanceOf(auditorC), runnerBefore, "the re-runner's verdict, a FAIL that held, is paid nothing");
        assertEq(uint256(cell.auditStateOf(disputeId)), uint256(CellTypeDefs.AuditState.Invalidated));
        _assertLatchedWithOneExit(id, filingStake);
        assertEq(token.balanceOf(address(cell)), 0);
    }

    // ------------------------------------------------------------------ C5: never verdicted, then the gap's exit

    /// G1 expiry of an unverdicted contest row is driven in SpecGapDisputeCustody.t.sol. What it does not show is the gap
    /// afterwards: the same latched state as C3, with the filer's refund as the only exit.
    function test_C5_after_an_unverdicted_contest_expires_the_gap_has_one_exit_and_it_refunds_the_filer() public {
        (uint256 id,, uint256 filingStake) = _filedGap();
        uint256 protocolBefore = token.balanceOf(protocol);
        uint256 disputeId = _contest(id);
        vm.prank(auditorC);
        cell.acceptAudit(disputeId, specErrors); // holds the row, then goes silent

        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        specGap.expireSpecGapDispute(id, classId);

        assertEq(token.balanceOf(protocol), protocolBefore, "the contest cost the protocol nothing");
        _assertLatchedWithOneExit(id, filingStake);
        assertEq(token.balanceOf(address(cell)), 0);
    }

    // ------------------------------------------------------------------ C6: row voided BEFORE confirm

    /// The check VD-218(4)(c) names, used in time. The re-runner's PASS - the protocol's side, whether replayed or copied -
    /// is voided by an integrity review before anyone confirms it: the bounty goes back to the funder (G1), the re-runner
    /// takes a `failed`, and the gap is untouched. It ends latched, as C3. The filer is protected, and paid for it: the
    /// review bounty is theirs to lose.
    function test_C6_a_verdict_voided_before_confirm_refunds_the_funder_and_leaves_the_gap_untouched() public {
        (uint256 id, bytes32 pinned, uint256 filingStake) = _filedGap();
        uint256 protocolBefore = token.balanceOf(protocol);
        uint256 disputeId = _contest(id);
        uint256 failedBefore = _failed(auditorC);

        _verdict(disputeId, false, _root(pinned, AuditResultV1.VERDICT_PASS));
        uint256 filerCost = _integrityVoid(disputeId);

        assertEq(filerCost, REVIEW_BOUNTY, "the filer's protection cost them the review bounty, and their filing came back");
        assertEq(_failed(auditorC), failedBefore + 1, "the re-runner takes a failed");
        assertEq(token.balanceOf(protocol), protocolBefore - CONTEST_STAKE, "the dispute bounty is back with its funder");
        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.Filed), "no verdict reached the gap");
        assertEq(specGap.activeSpecGapDisputeAuditId(id, classId), disputeId, "the module still names the voided row");

        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        specGap.expireSpecGapDispute(id, classId);
        assertEq(token.balanceOf(protocol), protocolBefore, "the contest stake comes back at the row's expiry");
        _assertLatchedWithOneExit(id, filingStake);
        assertEq(token.balanceOf(address(cell)), 0);
    }

    // ------------------------------------------------------------------ C7: row voided AFTER confirm

    /// The same review, one confirm too late. The PASS has already settled the gap: False, the filing stake slashed. The
    /// void finds the row InBlock, so nothing is refunded (SubmitAuditLib._voidAuditRow) and nothing reaches the gap: the
    /// re-runner takes a `failed` and keeps the bounty, and the filer's loss stands. OPEN (payout family, 2026-09-30): a
    /// re-runner who COPIES the protocol's root without replaying is indistinguishable here from one who replayed, and
    /// after confirm no path undoes what it settled.
    function test_C7_a_void_after_confirm_takes_a_failed_and_undoes_nothing() public {
        (uint256 id, bytes32 pinned,) = _filedGap();
        uint256 disputeId = _contest(id);
        _verdict(disputeId, false, _root(pinned, AuditResultV1.VERDICT_PASS));
        _confirm(disputeId);
        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.False), "fixture: settled False");

        uint256 runnerAfterPay = token.balanceOf(auditorC);
        uint256 protocolBefore = token.balanceOf(protocol);
        uint256 failedBefore = _failed(auditorC);
        uint256 filerCost = _integrityVoid(disputeId);

        assertEq(_failed(auditorC), failedBefore + 1, "the re-runner takes a failed");
        assertEq(token.balanceOf(auditorC), runnerAfterPay, "and keeps the bounty it was paid at confirm");
        assertEq(token.balanceOf(protocol), protocolBefore, "no refund: the row was InBlock");
        assertEq(filerCost, REVIEW_BOUNTY, "the filer paid for the review");
        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.False), "the gap stays False");
        assertEq(token.balanceOf(address(cell)), 0, "and the slashed filing stake is gone from the cell for good");
    }

    // ------------------------------------------------------------------ D4: adoption during an open demonstration

    /// The protocol may adopt while a demonstration is open: `adoptSpecGap` has no dispute-slot guard where its siblings
    /// do (SpecGapModule :257, :266, :304, :344, :368), and the demonstration's settlement runs before any status check.
    /// Both payments land, the same two as adoption AFTER a paid demonstration (SpecGapDemonstration.t.sol:204). OPEN
    /// (the operator's design question, 2026-09-30): should adoption wait for the demonstration - (a), one line,
    /// `ContestOpen` - or moot it and send the reward home - (b)? Under (a) this test becomes the refusal.
    function test_D4_the_protocol_may_adopt_during_an_open_demonstration_and_a_FAIL_still_pays_the_reward() public {
        (uint256 id, bytes32 pinned,) = _filedGap();
        vm.warp(block.timestamp + cell.protocolDecisionWindow() + 1);
        specGap.confirmSpecGapSilence(id, classId);
        uint256 disputeId = _fund(id);
        uint256 filerBefore = token.balanceOf(filer);

        vm.startPrank(protocol);
        token.approve(address(cell), 1_000 ether);
        specGap.adoptSpecGap(id, classId, 1_000 ether);
        vm.stopPrank();
        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.Adopted));
        assertEq(specGap.activeSpecGapDisputeAuditId(id, classId), disputeId, "the demonstration is still open");

        _verdict(disputeId, true, _root(pinned, AuditResultV1.VERDICT_FAIL));
        _confirm(disputeId);

        assertEq(token.balanceOf(filer), filerBefore + 1_000 ether + REWARD, "adoption and the reward both reach the filer");
        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.Adopted), "status not rewritten");
        assertEq(token.balanceOf(address(cell)), 0);
    }

    function test_D4_the_protocol_may_adopt_during_an_open_demonstration_and_a_PASS_sends_the_reward_home() public {
        (uint256 id, bytes32 pinned,) = _filedGap();
        vm.warp(block.timestamp + cell.protocolDecisionWindow() + 1);
        specGap.confirmSpecGapSilence(id, classId);
        uint256 disputeId = _fund(id);
        uint256 funderBefore = token.balanceOf(funder);

        vm.startPrank(protocol);
        token.approve(address(cell), 1_000 ether);
        specGap.adoptSpecGap(id, classId, 1_000 ether);
        vm.stopPrank();

        _verdict(disputeId, false, _root(pinned, AuditResultV1.VERDICT_PASS));
        _confirm(disputeId);

        assertEq(token.balanceOf(funder), funderBefore + REWARD, "the reward goes home, the re-run bounty went to the re-runner");
        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.Adopted));
        assertEq(token.balanceOf(address(cell)), 0);
    }

    // ------------------------------------------------------------------ side effect: the original's artifact

    /// A dispute row copies its original's artifact hash (CellLogicLib.initDisputeRow) and never registers it (the
    /// registration skips dispute rows). Both void arms clear `artifactRegistered[a.artifactHash]` and
    /// `artifactToAuditId[a.artifactHash]` (SubmitAuditLib._voidAuditRow; overlay kind 0) - so voiding the DISPUTE row
    /// unregisters the ORIGINAL row's artifact while the original stays InBlock. The kind-2 structural spawn's
    /// `ArtifactAlreadyAudited` guard and every `artifactToAuditId` lookup read that mapping. This is PC-82 (bug_002 of
    /// the 2026-09-15 second-family review) by a SECOND ROUTE: ArtifactRegistrationVoid.t.sol reaches it through
    /// supersession, this file through any dispute row, on all three lanes, by an uncontested integrity FAIL. One defect,
    /// two routes. Deferred by design to the value-bearing cell's window (VD-234; hull bytes under VD-237(3)). The cure,
    /// clear only when `artifactToAuditId[hash] == auditId`, flips both pins together.
    function test_voiding_a_dispute_row_unregisters_its_ORIGINAL_rows_artifact() public {
        (uint256 id, bytes32 pinned,) = _filedGap();
        assertTrue(cell.artifactRegistered(pinned), "fixture: the original registered its artifact");
        assertEq(cell.artifactToAuditId(pinned), id);

        uint256 disputeId = _contest(id);
        assertEq(cell.getAudit(disputeId).artifactHash, pinned, "the dispute row carries the original's artifact");
        _verdict(disputeId, false, _root(pinned, AuditResultV1.VERDICT_PASS));
        _integrityVoid(disputeId);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InBlock), "the original is untouched");
        assertFalse(cell.artifactRegistered(pinned), "yet its artifact is no longer registered");
        assertEq(cell.artifactToAuditId(pinned), 0, "and its lookup is gone");
    }
}

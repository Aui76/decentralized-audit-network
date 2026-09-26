// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/SpecGapModule.sol";
import "../contracts/SpecGapLib.sol";
import "../contracts/WitnessClaimLib.sol";
import "genesis-tools/AuditResultV1.sol";
import "./helpers/CellTestDeploy.sol";

contract PrecedenceTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice The hull window's G3 (walkthrough section 3, invariant I2: two permissionless exits from one state need a
///         precedence written in code, not in the windows) - the spec-gap trio and PC-91's second half.
///
///         (a) THE SPEC-GAP TRIO. `confirmSpecGapSilence` (Confirmed, filer refunded) and `expireSpecGap` (Expired, filer
///             slashed) were two permissionless exits from the same Filed state with opposite economics, and after the
///             protocol's window whoever transacted first decided (PC-49's note, VD-172(4)(a)). A contest that expired
///             unaudited left the gap Filed with nothing recording that the protocol had ever spoken, so silence-confirm
///             confirmed it as if it had not (VD-186(a)). And the protocol could contest again at once, for free.
///         (c) PC-91 bug_004: after `pickupTime + inAuditWindow` a late verdict and a permissionless timeout were BOTH
///             valid, and ordering decided.
///
///         RED on the pre-G3 bytes; each test names what it refuses.
contract ExitPrecedenceTest is Test {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    SpecGapModule specGap;

    address protocol = address(0xA11CE);
    address auditorA = address(0xB0B);
    address filer = address(0xDEAD);
    address auditorC = address(0xC0DE);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 finderToolId = keccak256("finder-tool");
    bytes32 gapEvaluatorId = keccak256("gap-eval");
    bytes32 classId = keccak256("CLASS_REENTRANCY");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");
    bytes32 invariantId = keccak256("INVARIANT_GAP");
    bytes32 locationCommitment = keccak256("loc-gap");
    bytes32 witnessCommitment = keccak256("witness-gap");

    uint256 constant BOUNTY = 40_000 ether;
    uint256 constant CONTEST_STAKE = 500 ether;
    uint256 nextSalt = 1;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        escrow = d.escrow;
        specGap = d.specGapModule;
        token.genesisMint(protocol, 300_000 ether);
        token.genesisMint(filer, 50_000 ether);
        token.genesisMint(auditorC, 50 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        cell.registerTool(finderToolId, false);
        cell.registerTool(gapEvaluatorId, false);
        cell.setToolWitnessFlags(gapEvaluatorId, true, true);
        specGap.registerClass(classId);
        vm.prank(auditorA);
        cell.register();
        vm.prank(filer);
        cell.register();
        vm.prank(auditorC);
        cell.register();
    }

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

    function _filedGap() internal returns (uint256 id) {
        PrecedenceTarget target = new PrecedenceTarget(nextSalt++);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.startPrank(protocol);
        token.approve(address(cell), BOUNTY);
        id = cell.submitAudit(address(target), address(target).codehash, specHash, specToolId, specErrors, BOUNTY, declared, 0, 0);
        vm.stopPrank();
        bytes32 pinned = address(target).codehash;
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditorA);
        cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);
        vm.startPrank(filer);
        token.approve(address(cell), cell.requiredClaimStake(id));
        specGap.openSpecGap(
            id, classId, finderToolId, _root(pinned, AuditResultV1.VERDICT_FAIL), gapEvaluatorId, invariantId,
            locationCommitment, witnessCommitment, bytes32(0)
        );
        vm.stopPrank();
    }

    /// A filed gap the protocol contested, whose re-audit expired with no verdict.
    function _contestedAndExpired() internal returns (uint256 id) {
        id = _filedGap();
        uint256 minB = (BOUNTY * 5000) / 10_000;
        vm.startPrank(protocol);
        token.approve(address(cell), minB + CONTEST_STAKE);
        specGap.protocolContestSpecGap(id, classId, minB);
        vm.stopPrank();
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        specGap.expireSpecGapDispute(id, classId);
        assertTrue(specGap.specGapContested(id, classId), "the contest is latched, and stays latched past its expiry");
    }

    // ------------------------------------------------------------------ (a) the spec-gap trio

    /// VD-172(4)(a): once the protocol's window has passed on an UNCONTESTED gap, silence has won - the only exit is
    /// Confirmed. `expireSpecGap` may not slash the filer after the protocol said nothing.
    function test_uncontested_gap_after_silence_cannot_be_expired_only_confirmed() public {
        uint256 id = _filedGap();
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1); // past BOTH windows (30 d > 2 d)

        vm.expectRevert(SpecGapModule.SilenceHasConfirmed.selector);
        specGap.expireSpecGap(id, classId);

        specGap.confirmSpecGapSilence(id, classId);
        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.Confirmed));
    }

    /// VD-186(a): a protocol that CONTESTED has spoken. When its re-audit expires unaudited, silence-confirm is refused.
    function test_a_contested_gap_whose_dispute_expired_is_not_confirmed_by_silence() public {
        uint256 id = _contestedAndExpired();
        vm.expectRevert(SpecGapModule.GapContested.selector);
        specGap.confirmSpecGapSilence(id, classId);
    }

    /// I4 for the latch: the dead contest does not freeze the gap. Its one exit is expiry, and with no adjudicated outcome
    /// there is no adjudicated loser (VD-117) - the filer's stake is REFUNDED, not slashed.
    function test_a_contested_gap_whose_dispute_expired_expires_with_the_filer_refunded() public {
        uint256 id = _contestedAndExpired();
        uint256 filerBefore = token.balanceOf(filer);
        uint256 escrowBefore = escrow.escrowBalance();
        (,,,,,,,,,, uint256 filingStake,,,) = specGap.specGaps(id, classId);
        assertGt(filingStake, 0, "fixture: the filer staked");

        specGap.expireSpecGap(id, classId);

        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.Expired));
        assertEq(token.balanceOf(filer), filerBefore + filingStake, "the filer is refunded: no verdict, no loser");
        assertEq(escrow.escrowBalance(), escrowBefore, "nothing is slashed");
    }

    /// One contest per gap: re-contesting after an unaudited expiry would restart the stall for free.
    function test_a_gap_cannot_be_contested_twice() public {
        uint256 id = _contestedAndExpired();
        uint256 minB = (BOUNTY * 5000) / 10_000;
        vm.startPrank(protocol);
        token.approve(address(cell), minB + CONTEST_STAKE);
        vm.expectRevert(SpecGapModule.ContestAlreadyOpen.selector);
        specGap.protocolContestSpecGap(id, classId, minB);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ VD-218(4) F1: PC-98's shape on the spec-gap lane

    function _contested() internal returns (uint256 id, uint256 disputeId, address drawn) {
        id = _filedGap();
        uint256 minB = (BOUNTY * 5000) / 10_000;
        vm.startPrank(protocol);
        token.approve(address(cell), minB + CONTEST_STAKE);
        disputeId = specGap.protocolContestSpecGap(id, classId, minB);
        vm.stopPrank();
        drawn = cell.auditAuditorOf(disputeId);
        assertTrue(drawn != address(0), "fixture: a re-auditor was drawn");
        vm.prank(drawn);
        cell.acceptAudit(disputeId, specErrors);
    }

    /// A contest verdict that replays NEITHER side is an outcome at confirm: the contest ends unadjudicated, the protocol's
    /// contest stake comes back, and the gap - latched, its contest dead - keeps its one exit, expiry with the filer refunded.
    /// Before, the resolver reverted `ContestWitnessMismatch` and expiry refused the verdicted row: the drawn re-auditor froze
    /// the gap and both stakes at will.
    function test_F1_a_non_replaying_contest_verdict_is_an_outcome_not_a_freeze() public {
        (uint256 id, uint256 disputeId, address drawn) = _contested();
        vm.prank(drawn);
        cell.provePass(disputeId, gapEvaluatorId, keccak256("replays-nothing"));
        vm.warp(block.timestamp + cell.getAudit(disputeId).auditWindow + 1);

        uint256 protocolBefore = token.balanceOf(protocol);
        cell.confirmAudit(disputeId);
        assertEq(specGap.activeSpecGapDisputeAuditId(id, classId), 0, "the contest slot is clear");
        assertEq(token.balanceOf(protocol) - protocolBefore, CONTEST_STAKE, "no adjudicated loser: the contest stake is back");
        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.Filed), "the gap is still open");

        uint256 filerBefore = token.balanceOf(filer);
        (,,,,,,,,,, uint256 filingStake,,,) = specGap.specGaps(id, classId);
        vm.warp(block.timestamp + cell.claimResolutionWindow());
        specGap.expireSpecGap(id, classId); // the contested gap's one exit
        assertEq(token.balanceOf(filer) - filerBefore, filingStake, "and the filer is refunded");
    }

    /// The belt: a contest verdict nobody confirms for one resolution window past its audit window is released, and confirm
    /// closes at that same instant (I2).
    function test_F1_an_unconfirmed_contest_verdict_is_released_after_one_grace_window_and_confirm_closes_there() public {
        (uint256 id, uint256 disputeId, address drawn) = _contested();
        vm.prank(drawn);
        cell.provePass(disputeId, gapEvaluatorId, keccak256("any-root"));
        uint256 releaseAt = cell.getAudit(disputeId).windowStart + cell.getAudit(disputeId).auditWindow
            + cell.claimResolutionWindow();
        uint256 minB = (BOUNTY * 5000) / 10_000;

        vm.warp(releaseAt - 1);
        vm.expectRevert();
        specGap.expireSpecGapDispute(id, classId);

        vm.warp(releaseAt);
        vm.expectRevert();
        cell.confirmAudit(disputeId);
        uint256 protocolBefore = token.balanceOf(protocol);
        specGap.expireSpecGapDispute(id, classId);
        assertEq(uint256(cell.auditStateOf(disputeId)), uint256(CellTypeDefs.AuditState.Invalidated), "the row ended");
        assertEq(token.balanceOf(protocol) - protocolBefore, minB + CONTEST_STAKE, "its funder refunded, bounty and stake");
        assertEq(token.balanceOf(drawn), 50 ether, "nobody confirmed, so nobody was paid");
    }

    // ------------------------------------------------------------------ (c) PC-91 bug_004

    /// The verdict path closes where the timeout opens: at `pickupTime + inAuditWindow` exactly, the verdict still lands;
    /// one second later only the timeout does. Half-open on one side, so the two intervals partition time.
    function test_a_verdict_is_refused_once_the_in_audit_timeout_is_open() public {
        PrecedenceTarget target = new PrecedenceTarget(nextSalt++);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.startPrank(protocol);
        token.approve(address(cell), BOUNTY);
        uint256 id = cell.submitAudit(address(target), address(target).codehash, specHash, specToolId, specErrors, BOUNTY, declared, 0, 0);
        vm.stopPrank();
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        address a = cell.auditAuditorOf(id);
        vm.prank(a);
        cell.acceptAudit(id, specErrors);
        uint256 pickup = cell.getAudit(id).pickupTime;

        vm.warp(pickup + cell.inAuditWindow() + 1);
        vm.prank(a);
        vm.expectRevert(CellLogicLib.InAuditWindowPassed.selector);
        cell.provePass(id, verdictToolId, resultRoot);

        cell.advanceInAudit(id); // the only valid call now
        assertTrue(cell.auditStateOf(id) != CellTypeDefs.AuditState.InAudit, "the timeout fired");
    }

    function test_a_verdict_at_the_last_in_audit_second_still_lands() public {
        PrecedenceTarget target = new PrecedenceTarget(nextSalt++);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.startPrank(protocol);
        token.approve(address(cell), BOUNTY);
        uint256 id = cell.submitAudit(address(target), address(target).codehash, specHash, specToolId, specErrors, BOUNTY, declared, 0, 0);
        vm.stopPrank();
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        address a = cell.auditAuditorOf(id);
        vm.prank(a);
        cell.acceptAudit(id, specErrors);
        uint256 pickup = cell.getAudit(id).pickupTime;

        vm.warp(pickup + cell.inAuditWindow());
        vm.expectRevert(CellLogicLib.InAuditWindowActive.selector);
        cell.advanceInAudit(id); // not yet
        vm.prank(a);
        cell.provePass(id, verdictToolId, resultRoot);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.AwaitingWindow));
    }
}

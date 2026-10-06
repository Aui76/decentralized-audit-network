// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/SpecGapModule.sol";
import "../contracts/SpecGapLib.sol";
import "../contracts/WitnessClaimLib.sol";
import "genesis-tools/AuditResultV1.sol";
import "./helpers/CellTestDeploy.sol";

contract DemoGapTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice The spec-gap payout hole, closed (spec-gap-funded-demonstration-proposal, 2026-09-30). Before this file's
///         bytes the overlay had ONE payout, `adoptSpecGap`, callable by the protocol alone: a gap the protocol conceded,
///         or let silence confirm, and then never adopted paid its discoverer nothing, with no path for anyone else to
///         pay them. `fundSpecGapDemonstration` is PK-4's tier 3 (dan-core F-83 Part B B6, parked 2026-06-16): anyone but
///         the filer puts a re-run bounty and a discovery reward behind a recorded gap; the cell draws a re-runner with
///         the filer and the funder excluded; a FAIL replay of the filer's witness pays the reward to the filer, and
///         anything else returns it to the funder. Every token that enters the cell here leaves it exactly once.
contract SpecGapDemonstrationTest is Test {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    SpecGapModule specGap;

    address protocol = address(0xA11CE);
    address auditorA = address(0xB0B);
    address filer = address(0xDEAD);
    address auditorC = address(0xC0DE);
    address funder = address(0xF00D);

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
    uint256 constant REWARD = 3_000 ether;
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
        token.genesisMint(funder, 300_000 ether);
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

    function _minB() internal pure returns (uint256) {
        return (BOUNTY * 5000) / 10_000;
    }

    /// An InBlock original with a gap FILED on it. The protocol has not answered yet.
    function _filedGap() internal returns (uint256 id, bytes32 pinned) {
        DemoGapTarget target = new DemoGapTarget(nextSalt++);
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

        vm.startPrank(filer);
        token.approve(address(cell), cell.requiredClaimStake(id));
        specGap.openSpecGap(
            id, classId, finderToolId, _root(pinned, AuditResultV1.VERDICT_FAIL), gapEvaluatorId, invariantId,
            locationCommitment, witnessCommitment, bytes32(0)
        );
        vm.stopPrank();
    }

    /// The hole's exact shape: the protocol says nothing, silence confirms the gap, and the protocol never adopts.
    function _silenceConfirmedGap() internal returns (uint256 id, bytes32 pinned) {
        (id, pinned) = _filedGap();
        vm.warp(block.timestamp + cell.protocolDecisionWindow() + 1);
        specGap.confirmSpecGapSilence(id, classId);
        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.Confirmed));
    }

    function _fund(uint256 id) internal returns (uint256 disputeId) {
        vm.startPrank(funder);
        token.approve(address(cell), _minB() + REWARD);
        disputeId = specGap.fundSpecGapDemonstration(id, classId, _minB(), REWARD);
        vm.stopPrank();
        assertEq(cell.auditAuditorOf(disputeId), auditorC, "fixture: the only drawable re-runner");
        assertTrue(cell.auditBountyEscrowed(disputeId), "the demonstration row holds its re-run bounty in escrow (G1)");
        assertEq(specGap.demonstrationReward(disputeId), REWARD, "the reward is recorded on the row");
        assertEq(specGap.activeSpecGapDisputeAuditId(id, classId), disputeId, "the gap's dispute slot is taken");
    }

    function _run(uint256 disputeId, bytes32 pinned, bool fail) internal {
        vm.prank(auditorC);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(auditorC);
        if (fail) cell.proveFail(disputeId, gapEvaluatorId, _root(pinned, AuditResultV1.VERDICT_FAIL));
        else cell.provePass(disputeId, gapEvaluatorId, _root(pinned, AuditResultV1.VERDICT_PASS));
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);
    }

    // ------------------------------------------------------------------ the payout, on the hole's exact shape

    function test_a_FAIL_replay_pays_the_filer_the_reward_the_rerunner_the_bounty_and_the_cell_holds_nothing() public {
        (uint256 id, bytes32 pinned) = _silenceConfirmedGap();
        uint256 disputeId = _fund(id);
        uint256 filerBefore = token.balanceOf(filer);
        uint256 runnerBefore = token.balanceOf(auditorC);
        uint256 funderBefore = token.balanceOf(funder);

        _run(disputeId, pinned, true);

        assertEq(token.balanceOf(filer), filerBefore + REWARD, "the discoverer is paid, and the protocol paid nothing");
        assertEq(token.balanceOf(auditorC), runnerBefore + _minB(), "the re-runner is paid the re-run bounty by the cell");
        assertEq(token.balanceOf(funder), funderBefore, "the funder's money went where they put it");
        assertEq(token.balanceOf(address(cell)), 0, "the cell holds NOTHING once the demonstration has settled");
        assertEq(specGap.demonstrationReward(disputeId), 0, "the reward leaves the row with the payment");
        assertEq(specGap.activeSpecGapDisputeAuditId(id, classId), 0, "the slot is free again");
        assertEq(
            uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.Confirmed),
            "the gap's status is not rewritten by a demonstration"
        );
    }

    function test_a_PASS_replay_returns_the_reward_to_the_funder_and_leaves_the_gap_as_it_was() public {
        (uint256 id, bytes32 pinned) = _silenceConfirmedGap();
        uint256 disputeId = _fund(id);
        uint256 filerBefore = token.balanceOf(filer);
        uint256 funderBefore = token.balanceOf(funder);

        _run(disputeId, pinned, false);

        assertEq(token.balanceOf(filer), filerBefore, "the filer is not paid on a PASS, and loses nothing either");
        assertEq(token.balanceOf(funder), funderBefore + REWARD, "the reward goes back to the funder");
        assertEq(token.balanceOf(address(cell)), 0, "the cell holds NOTHING once the demonstration has settled");
        assertEq(
            uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.Confirmed),
            "one third-party re-run does not un-confirm what the protocol's silence confirmed"
        );
    }

    function test_a_declined_gap_is_demonstrable_and_a_FAIL_pays_the_filer() public {
        (uint256 id, bytes32 pinned) = _filedGap();
        vm.prank(protocol);
        specGap.protocolDeclineSpecGapRelevance(id, classId);
        uint256 disputeId = _fund(id);
        uint256 filerBefore = token.balanceOf(filer);

        _run(disputeId, pinned, true);

        assertEq(token.balanceOf(filer), filerBefore + REWARD, "relevance is the protocol's call; the fact still pays");
        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.Declined));
        assertEq(token.balanceOf(address(cell)), 0);
    }

    function test_the_protocol_may_still_adopt_after_a_demonstration_paid() public {
        (uint256 id, bytes32 pinned) = _silenceConfirmedGap();
        _run(_fund(id), pinned, true);
        uint256 filerBefore = token.balanceOf(filer);
        vm.startPrank(protocol);
        token.approve(address(cell), 1_000 ether);
        specGap.adoptSpecGap(id, classId, 1_000 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(filer), filerBefore + 1_000 ether, "adoption is a second payment, not a replacement");
        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.Adopted));
    }

    // ------------------------------------------------------------------ what it refuses

    function test_a_filed_gap_is_not_demonstrable_because_the_protocol_window_is_theirs() public {
        (uint256 id,) = _filedGap();
        vm.startPrank(funder);
        token.approve(address(cell), _minB() + REWARD);
        vm.expectRevert(SpecGapModule.NotDemonstrable.selector);
        specGap.fundSpecGapDemonstration(id, classId, _minB(), REWARD);
        vm.stopPrank();
    }

    function test_the_filer_cannot_fund_their_own_demonstration() public {
        (uint256 id,) = _silenceConfirmedGap();
        vm.startPrank(filer);
        token.approve(address(cell), _minB() + REWARD);
        vm.expectRevert(SpecGapModule.FunderCannotBeFiler.selector);
        specGap.fundSpecGapDemonstration(id, classId, _minB(), REWARD);
        vm.stopPrank();
    }

    function test_a_zero_reward_and_a_bounty_under_the_floor_are_refused() public {
        (uint256 id,) = _silenceConfirmedGap();
        vm.startPrank(funder);
        token.approve(address(cell), _minB() + REWARD);
        vm.expectRevert(SpecGapModule.RewardRequired.selector);
        specGap.fundSpecGapDemonstration(id, classId, _minB(), 0);
        vm.expectRevert(SpecGapModule.BountyLow.selector);
        specGap.fundSpecGapDemonstration(id, classId, _minB() - 1, REWARD);
        vm.stopPrank();
    }

    function test_a_second_demonstration_waits_for_the_first_and_may_follow_it() public {
        (uint256 id, bytes32 pinned) = _silenceConfirmedGap();
        uint256 first = _fund(id);
        vm.startPrank(funder);
        token.approve(address(cell), _minB() + REWARD);
        vm.expectRevert(SpecGapModule.ContestOpen.selector);
        specGap.fundSpecGapDemonstration(id, classId, _minB(), REWARD);
        vm.stopPrank();

        _run(first, pinned, false);
        uint256 second = _fund(id);
        assertTrue(second != first, "a fresh row for the second demonstration");
        uint256 filerBefore = token.balanceOf(filer);
        _run(second, pinned, true);
        assertEq(token.balanceOf(filer), filerBefore + REWARD, "the second demonstration pays on its own replay");
        assertEq(token.balanceOf(address(cell)), 0);
    }

    // ------------------------------------------------------------------ custody on the other exits

    function test_an_expired_demonstration_refunds_the_funder_both_halves_and_the_row_is_terminal() public {
        (uint256 id, bytes32 pinned) = _silenceConfirmedGap();
        uint256 disputeId = _fund(id);
        vm.prank(auditorC);
        cell.acceptAudit(disputeId, specErrors); // holds the row, then goes silent
        uint256 funderBefore = token.balanceOf(funder);

        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        specGap.expireSpecGapDispute(id, classId);

        assertEq(token.balanceOf(funder), funderBefore + _minB() + REWARD, "re-run bounty and reward both come back, once");
        assertEq(token.balanceOf(address(cell)), 0, "and the cell keeps nothing of it");
        assertEq(specGap.demonstrationReward(disputeId), 0);
        assertEq(specGap.activeSpecGapDisputeAuditId(id, classId), 0, "the slot is free for another funder");
        assertEq(
            uint256(cell.auditStateOf(disputeId)), uint256(CellTypeDefs.AuditState.Invalidated),
            "an expired demonstration row is TERMINAL (I1)"
        );
        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.Confirmed));

        vm.prank(auditorC);
        vm.expectRevert();
        cell.proveFail(disputeId, gapEvaluatorId, _root(pinned, AuditResultV1.VERDICT_FAIL));
    }

    function test_a_verdict_that_replays_neither_side_returns_the_reward_to_the_funder() public {
        (uint256 id,) = _silenceConfirmedGap();
        uint256 disputeId = _fund(id);
        uint256 funderBefore = token.balanceOf(funder);
        uint256 filerBefore = token.balanceOf(filer);
        vm.prank(auditorC);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(auditorC);
        cell.proveFail(disputeId, gapEvaluatorId, keccak256("a root that binds to nothing on file"));
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);

        assertEq(token.balanceOf(funder), funderBefore + REWARD, "unadjudicated: the reward goes back to its funder");
        assertEq(token.balanceOf(filer), filerBefore, "and the filer is neither paid nor touched");
        assertEq(token.balanceOf(address(cell)), 0);
        assertEq(specGap.activeSpecGapDisputeAuditId(id, classId), 0);
    }

    /// The funder is the draw's second exclusion (PC-99's hook): a funder who is also a queued auditor may not draw the
    /// row they funded and settle their own reward. With the funder registered, two auditors are eligible on paper and
    /// the draw must still land on the other one.
    function test_a_funder_who_is_a_queued_auditor_is_excluded_from_the_draw() public {
        (uint256 id,) = _silenceConfirmedGap();
        vm.prank(funder);
        cell.register();
        vm.startPrank(funder);
        token.approve(address(cell), _minB() + REWARD);
        uint256 disputeId = specGap.fundSpecGapDemonstration(id, classId, _minB(), REWARD);
        vm.stopPrank();
        assertEq(cell.auditAuditorOf(disputeId), auditorC, "the funder is never their own re-runner");
    }
}

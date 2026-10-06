// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/CellStorage.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/WitnessClaimLib.sol";
import "genesis-tools/AuditResultV1.sol";
import "../contracts/ClaimDisputeModule.sol";
import "./helpers/CellTestDeploy.sol";
import "./helpers/SpecValidationCellSetup.sol";

contract ReviewTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice The auditor's witness in review: the row's own auditor sees a finding the declared spec does not carry and
///         files it as a witness claim while the row is InAudit. No PASS is given first. A drawn stranger re-runs the
///         canonical evaluator and the pot pays.
contract ReviewWitnessClaimTest is Test {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    ClaimDisputeModule claimModule;

    address protocol = address(0xA11CE);
    address auditorA = address(0xB0B);
    address stranger = address(0xDEAD);
    address auditorC = address(0xC0DE);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 finderToolId = keccak256("finder-tool");
    bytes32 evaluatorToolId = keccak256("eval-tool");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 invariantId = keccak256("INVARIANT_OUTSIDE_THE_SPEC");
    bytes32 locationCommitment = keccak256("loc-commit");
    bytes32 witnessCommitment = keccak256("witness-bytes");
    bytes32 contextRoot = bytes32(0);
    bytes32 passRoot = keccak256("verdict-pass");

    uint256 constant BOUNTY = 40 ether;
    uint256 nextSalt = 1;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        claimModule = d.claimModule;
        escrow = d.escrow;
        token.genesisMint(protocol, 2_000 ether);
        token.genesisMint(auditorA, 500 ether);
        token.genesisMint(stranger, 500 ether);
        token.genesisMint(auditorC, 50 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, finderToolId);
        cell.registerTool(evaluatorToolId, false);
        cell.setToolWitnessFlags(evaluatorToolId, true, true);

        vm.prank(auditorA);
        cell.register();
        vm.prank(stranger);
        cell.register();
        vm.prank(auditorC);
        cell.register();
    }

    function _root(bytes32 pinnedArtifactHash, uint8 verdict) internal view returns (bytes32) {
        WitnessClaimLib.Binding memory b = WitnessClaimLib.Binding({
            evaluatorToolId: evaluatorToolId,
            invariantId: invariantId,
            locationCommitment: locationCommitment,
            witnessCommitment: witnessCommitment,
            contextRoot: contextRoot
        });
        return WitnessClaimLib.resultRoot(b, pinnedArtifactHash, specHash, verdict);
    }

    /// A row in review: submitted, the drawn auditor accepted by the protocol, the spec attested. No verdict yet.
    function _inReview() internal returns (uint256 id, bytes32 pinnedArtifactHash) {
        ReviewTarget original = new ReviewTarget(nextSalt++);
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = finderToolId;
        vm.prank(protocol);
        id = cell.submitAudit(
            address(original), address(original).codehash, specHash, specToolId, specErrors, BOUNTY, declared, 0, 0
        );
        pinnedArtifactHash = address(original).codehash;

        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InAudit));
        assertEq(cell.auditAuditorOf(id), auditorA);
    }

    function _file(address who, uint256 id, bytes32 root) internal {
        vm.startPrank(who);
        token.approve(address(cell), cell.requiredClaimStake(id));
        cell.claimVulnerability(
            id, finderToolId, root, "", evaluatorToolId, invariantId, locationCommitment, witnessCommitment, contextRoot
        );
        vm.stopPrank();
    }

    /// The protocol funds the re-run, the drawn re-auditor runs the evaluator and its verdict is confirmed.
    function _rerun(uint256 id, bytes32 disputeRoot, bool passVerdict) internal returns (uint256 disputeId) {
        disputeId = _rerunToVerdict(id, disputeRoot, passVerdict);
        cell.confirmAudit(disputeId);
    }

    /// The same, stopped one step short: the verdict is in and its window has run, nothing is confirmed.
    /// Time is read through the cheatcode: under via_ir a `block.timestamp` read after a warp can be stale.
    function _rerunToVerdict(uint256 id, bytes32 disputeRoot, bool passVerdict) internal returns (uint256 disputeId) {
        uint256 minB = (BOUNTY * 5000) / 10_000;
        vm.startPrank(protocol);
        token.approve(address(cell), minB);
        disputeId = claimModule.openDisputeReaudit(id, minB);
        vm.stopPrank();

        address disputeAuditor = cell.auditAuditorOf(disputeId);
        assertTrue(disputeAuditor != auditorA, "the re-run is a drawn stranger's, never the filer's");
        vm.prank(disputeAuditor);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(disputeAuditor);
        if (passVerdict) {
            cell.provePass(disputeId, evaluatorToolId, disputeRoot);
        } else {
            cell.proveFail(disputeId, evaluatorToolId, disputeRoot);
        }
        vm.warp(vm.getBlockTimestamp() + cell.minAuditWindow() + 1);
    }

    // ------------------------------------------------------------------ the lane

    function test_the_auditor_in_review_files_a_witness_and_the_pot_pays() public {
        (uint256 id, bytes32 art) = _inReview();
        uint256 balBefore = token.balanceOf(auditorA);
        bytes32 failRoot = _root(art, AuditResultV1.VERDICT_FAIL);

        _file(auditorA, id, failRoot);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Claimed));
        assertEq(uint256(cell.getAudit(id).stateBeforeClaim), uint256(CellTypeDefs.AuditState.InAudit));
        (address filer,,,,,, bool exists, bool witnessPath, bytes32 evaluator,,,,) = cell.vulnerabilityClaims(id);
        assertEq(filer, auditorA);
        assertTrue(exists);
        assertTrue(witnessPath, "the claim carries the witness, which proveFail's own claim cannot");
        assertEq(evaluator, evaluatorToolId);
        assertEq(cell.auditVerdictToolId(id), bytes32(0), "no verdict was given: there is no PASS and no FAIL on the row");

        uint256 disputeId = _rerunToVerdict(id, failRoot, false);
        uint256 pot = cell.getAudit(id).bounty;
        uint256 poolBefore = escrow.escrowBalance();
        uint256 protocolBefore = token.balanceOf(protocol);
        cell.confirmAudit(disputeId);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Exploited));

        // INHERITED RULE ONE (DiscovererPayoutLib.pay): the target is the pot, capped at the larger of the pool's share
        // and the pot's floor; the pool pays first, the pot tops up only the shortfall, the rest of the pot goes back
        // to the protocol. The stake comes back whole, so the auditor's gain is the payout alone.
        uint256 poolShare = (poolBefore * cell.discoveryCapBps()) / 10_000;
        uint256 floorShare = (pot * cell.discoveryFloorBps()) / 10_000;
        uint256 target = poolShare > floorShare ? poolShare : floorShare;
        if (target > pot) target = pot;
        uint256 gain = token.balanceOf(auditorA) - balBefore;
        uint256 refund = token.balanceOf(protocol) - protocolBefore;
        uint256 poolAfter = escrow.escrowBalance();
        emit log_named_decimal_uint("the pot", pot, 18);
        emit log_named_decimal_uint("the pool before the confirmation", poolBefore, 18);
        emit log_named_decimal_uint("the pool after it", poolAfter, 18);
        emit log_named_decimal_uint("paid to the auditor above the returned stake", gain, 18);
        emit log_named_decimal_uint("returned to the protocol", refund, 18);
        assertEq(gain, target, "the auditor is paid the target the rule sets, and the stake came back");
        assertLe(refund, pot, "the protocol cannot get back more than the pot");
        // what the auditor got and the pot did not pay came from the pool
        assertEq(poolBefore - poolAfter, gain + refund - pot, "the pool paid first, the pot only the shortfall");
        (, uint256 failed, uint256 found,,,) = cell.auditors(auditorA);
        assertEq(failed, 0, "the auditor gave no verdict to be wrong about");
        assertEq(found, 1);
    }

    function test_a_rerun_that_passes_takes_the_stake_and_returns_the_row_to_review() public {
        (uint256 id, bytes32 art) = _inReview();
        uint256 stake = cell.requiredClaimStake(id);
        uint256 balBefore = token.balanceOf(auditorA);
        uint256 pickupBefore = cell.getAudit(id).pickupTime;

        _file(auditorA, id, _root(art, AuditResultV1.VERDICT_FAIL));
        _rerun(id, _root(art, AuditResultV1.VERDICT_PASS), true);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InAudit));
        assertEq(token.balanceOf(auditorA), balBefore - stake, "a witness that does not reproduce costs its stake");

        // INHERITED RULE TWO: the clock is NOT given back on a PASS replay. The re-run's own window is longer than
        // the review window, so the auditor comes back to a row it can no longer decide, and anyone can time it out.
        assertEq(cell.getAudit(id).pickupTime, pickupBefore, "the Claimed time is not given back");
        assertGt(vm.getBlockTimestamp(), pickupBefore + cell.inAuditWindow(), "the review window ran out under the re-run");
        vm.prank(auditorA);
        vm.expectRevert(CellLogicLib.InAuditWindowPassed.selector);
        cell.provePass(id, finderToolId, passRoot);

        (,,,, uint256 streakBefore,) = cell.auditors(auditorA);
        vm.prank(stranger);
        cell.advanceInAudit(id);
        (,,,, uint256 streakAfter, bool inQueue) = cell.auditors(auditorA);
        assertEq(streakAfter, streakBefore + 1, "the auditor is timed out for the time the re-run took");
        assertTrue(inQueue, "one time-out is under the push-out threshold");
        assertTrue(uint256(cell.auditStateOf(id)) != uint256(CellTypeDefs.AuditState.InAudit), "the row left review");
        emit log_named_address("the row's auditor after the time-out", cell.auditAuditorOf(id));
        emit log_named_uint("the row's state after the time-out", uint256(cell.auditStateOf(id)));
    }

    function test_a_rerun_on_neither_root_gives_the_clock_back_and_the_auditor_still_decides() public {
        (uint256 id, bytes32 art) = _inReview();
        uint256 pickupBefore = cell.getAudit(id).pickupTime;
        uint256 balBefore = token.balanceOf(auditorA);
        uint256 filedAt = vm.getBlockTimestamp();

        _file(auditorA, id, _root(art, AuditResultV1.VERDICT_FAIL));
        _rerun(id, keccak256("a root that is neither"), false);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InAudit));
        assertEq(token.balanceOf(auditorA), balBefore, "nobody adjudicated: the stake comes back");
        assertEq(cell.getAudit(id).pickupTime, pickupBefore + (vm.getBlockTimestamp() - filedAt), "the Claimed time is given back");

        vm.prank(auditorA);
        cell.provePass(id, finderToolId, passRoot);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.AwaitingWindow));
    }

    // ------------------------------------------------------------------ the bound: one claim of its own per auditor per row

    function test_one_claim_per_auditor_per_row_across_both_lanes_witness_first() public {
        (uint256 id, bytes32 art) = _inReview();
        bytes32 failRoot = _root(art, AuditResultV1.VERDICT_FAIL);
        _file(auditorA, id, failRoot);
        _rerun(id, keccak256("a root that is neither"), false);

        vm.startPrank(auditorA);
        token.approve(address(cell), cell.requiredClaimStake(id));
        vm.expectRevert(ClaimDisputeModule.ClaimAlreadyFiled.selector);
        cell.claimVulnerability(
            id, finderToolId, failRoot, "", evaluatorToolId, invariantId, locationCommitment, witnessCommitment, contextRoot
        );
        vm.expectRevert(CellLogicLib.ClaimAlreadyExists.selector);
        cell.proveFail(id, finderToolId, keccak256("fail"));
        vm.stopPrank();
    }

    function test_one_claim_per_auditor_per_row_across_both_lanes_verdict_first() public {
        (uint256 id, bytes32 art) = _inReview();
        bytes32 verdictFail = keccak256("fail");
        vm.startPrank(auditorA);
        token.approve(address(cell), cell.requiredClaimStake(id));
        cell.proveFail(id, finderToolId, verdictFail);
        vm.stopPrank();

        // proveFail's own claim is re-run with the finder tool; a root that is neither sends the row back to review
        uint256 minB = (BOUNTY * 5000) / 10_000;
        vm.startPrank(protocol);
        token.approve(address(cell), minB);
        uint256 disputeId = claimModule.openDisputeReaudit(id, minB);
        vm.stopPrank();
        address disputeAuditor = cell.auditAuditorOf(disputeId);
        vm.prank(disputeAuditor);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(disputeAuditor);
        cell.proveFail(disputeId, finderToolId, keccak256("a root that is neither"));
        vm.warp(vm.getBlockTimestamp() + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InAudit));

        bytes32 failRoot = _root(art, AuditResultV1.VERDICT_FAIL);
        vm.startPrank(auditorA);
        token.approve(address(cell), cell.requiredClaimStake(id));
        vm.expectRevert(ClaimDisputeModule.ClaimAlreadyFiled.selector);
        cell.claimVulnerability(
            id, finderToolId, failRoot, "", evaluatorToolId, invariantId, locationCommitment, witnessCommitment, contextRoot
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ what stays refused

    function test_a_stranger_cannot_claim_a_row_in_review() public {
        (uint256 id, bytes32 art) = _inReview();
        bytes32 failRoot = _root(art, AuditResultV1.VERDICT_FAIL);
        vm.startPrank(stranger);
        token.approve(address(cell), cell.requiredClaimStake(id));
        vm.expectRevert(ClaimDisputeModule.OriginalNotEligibleForClaim.selector);
        cell.claimVulnerability(
            id, finderToolId, failRoot, "", evaluatorToolId, invariantId, locationCommitment, witnessCommitment, contextRoot
        );
        vm.stopPrank();
    }

    function test_the_protocol_cannot_claim_its_own_row_in_review() public {
        (uint256 id, bytes32 art) = _inReview();
        bytes32 failRoot = _root(art, AuditResultV1.VERDICT_FAIL);
        vm.startPrank(protocol);
        vm.expectRevert(ClaimDisputeModule.OriginalNotEligibleForClaim.selector);
        cell.claimVulnerability(
            id, finderToolId, failRoot, "", evaluatorToolId, invariantId, locationCommitment, witnessCommitment, contextRoot
        );
        vm.stopPrank();
    }

    function test_a_claim_in_review_without_a_witness_is_refused() public {
        (uint256 id,) = _inReview();
        vm.startPrank(auditorA);
        token.approve(address(cell), cell.requiredClaimStake(id));
        vm.expectRevert(ClaimDisputeModule.ReviewClaimNeedsWitness.selector);
        cell.claimVulnerability(id, finderToolId, keccak256("fail"), "");
        vm.stopPrank();
    }

    function test_a_claim_past_the_in_audit_deadline_is_refused() public {
        (uint256 id, bytes32 art) = _inReview();
        bytes32 failRoot = _root(art, AuditResultV1.VERDICT_FAIL);
        vm.warp(cell.getAudit(id).pickupTime + cell.inAuditWindow() + 1);
        vm.startPrank(auditorA);
        token.approve(address(cell), cell.requiredClaimStake(id));
        vm.expectRevert(ClaimDisputeModule.ReviewWindowPassed.selector);
        cell.claimVulnerability(
            id, finderToolId, failRoot, "", evaluatorToolId, invariantId, locationCommitment, witnessCommitment, contextRoot
        );
        vm.stopPrank();
    }

    function test_a_claim_on_the_last_second_of_the_deadline_is_taken() public {
        (uint256 id, bytes32 art) = _inReview();
        vm.warp(cell.getAudit(id).pickupTime + cell.inAuditWindow());
        _file(auditorA, id, _root(art, AuditResultV1.VERDICT_FAIL));
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Claimed));
    }

    function test_the_in_audit_timeout_cannot_fire_on_a_row_claimed_in_review() public {
        (uint256 id, bytes32 art) = _inReview();
        _file(auditorA, id, _root(art, AuditResultV1.VERDICT_FAIL));
        vm.warp(cell.getAudit(id).pickupTime + cell.inAuditWindow() + 1);
        vm.expectRevert();
        cell.advanceInAudit(id);
    }

    function test_the_auditor_who_passed_the_row_is_still_refused_after_the_pass() public {
        (uint256 id, bytes32 art) = _inReview();
        bytes32 failRoot = _root(art, AuditResultV1.VERDICT_FAIL);
        vm.prank(auditorA);
        cell.provePass(id, finderToolId, passRoot);
        vm.startPrank(auditorA);
        token.approve(address(cell), cell.requiredClaimStake(id));
        vm.expectRevert(ClaimDisputeModule.ClaimantCannotBeOriginalAuditor.selector);
        cell.claimVulnerability(
            id, finderToolId, failRoot, "", evaluatorToolId, invariantId, locationCommitment, witnessCommitment, contextRoot
        );
        vm.stopPrank();
    }

    function test_a_stranger_after_the_pass_files_as_before() public {
        (uint256 id, bytes32 art) = _inReview();
        vm.prank(auditorA);
        cell.provePass(id, finderToolId, passRoot);
        _file(stranger, id, _root(art, AuditResultV1.VERDICT_FAIL));
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Claimed));
        assertEq(uint256(cell.getAudit(id).stateBeforeClaim), uint256(CellTypeDefs.AuditState.AwaitingWindow));
    }

    function test_the_re_auditor_cannot_claim_the_re_run_row_it_is_reviewing() public {
        (uint256 id, bytes32 art) = _inReview();
        bytes32 failRoot = _root(art, AuditResultV1.VERDICT_FAIL);
        _file(auditorA, id, failRoot);

        uint256 minB = (BOUNTY * 5000) / 10_000;
        vm.startPrank(protocol);
        token.approve(address(cell), minB);
        uint256 disputeId = claimModule.openDisputeReaudit(id, minB);
        vm.stopPrank();
        address disputeAuditor = cell.auditAuditorOf(disputeId);
        vm.prank(disputeAuditor);
        cell.acceptAudit(disputeId, specErrors);
        assertEq(uint256(cell.auditStateOf(disputeId)), uint256(CellTypeDefs.AuditState.InAudit));

        vm.startPrank(disputeAuditor);
        vm.expectRevert(ClaimDisputeModule.OriginalNotEligibleForClaim.selector);
        cell.claimVulnerability(
            disputeId, evaluatorToolId, failRoot, "", evaluatorToolId, invariantId, locationCommitment, witnessCommitment,
            contextRoot
        );
        vm.stopPrank();
    }

    function test_a_witness_that_does_not_bind_the_row_is_refused_in_review() public {
        (uint256 id,) = _inReview();
        vm.startPrank(auditorA);
        token.approve(address(cell), cell.requiredClaimStake(id));
        vm.expectRevert(ClaimDisputeModule.WitnessResultRootMismatch.selector);
        cell.claimVulnerability(
            id, finderToolId, keccak256("not the bound root"), "", evaluatorToolId, invariantId, locationCommitment,
            witnessCommitment, contextRoot
        );
        vm.stopPrank();
    }
}

/// @notice The genesis row keeps its latch: its auditor's witness claim in review is refused, `proveFail` stays its lane.
contract ReviewWitnessClaimGenesisTest is SpecValidationCellSetup {
    function test_the_genesis_row_is_refused() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        address genesisProtocol = address(0xBEEF);
        address genesisAuditor = address(0xA11CE);
        bytes32 specToolId = keccak256("spec.tool.v1");
        bytes32 verdictToolId = keccak256("verdict.tool.v1");
        bytes32 evaluatorToolId = keccak256("eval-tool");
        bytes32 specHash = keccak256("spec.v1");

        d.cell.setGenesisBootstrap(genesisProtocol, address(0));
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        d.cell.registerTool(evaluatorToolId, false);
        d.cell.setToolWitnessFlags(evaluatorToolId, true, true);
        vm.prank(genesisAuditor);
        d.cell.register();

        ReviewTarget target = new ReviewTarget(1);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(genesisProtocol);
        uint256 id = d.cell.submitGenesisAudit(
            address(target), address(target).codehash, specHash, specToolId, EMPTY_SPEC_ERRORS, 5000 ether, declared, 0, 0
        );
        CellTestDeploy.attachMinter(d);
        vm.prank(genesisProtocol);
        d.cell.protocolAcceptAuditor(id);
        vm.prank(genesisAuditor);
        d.cell.acceptAudit(id, EMPTY_SPEC_ERRORS);
        assertEq(uint256(d.cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InAudit));
        assertTrue(d.cell.genesisAuditOpen());

        WitnessClaimLib.Binding memory b = WitnessClaimLib.Binding({
            evaluatorToolId: evaluatorToolId,
            invariantId: keccak256("INV"),
            locationCommitment: keccak256("loc"),
            witnessCommitment: keccak256("wit"),
            contextRoot: bytes32(0)
        });
        bytes32 failRoot = WitnessClaimLib.resultRoot(b, address(target).codehash, specHash, AuditResultV1.VERDICT_FAIL);

        vm.startPrank(genesisAuditor);
        vm.expectRevert(ClaimDisputeModule.OriginalNotEligibleForClaim.selector);
        d.cell.claimVulnerability(
            id, verdictToolId, failRoot, "", evaluatorToolId, keccak256("INV"), keccak256("loc"), keccak256("wit"), bytes32(0)
        );
        vm.stopPrank();
    }
}

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
import "../contracts/SpecGapModule.sol";
import "./helpers/CellTestDeploy.sol";

contract MatrixTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice The audit matrix's own pins (`body/tools/audit-matrix/matrix.json`). Every matrix row names the tests that
///         pin it; most rows are pinned by the suites that built their lane, and this file holds the rows nothing else
///         pinned. A row whose handler is "nothing" is pinned by the refusal, so an empty cell stays empty on purpose.
///         Test names start with the row they pin: `test_rowNN_`.
contract AuditMatrixTest is Test {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    ClaimDisputeModule claimModule;
    SpecGapModule specGap;

    address protocol = address(0xA11CE);
    address auditorA = address(0xB0B);
    address stranger = address(0xDEAD);
    address auditorC = address(0xC0DE);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 finderToolId = keccak256("finder-tool");
    bytes32 evaluatorToolId = keccak256("eval-tool");
    bytes32 notCanonicalEvaluatorId = keccak256("eval-tool-not-canonical");
    bytes32 notAnEvaluatorId = keccak256("not-an-evaluator");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 invariantId = keccak256("INVARIANT_OUTSIDE_THE_SPEC");
    bytes32 classId = keccak256("CLASS_OUTSIDE_THE_SPEC");
    bytes32 locationCommitment = keccak256("loc-commit");
    bytes32 witnessCommitment = keccak256("witness-bytes");
    bytes32 contextRoot = bytes32(0);
    bytes32 passRoot = keccak256("verdict-pass");
    bytes32 failRoot = keccak256("verdict-fail");

    uint256 constant BOUNTY = 40 ether;
    uint256 nextSalt = 1;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        claimModule = d.claimModule;
        escrow = d.escrow;
        specGap = d.specGapModule;
        token.genesisMint(protocol, 2_000 ether);
        token.genesisMint(auditorA, 500 ether);
        token.genesisMint(stranger, 500 ether);
        token.genesisMint(auditorC, 50 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, finderToolId);
        cell.registerTool(evaluatorToolId, false);
        cell.setToolWitnessFlags(evaluatorToolId, true, true);
        cell.registerTool(notCanonicalEvaluatorId, false);
        cell.setToolWitnessFlags(notCanonicalEvaluatorId, true, false);
        cell.registerTool(notAnEvaluatorId, false);
        specGap.registerClass(classId);

        vm.prank(auditorA);
        cell.register();
        vm.prank(stranger);
        cell.register();
        vm.prank(auditorC);
        cell.register();
    }

    // ------------------------------------------------------------------ fixtures

    function _submit() internal returns (uint256 id, bytes32 pinned) {
        MatrixTarget original = new MatrixTarget(nextSalt++);
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = finderToolId;
        vm.prank(protocol);
        id = cell.submitAudit(
            address(original), address(original).codehash, specHash, specToolId, specErrors, BOUNTY, declared, 0, 0
        );
        pinned = address(original).codehash;
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        assertEq(cell.auditAuditorOf(id), auditorA);
    }

    function _inReview() internal returns (uint256 id, bytes32 pinned) {
        (id, pinned) = _submit();
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InAudit));
    }

    function _afterPass() internal returns (uint256 id, bytes32 pinned) {
        (id, pinned) = _inReview();
        vm.prank(auditorA);
        cell.provePass(id, finderToolId, passRoot);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.AwaitingWindow));
    }

    function _selfClaim(uint256 id) internal returns (uint256 stake) {
        stake = cell.requiredClaimStake(id);
        vm.startPrank(auditorA);
        token.approve(address(cell), stake);
        cell.proveFail(id, finderToolId, failRoot);
        vm.stopPrank();
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Claimed));
        assertEq(uint256(cell.getAudit(id).stateBeforeClaim), uint256(CellTypeDefs.AuditState.InAudit));
    }

    /// The protocol funds the re-run of a `proveFail` self-claim; the drawn stranger re-runs the declared tool.
    function _rerunSelfClaim(uint256 id, bytes32 root, bool passVerdict) internal returns (uint256 disputeId) {
        uint256 minB = (BOUNTY * 5000) / 10_000;
        vm.startPrank(protocol);
        token.approve(address(cell), minB);
        disputeId = claimModule.openDisputeReaudit(id, minB);
        vm.stopPrank();
        address reAuditor = cell.auditAuditorOf(disputeId);
        assertTrue(reAuditor != auditorA, "the re-run is a drawn stranger's");
        vm.prank(reAuditor);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(reAuditor);
        if (passVerdict) {
            cell.provePass(disputeId, finderToolId, root);
        } else {
            cell.proveFail(disputeId, finderToolId, root);
        }
        vm.warp(vm.getBlockTimestamp() + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);
    }

    function _witnessRoot(bytes32 evaluator, bytes32 pinned, uint8 verdict) internal view returns (bytes32) {
        WitnessClaimLib.Binding memory b = WitnessClaimLib.Binding({
            evaluatorToolId: evaluator,
            invariantId: invariantId,
            locationCommitment: locationCommitment,
            witnessCommitment: witnessCommitment,
            contextRoot: contextRoot
        });
        return WitnessClaimLib.resultRoot(b, pinned, specHash, verdict);
    }

    function _witnessClaim(address who, uint256 id, bytes32 tool, bytes32 evaluator, bytes32 root) internal {
        vm.startPrank(who);
        token.approve(address(cell), cell.requiredClaimStake(id));
        cell.claimVulnerability(
            id, tool, root, "", evaluator, invariantId, locationCommitment, witnessCommitment, contextRoot
        );
        vm.stopPrank();
    }

    function _openGap(address who, uint256 id, bytes32 evaluator, bytes32 root) internal {
        vm.startPrank(who);
        token.approve(address(cell), cell.requiredClaimStake(id));
        specGap.openSpecGap(
            id, classId, finderToolId, root, evaluator, invariantId, locationCommitment, witnessCommitment, contextRoot
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ row 1: the auditor's own FAIL in review

    function test_row01_a_self_claim_the_rerun_reproduces_exploits_the_row_and_marks_no_one_failed() public {
        (uint256 id,) = _inReview();
        uint256 balBefore = token.balanceOf(auditorA);
        _selfClaim(id);
        _rerunSelfClaim(id, failRoot, false);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Exploited));
        (, uint256 failed, uint256 found,,,) = cell.auditors(auditorA);
        assertEq(failed, 0, "the auditor's own FAIL was right: no failed mark");
        assertEq(found, 1);
        assertGe(token.balanceOf(auditorA), balBefore, "the stake came back");
    }

    function test_row01_a_self_claim_nobody_resolves_lapses_with_the_stake_back_and_the_row_in_review() public {
        (uint256 id,) = _inReview();
        uint256 balBefore = token.balanceOf(auditorA);
        _selfClaim(id);
        vm.warp(vm.getBlockTimestamp() + cell.claimResolutionWindow() + 1);
        cell.expireClaim(id);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InAudit));
        assertEq(token.balanceOf(auditorA), balBefore, "VD-117: no adjudicated outcome, no adjudicated loser");
    }

    // ------------------------------------------------------------------ row 7: a property with no canonical evaluator

    function test_row07_a_witness_whose_evaluator_is_not_canonical_has_no_claim_lane() public {
        (uint256 id, bytes32 pinned) = _afterPass();
        bytes32 root = _witnessRoot(notCanonicalEvaluatorId, pinned, AuditResultV1.VERDICT_FAIL);
        vm.startPrank(stranger);
        token.approve(address(cell), cell.requiredClaimStake(id));
        vm.expectRevert(ClaimDisputeModule.EvaluatorNotCanonical.selector);
        cell.claimVulnerability(
            id, finderToolId, root, "", notCanonicalEvaluatorId, invariantId, locationCommitment, witnessCommitment,
            contextRoot
        );
        vm.stopPrank();
    }

    function test_row07_a_witness_whose_tool_is_no_evaluator_has_no_claim_lane() public {
        (uint256 id, bytes32 pinned) = _afterPass();
        bytes32 root = _witnessRoot(notAnEvaluatorId, pinned, AuditResultV1.VERDICT_FAIL);
        vm.startPrank(stranger);
        token.approve(address(cell), cell.requiredClaimStake(id));
        vm.expectRevert(ClaimDisputeModule.NotInvariantEvaluator.selector);
        cell.claimVulnerability(
            id, finderToolId, root, "", notAnEvaluatorId, invariantId, locationCommitment, witnessCommitment, contextRoot
        );
        vm.stopPrank();
    }

    function test_row07_the_spec_gap_lane_refuses_the_same_evaluator() public {
        (uint256 id, bytes32 pinned) = _afterPass();
        bytes32 root = _witnessRoot(notCanonicalEvaluatorId, pinned, AuditResultV1.VERDICT_FAIL);
        vm.startPrank(stranger);
        token.approve(address(cell), cell.requiredClaimStake(id));
        vm.expectRevert(SpecGapModule.EvaluatorNotCanonical.selector);
        specGap.openSpecGap(
            id, classId, finderToolId, root, notCanonicalEvaluatorId, invariantId, locationCommitment, witnessCommitment,
            contextRoot
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ row 8: the spec tool itself as the finder

    function test_row08_the_spec_tool_is_refused_as_the_claims_tool() public {
        (uint256 id,) = _afterPass();
        vm.startPrank(stranger);
        token.approve(address(cell), cell.requiredClaimStake(id));
        vm.expectRevert(ClaimDisputeModule.SpecToolNotForClaim.selector);
        cell.claimVulnerability(id, specToolId, keccak256("fail"), "");
        vm.stopPrank();
    }

    function test_row08_the_spec_tool_is_refused_as_the_witness_evaluator() public {
        (uint256 id, bytes32 pinned) = _afterPass();
        bytes32 root = _witnessRoot(specToolId, pinned, AuditResultV1.VERDICT_FAIL);
        vm.startPrank(stranger);
        token.approve(address(cell), cell.requiredClaimStake(id));
        vm.expectRevert(ClaimDisputeModule.SpecToolNotForVerdict.selector);
        cell.claimVulnerability(
            id, finderToolId, root, "", specToolId, invariantId, locationCommitment, witnessCommitment, contextRoot
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ row 9: a spec that does not reproduce

    function test_row09_a_spec_run_that_does_not_reproduce_is_refused_at_accept() public {
        (uint256 id,) = _submit();
        vm.prank(auditorA);
        vm.expectRevert(CellLogicLib.SpecRunMismatch.selector);
        cell.acceptAudit(id, keccak256("errors the submitter did not commit"));
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Assigned));
    }

    // ------------------------------------------------------------------ row 15: a FAIL asserted where there is no flaw

    /// The legacy resolver reads a PASS replay as reproducing only when its root equals the row's own proof hash
    /// (ClaimDisputeModule `rDisp == rOrig`). On a `proveFail` self-claim that proof hash IS the FAIL root, so an
    /// honest PASS re-run reproduces neither side: the claim resolves unadjudicated, the stake comes back and the
    /// clock is given back. A FAIL the auditor asserts in review is never priced by a PASS replay on this path.
    function test_row15_a_self_claim_whose_honest_rerun_passes_resolves_unadjudicated() public {
        (uint256 id,) = _inReview();
        uint256 balBefore = token.balanceOf(auditorA);
        _selfClaim(id);
        _rerunSelfClaim(id, passRoot, true);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InAudit), "back in review");
        assertEq(token.balanceOf(auditorA), balBefore, "the wrong FAIL cost the auditor nothing");
        (, uint256 failed,,,,) = cell.auditors(auditorA);
        assertEq(failed, 0);
    }
}

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

contract CustodyGapTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice PC-87 on the SPEC-GAP lane, which the register showed "by reading only; no fixture drives it" - driven here
///         in the hull window's G1 under D1 option A (VD-199). The lane pulls `disputeBounty + INTEGRITY_CONTEST_STAKE`
///         at contest; its settlement disposed of the stake and never of the bounty, and its expiry refunded the bounty
///         but left the dispute row live with the field still set (PC-87's note, PC-95(2)).
///
///         RED on the old bytes: the drawn re-runner is not paid the bounty and the cell keeps it; an expired row stays
///         in its pre-expiry state and still takes a verdict. GREEN after G1.
contract SpecGapDisputeCustodyTest is Test {
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

    /// An InBlock original with a filed gap, and the protocol's contest open. Returns the dispute row and its bounty.
    function _contested() internal returns (uint256 id, bytes32 pinned, uint256 disputeId, uint256 minB) {
        CustodyGapTarget target = new CustodyGapTarget(1);
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

        minB = (BOUNTY * 5000) / 10_000;
        vm.startPrank(protocol);
        token.approve(address(cell), minB + CONTEST_STAKE);
        disputeId = specGap.protocolContestSpecGap(id, classId, minB);
        vm.stopPrank();
        assertEq(cell.auditAuditorOf(disputeId), auditorC, "fixture: the only drawable re-runner");
        assertTrue(cell.auditBountyEscrowed(disputeId), "D1 option A: the dispute row holds its bounty in escrow");
    }

    function test_a_FAIL_replay_pays_the_rerunner_the_dispute_bounty_and_the_cell_holds_nothing() public {
        (uint256 id, bytes32 pinned, uint256 disputeId, uint256 minB) = _contested();
        uint256 before = token.balanceOf(auditorC);
        vm.prank(auditorC);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(auditorC);
        cell.proveFail(disputeId, gapEvaluatorId, _root(pinned, AuditResultV1.VERDICT_FAIL));
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);

        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.Confirmed));
        assertEq(
            token.balanceOf(auditorC), before + minB + CONTEST_STAKE,
            "the re-runner is paid the dispute bounty by the cell, and the contest stake by the lane"
        );
        assertEq(token.balanceOf(address(cell)), 0, "the cell holds NOTHING once the gap has settled");
    }

    function test_a_PASS_replay_pays_the_rerunner_the_dispute_bounty_and_the_cell_holds_nothing() public {
        (uint256 id, bytes32 pinned, uint256 disputeId, uint256 minB) = _contested();
        uint256 before = token.balanceOf(auditorC);
        vm.prank(auditorC);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(auditorC);
        cell.provePass(disputeId, gapEvaluatorId, _root(pinned, AuditResultV1.VERDICT_PASS));
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);

        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.False));
        assertEq(token.balanceOf(auditorC), before + minB, "the re-runner is paid the dispute bounty");
        assertEq(token.balanceOf(address(cell)), 0, "the cell holds NOTHING once the gap has settled");
    }

    function test_an_expired_spec_gap_dispute_row_is_terminal_zeroed_and_refuses_the_verdict() public {
        (uint256 id, bytes32 pinned, uint256 disputeId,) = _contested();
        vm.prank(auditorC);
        cell.acceptAudit(disputeId, specErrors); // holds the row, then goes silent
        uint256 protocolBefore = token.balanceOf(protocol);
        uint256 cellBefore = token.balanceOf(address(cell));
        uint256 minB = (BOUNTY * 5000) / 10_000;

        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        specGap.expireSpecGapDispute(id, classId);

        assertEq(token.balanceOf(protocol), protocolBefore + minB + CONTEST_STAKE, "the funder is refunded, once");
        assertEq(token.balanceOf(address(cell)), cellBefore - minB - CONTEST_STAKE, "and the cell keeps nothing of it");
        assertEq(
            uint256(cell.auditStateOf(disputeId)), uint256(CellTypeDefs.AuditState.Invalidated),
            "an expired dispute row is TERMINAL (I1)"
        );
        assertEq(cell.getAudit(disputeId).bounty, 0, "its bounty field is zeroed");
        assertFalse(cell.auditBountyEscrowed(disputeId), "the flag clears where custody ends (VD-101)");

        vm.prank(auditorC);
        vm.expectRevert(); // a zombie row must not take a verdict (PC-95(2))
        cell.proveFail(disputeId, gapEvaluatorId, _root(pinned, AuditResultV1.VERDICT_FAIL));
    }
}

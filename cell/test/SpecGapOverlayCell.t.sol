// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/CellStorage.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/SpecGapModule.sol";
import "../contracts/SpecGapLib.sol";
import "../contracts/WitnessClaimLib.sol";
import "genesis-tools/AuditResultV1.sol";
import "./helpers/CellTestDeploy.sol";

contract GapTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice F-83 Part B: non-destructive spec-gap overlay on the puzzle cell (C12 oracle).
contract SpecGapOverlayCellTest is Test {
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
    bytes32 contextRoot = bytes32(0);

    uint256 constant BOUNTY = 40_000 ether;
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

    function _gapResultRoot(bytes32 pinnedArtifact, uint8 verdict) internal view returns (bytes32) {
        WitnessClaimLib.Binding memory b = WitnessClaimLib.Binding({
            evaluatorToolId: gapEvaluatorId,
            invariantId: invariantId,
            locationCommitment: locationCommitment,
            witnessCommitment: witnessCommitment,
            contextRoot: contextRoot
        });
        return WitnessClaimLib.resultRoot(b, pinnedArtifact, specHash, verdict);
    }

    function _inBlockAudit() internal returns (uint256 id, bytes32 pinnedArtifact) {
        GapTarget target = new GapTarget(nextSalt++);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.startPrank(protocol);
        token.approve(address(cell), BOUNTY);
        id = cell.submitAudit(address(target), address(target).codehash, specHash, specToolId, specErrors, BOUNTY, declared, 0, 0);
        vm.stopPrank();
        pinnedArtifact = address(target).codehash;

        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditorA);
        cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InBlock));
    }

    function _openGap(uint256 id, bytes32 pinnedArtifact) internal {
        bytes32 failRoot = _gapResultRoot(pinnedArtifact, AuditResultV1.VERDICT_FAIL);
        vm.startPrank(filer);
        token.approve(address(cell), cell.requiredClaimStake(id));
        specGap.openSpecGap(
            id,
            classId,
            finderToolId,
            failRoot,
            gapEvaluatorId,
            invariantId,
            locationCommitment,
            witnessCommitment,
            contextRoot
        );
        vm.stopPrank();
    }

    function test_open_spec_gap_non_destructive() public {
        (uint256 id, bytes32 pinned) = _inBlockAudit();
        _openGap(id, pinned);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InBlock));
        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.Filed));
    }

    function test_concede_refunds_stake_records_gap() public {
        (uint256 id, bytes32 pinned) = _inBlockAudit();
        uint256 stake = cell.requiredClaimStake(id);
        _openGap(id, pinned);
        assertEq(token.balanceOf(filer), 50_000 ether - stake);

        vm.prank(protocol);
        specGap.protocolConcedeSpecGap(id, classId);

        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.Confirmed));
        assertEq(token.balanceOf(filer), 50_000 ether);
        assertEq(specGap.toolKnownGapCount(specToolId), 1);
        assertEq(specGap.toolKnownGapAt(specToolId, 0), classId);
    }

    function test_adopt_pays_filer_after_confirm() public {
        (uint256 id, bytes32 pinned) = _inBlockAudit();
        _openGap(id, pinned);
        vm.prank(protocol);
        specGap.protocolConcedeSpecGap(id, classId);

        uint256 reward = 5_000 ether;
        uint256 beforeAdopt = token.balanceOf(filer);
        vm.startPrank(protocol);
        token.approve(address(cell), reward);
        specGap.adoptSpecGap(id, classId, reward);
        vm.stopPrank();

        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.Adopted));
        assertEq(token.balanceOf(filer), beforeAdopt + reward);
    }

    function test_contest_fail_replay_confirms() public {
        (uint256 id, bytes32 pinned) = _inBlockAudit();
        _openGap(id, pinned);

        uint256 minB = (BOUNTY * 5000) / 10_000;
        uint256 contestExtra = 500 ether;
        vm.startPrank(protocol);
        token.approve(address(cell), minB + contestExtra);
        uint256 disputeId = specGap.protocolContestSpecGap(id, classId, minB);
        vm.stopPrank();

        vm.prank(auditorC);
        cell.acceptAudit(disputeId, specErrors);
        bytes32 failRoot = _gapResultRoot(pinned, AuditResultV1.VERDICT_FAIL);
        vm.prank(auditorC);
        cell.proveFail(disputeId, gapEvaluatorId, failRoot);

        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);

        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.Confirmed));
    }

    function test_contest_pass_replay_marks_false() public {
        (uint256 id, bytes32 pinned) = _inBlockAudit();
        _openGap(id, pinned);

        uint256 minB = (BOUNTY * 5000) / 10_000;
        uint256 contestExtra = 500 ether;
        vm.startPrank(protocol);
        token.approve(address(cell), minB + contestExtra);
        uint256 disputeId = specGap.protocolContestSpecGap(id, classId, minB);
        vm.stopPrank();

        vm.prank(auditorC);
        cell.acceptAudit(disputeId, specErrors);
        bytes32 passRoot = _gapResultRoot(pinned, AuditResultV1.VERDICT_PASS);
        vm.prank(auditorC);
        cell.provePass(disputeId, gapEvaluatorId, passRoot);

        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);

        assertEq(uint256(specGap.specGapStatusOf(id, classId)), uint256(SpecGapLib.Status.False));
    }

    function test_misroute_reverts_when_evaluator_is_spec_tool() public {
        (uint256 id, bytes32 pinned) = _inBlockAudit();
        bytes32 failRoot = _gapResultRoot(pinned, AuditResultV1.VERDICT_FAIL);
        vm.startPrank(filer);
        token.approve(address(cell), cell.requiredClaimStake(id));
        vm.expectRevert(SpecGapModule.MisrouteWithinS.selector);
        specGap.openSpecGap(
            id,
            classId,
            finderToolId,
            failRoot,
            specToolId,
            invariantId,
            locationCommitment,
            witnessCommitment,
            contextRoot
        );
        vm.stopPrank();
    }
}

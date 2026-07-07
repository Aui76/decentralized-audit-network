// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";

import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/CellStorage.sol";
import "../contracts/CellToken.sol";
import "../contracts/AssignmentModule.sol";
import "../contracts/IAssignmentModule.sol";
import "./helpers/CellTestDeploy.sol";

contract AssignTarget {
    uint256 public immutable salt;

    constructor(uint256 _salt) {
        salt = _salt;
    }
}

/// @notice X7 / F-53: constrained random assignment — reject memory, dyad cap, CRD mode (oracle: cathedral AssignmentRandomDraw.t.sol).
contract AssignmentRandomDrawCellTest is Test {
    using stdStorage for StdStorage;

    CellTestDeploy.Deployment d;
    AuditCell cell;
    AssignmentModule assignment;
    CellToken token;

    address protocol = address(0xBEEF);
    address auditorA = address(0xA11CE);
    address auditorB = address(0xB0B);
    address auditorC = address(0xCAFE);

    bytes32 specToolId = keccak256("spec-tool");
    bytes32 verdictToolId = keccak256("audit-tool");
    bytes32 specHash = keccak256("spec");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");

    uint256 deploySalt;

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        cell = d.cell;
        assignment = d.assignmentModule;
        token = d.token;

        token.genesisMint(protocol, 200_000 ether);
        token.genesisMint(auditorA, 10_000 ether);
        token.genesisMint(auditorB, 10_000 ether);
        token.genesisMint(auditorC, 10_000 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);

        vm.prank(auditorA);
        cell.register();
        vm.prank(auditorB);
        cell.register();
        vm.prank(auditorC);
        cell.register();

        assignment.setAssignmentMode(IAssignmentModule.AssignmentMode.RandomConstrained);
        assertEq(uint256(assignment.assignmentMode()), uint256(IAssignmentModule.AssignmentMode.RandomConstrained));
    }

    function test_reject_permanently_excludes_auditor_on_same_audit() public {
        uint256 auditId = _submitOrdinary();
        address first = cell.auditAuditorOf(auditId);

        vm.prank(protocol);
        cell.protocolRejectAuditor(auditId);

        address second = cell.auditAuditorOf(auditId);
        assertTrue(second != address(0), "re-assigned");
        assertTrue(second != first, "not same auditor");
        assertTrue(assignment.rejectedOnAudit(auditId, first), "reject memory");
    }

    function test_dyad_blocks_repeat_protocol_auditor_after_completion() public {
        uint256 auditId = _submitOrdinary();
        address first = cell.auditAuditorOf(auditId);
        _completeOrdinary(auditId, first);

        assertEq(assignment.protocolAuditorCompleted(protocol, first), 1, "dyad recorded");

        uint256 auditId2 = _submitOrdinary();
        address second = cell.auditAuditorOf(auditId2);
        assertTrue(second != first, "completed dyad excluded");
        assertTrue(second == auditorA || second == auditorB || second == auditorC, "eligible auditor");
    }

    function test_crd_emits_assignment_candidates() public {
        _submitOrdinary();
        vm.recordLogs();
        _submitOrdinary();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool sawCandidates;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("AssignmentCandidates(uint256,uint256,address)")) {
                sawCandidates = true;
                break;
            }
        }
        assertTrue(sawCandidates, "CRD emits AssignmentCandidates");
    }

    function test_fifo_mode_still_assigns_head() public {
        assignment.setAssignmentMode(IAssignmentModule.AssignmentMode.QueueFifo);

        stdstore.target(address(cell)).sig("queueHead()").checked_write(auditorB);

        uint256 auditId = _submitOrdinary();
        assertEq(cell.auditAuditorOf(auditId), auditorB, "FIFO head assign");
    }

    function test_reroll_entropy_varies_after_reject() public {
        uint256 auditId = _submitOrdinary();
        address first = cell.auditAuditorOf(auditId);
        vm.roll(block.number + 1);
        vm.prank(protocol);
        cell.protocolRejectAuditor(auditId);
        address second = cell.auditAuditorOf(auditId);
        assertTrue(second != address(0));
        assertTrue(second != first);
    }

    function test_module_unset_fifo_fallback_intact() public {
        CellTestDeploy.Deployment memory bare = CellTestDeploy.deployWithoutAssignment(address(this));
        AuditCell bareCell = bare.cell;
        bare.token.genesisMint(protocol, 200_000 ether);
        bare.token.genesisMint(auditorA, 10_000 ether);
        bare.token.genesisMint(auditorB, 10_000 ether);
        CellTestDeploy.attachMinter(bare);
        CellTestDeploy.registerDefaultTools(bare, specToolId, verdictToolId);

        vm.prank(auditorA);
        bareCell.register();
        vm.prank(auditorB);
        bareCell.register();

        assertEq(bareCell.assignmentModule(), address(0));

        stdstore.target(address(bareCell)).sig("queueHead()").checked_write(auditorB);

        deploySalt += 1;
        AssignTarget target = new AssignTarget(deploySalt);
        vm.startPrank(protocol);
        bare.token.approve(address(bareCell), 20_000 ether);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        uint256 auditId =
            bareCell.submitAudit(address(target), address(target).codehash, specHash, specToolId, specErrors, 20_000 ether, declared, 0, 0);
        vm.stopPrank();

        assertEq(bareCell.auditAuditorOf(auditId), auditorB, "unset module uses in-cell FIFO head");
    }

    function _submitOrdinary() internal returns (uint256 auditId) {
        deploySalt += 1;
        AssignTarget target = new AssignTarget(deploySalt);

        vm.startPrank(protocol);
        token.approve(address(cell), 20_000 ether);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        auditId = cell.submitAudit(address(target), address(target).codehash, specHash, specToolId, specErrors, 20_000 ether, declared, 0, 0);
        vm.stopPrank();
    }

    function _completeOrdinary(uint256 auditId, address assigned) internal {
        vm.prank(protocol);
        cell.protocolAcceptAuditor(auditId);

        vm.prank(assigned);
        cell.acceptAudit(auditId, specErrors);

        vm.prank(assigned);
        cell.provePass(auditId, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(auditId);
    }
}

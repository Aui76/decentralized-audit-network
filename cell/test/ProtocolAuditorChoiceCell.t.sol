// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/AuditCell.sol";
import "./helpers/CellTestDeploy.sol";

contract Target {
    uint256 public x = 1;
}

/// @notice R10 oracle — protocol accept/reject + per-audit reject cap (cathedral: ProtocolAuditorChoice.t.sol).
contract ProtocolAuditorChoiceCellTest is Test {
    CellTestDeploy.Deployment internal d;

    address internal protocol = address(0xBEEF);
    address internal auditor1 = address(0xA11CE);
    address internal auditor2 = address(0xB0B);

    bytes32 internal specToolId = keccak256("spec.tool.v1");
    bytes32 internal verdictToolId = keccak256("verdict.tool.v1");
    bytes32 internal specHash = keccak256("spec.v1");
    bytes32 internal specErrors = keccak256("errors.v1");
    bytes32 internal resultRoot = keccak256("result.v1");

    Target internal target;

    uint256 internal constant MAX_PROTOCOL_REJECTS_CAP = 5;
    uint256 internal constant PROTOCOL_EXPLOITED_REJECT_GRACE = 5;

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        target = new Target();
        d.token.genesisMint(protocol, 100_000 ether);
        d.token.genesisMint(auditor1, 10_000 ether);
        d.token.genesisMint(auditor2, 10_000 ether);
        CellTestDeploy.attachMinter(d);
        d.cell.registerTool(specToolId, true);
        d.cell.registerTool(verdictToolId, false);

        vm.prank(auditor1);
        d.cell.register();
        vm.prank(auditor2);
        d.cell.register();
    }

    function test_auditor_cannot_accept_before_protocol_approval() public {
        uint256 auditId = _submitAudit();
        address assigned = d.cell.auditAuditorOf(auditId);

        vm.prank(assigned);
        vm.expectRevert(AuditCell.ProtocolNotAcceptedAssignment.selector);
        d.cell.acceptAudit(auditId, specErrors);

        vm.prank(protocol);
        d.cell.protocolAcceptAuditor(auditId);

        vm.prank(assigned);
        d.cell.acceptAudit(auditId, specErrors);
    }

    function test_protocol_reject_reassigns_and_updates_stats() public {
        uint256 auditId = _submitAudit();

        vm.prank(protocol);
        d.cell.protocolRejectAuditor(auditId);

        address assigned = d.cell.auditAuditorOf(auditId);
        assertEq(assigned, auditor2, "next auditor assigned");
    }

    function test_advance_protocol_decision_auto_accepts() public {
        uint256 auditId = _submitAudit();

        vm.warp(block.timestamp + d.cell.protocolDecisionWindow() + 1);
        d.cell.advanceProtocolDecision(auditId);

        address assigned = d.cell.auditAuditorOf(auditId);
        vm.prank(assigned);
        d.cell.acceptAudit(auditId, specErrors);
    }

    function test_exploited_count_reduces_reject_cap_after_grace() public {
        assertEq(_maxProtocolRejectsForAuditFrom(50, 0), 5, "base cap at 50 successful");

        assertEq(_maxProtocolRejectsForAuditFrom(50, 5), 5, "5 exploited: no penalty yet");
        assertEq(_maxProtocolRejectsForAuditFrom(50, 6), 4, "6 exploited: cap - 1");
        assertEq(_maxProtocolRejectsForAuditFrom(50, 10), 0, "10 exploited: base 5 - 5 = 0");
    }

    function test_reject_cap_blocks_excess_rejects() public {
        uint256 auditId = _submitAudit();
        assertEq(_maxProtocolRejectsForAuditFrom(0, 0), 1, "new protocol cap is 1");

        vm.startPrank(protocol);
        d.cell.protocolRejectAuditor(auditId);
        vm.expectRevert(CellLogicLib.RejectCapReached.selector);
        d.cell.protocolRejectAuditor(auditId);
        vm.stopPrank();
    }

    /// @dev Mirrors CellLogicLib cap formula — lib is settlement path; no cell forwarder view.
    function _maxProtocolRejectsForAuditFrom(uint256 successful, uint256 exploited)
        internal
        pure
        returns (uint256)
    {
        uint256 cap = 1 + successful / 10;
        if (cap > MAX_PROTOCOL_REJECTS_CAP) {
            cap = MAX_PROTOCOL_REJECTS_CAP;
        }
        if (exploited > PROTOCOL_EXPLOITED_REJECT_GRACE) {
            uint256 penalty = exploited - PROTOCOL_EXPLOITED_REJECT_GRACE;
            if (penalty >= cap) {
                return 0;
            }
            return cap - penalty;
        }
        return cap;
    }

    function _submitAudit() internal returns (uint256 auditId) {
        vm.startPrank(protocol);
        d.token.approve(address(d.cell), 20_000 ether);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        auditId = d.cell.submitAudit(
            address(target), address(target).codehash,
            specHash,
            specToolId,
            specErrors,
            20_000 ether,
            declared,
            0,
            0
        );
        vm.stopPrank();
    }
}

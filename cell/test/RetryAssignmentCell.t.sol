// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellToken.sol";
import "./helpers/CellTestDeploy.sol";

contract Target {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @dev R12: empty-pool submit sticks Submitted until retryAssignment after pool fills.
contract RetryAssignmentCellTest is Test {
    CellToken token;
    AuditCell cell;

    address protocol = address(0xA11CE);
    address auditor = address(0xB0B);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");

    uint256 constant BOUNTY = 10 ether;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        token.genesisMint(protocol, 100 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
    }

    function test_retry_assigns_after_pool_fills() public {
        Target original = new Target(1);
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        uint256 id = cell.submitAudit(address(original), address(original).codehash, specHash, specToolId, specErrors, BOUNTY, declared, 0, 0);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Submitted));
        assertEq(cell.auditAuditorOf(id), address(0));

        vm.prank(auditor);
        cell.register();

        cell.retryAssignment(id);
        assertEq(cell.auditAuditorOf(id), auditor);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Assigned));
    }

    function test_retry_reverts_when_not_submitted() public {
        Target original = new Target(2);
        vm.prank(auditor);
        cell.register();
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        uint256 id = cell.submitAudit(address(original), address(original).codehash, specHash, specToolId, specErrors, BOUNTY, declared, 0, 0);

        vm.expectRevert(AuditCell.WrongState.selector);
        cell.retryAssignment(id);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "./helpers/CellTestDeploy.sol";

/// @notice G1 oracle — gift-free auditor entry (increment dial @ 0, lockable).
contract GiftFreeEntryCellTest is Test {
    CellTestDeploy.Deployment internal d;
    address internal auditor = address(0xA11CE);

    bytes32 internal specToolId = keccak256("spec.tool.v1");
    bytes32 internal verdictToolId = keccak256("verdict.tool.v1");

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
    }

    function test_register_at_increment_zero_without_balance() public {
        assertEq(d.cell.increment(), 0);
        vm.prank(auditor);
        d.cell.register();
        assertEq(d.cell.auditorCount(), 1);
    }

    function test_setIncrement_raises_hold_and_blocks_underfunded() public {
        d.cell.setIncrement(1 ether);
        address first = address(0x1111);
        vm.prank(first);
        d.cell.register();

        vm.prank(auditor);
        vm.expectRevert(AuditCell.InsufficientHold.selector);
        d.cell.register();

        d.token.genesisMint(auditor, 1 ether);
        vm.prank(auditor);
        d.cell.register();
        assertEq(d.cell.auditorCount(), 2);
    }

    function test_lockIncrement_freezes_dial() public {
        d.cell.setIncrement(2 ether);
        d.cell.lockIncrement();
        assertTrue(d.cell.incrementLocked());

        vm.expectRevert(AuditCell.IncrementLockedErr.selector);
        d.cell.setIncrement(0);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellToken.sol";
import "../contracts/ClaimDisputeModule.sol";
import "../contracts/AssignmentModule.sol";

/// @notice X7 Phase 1.4 — wiring-observability events on module setters.
contract CellWiringEventsTest is Test {
    event DisputeModuleSet(uint8 indexed which, address indexed module);
    event AssignmentModuleSet(address indexed module);
    event ParameterUpdated(string indexed name, uint256 value);

    AuditCell cell;
    ClaimDisputeModule claimModule;
    AssignmentModule assignmentModule;

    function setUp() public {
        CellToken token = new CellToken();
        cell = new AuditCell(address(token));
        claimModule = new ClaimDisputeModule(address(this));
        assignmentModule = new AssignmentModule(address(this));
        claimModule.wire(address(cell));
        assignmentModule.wire(address(cell));
    }

    function test_setDisputeModule_emits_DisputeModuleSet() public {
        vm.expectEmit(true, true, false, true, address(cell));
        emit DisputeModuleSet(0, address(claimModule));
        cell.setDisputeModule(0, address(claimModule));
    }

    function test_setAssignmentModule_emits_AssignmentModuleSet() public {
        vm.expectEmit(true, true, false, true, address(cell));
        emit ParameterUpdated("assignmentModule", uint256(uint160(address(assignmentModule))));
        vm.expectEmit(true, true, false, true, address(cell));
        emit AssignmentModuleSet(address(assignmentModule));
        cell.setAssignmentModule(address(assignmentModule));
    }
}

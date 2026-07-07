// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./helpers/SpecValidationCellSetup.sol";
import "../contracts/CellStorage.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/RunDigests.sol";

contract SpecTarget {
    uint256 public x = 1;
}

/// @notice Gate A declare + re-run on the puzzle cell (X1 oracle subset).
contract SpecValidationFlowCellTest is SpecValidationCellSetup {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;

    address protocol = address(0xBEEF);
    bytes32 specToolId = keccak256("spec-validator-v1");
    bytes32 specHash = keccak256("spec-hash");
    bytes32 specErrorsRoot = EMPTY_SPEC_ERRORS;
    bytes32 verdictToolId = keccak256("verdict-tool");

    function setUp() external {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        escrow = d.escrow;
        cell = d.cell;
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        token.genesisMint(protocol, 100_000 ether);
        CellTestDeploy.attachMinter(d);
    }

    function test_submit_reverts_without_spec_tool() external {
        SpecTarget target = new SpecTarget();
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.startPrank(protocol);
        token.approve(address(cell), 1 ether);
        vm.expectRevert(AuditCell.SpecToolRequired.selector);
        cell.submitAudit(address(target), address(target).codehash, specHash, bytes32(0), specErrorsRoot, 1 ether, declared, 0, 0);
        vm.stopPrank();
    }

    function test_submit_reverts_with_verdict_tool_as_spec_tool() external {
        SpecTarget target = new SpecTarget();
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.startPrank(protocol);
        token.approve(address(cell), 1 ether);
        vm.expectRevert(AuditCell.NotSpecValidationTool.selector);
        cell.submitAudit(address(target), address(target).codehash, specHash, verdictToolId, specErrorsRoot, 1 ether, declared, 0, 0);
        vm.stopPrank();
    }

    function test_submit_succeeds_with_declared_spec_tool_and_stores_binding() external {
        SpecTarget target = new SpecTarget();
        uint256 bounty = 5_000 ether;
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;

        vm.startPrank(protocol);
        token.approve(address(cell), bounty);
        uint256 id = cell.submitAudit(address(target), address(target).codehash, specHash, specToolId, specErrorsRoot, bounty, declared, 0, 0);
        vm.stopPrank();

        (, , , , , , bytes32 storedSpecHash, , bytes32 storedTool, bytes32 storedPass, , , , , , , , , , ) =
            cell.audits(id);
        storedSpecHash;
        assertEq(storedSpecHash, specHash);
        assertEq(storedTool, specToolId);
        assertEq(
            RunDigests.specRunDigest(specHash, specToolId, true, specErrorsRoot),
            storedPass
        );
        assertEq(uint256(_auditState(cell, id)), uint256(CellTypeDefs.AuditState.Submitted));
    }
}

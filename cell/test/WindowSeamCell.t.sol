// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "./helpers/SpecValidationCellSetup.sol";
import "../contracts/CellParamIds.sol";
import "../contracts/CellStorage.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/ClaimDisputeModule.sol";

contract WindowTarget {
    uint256 public x = 1;
}

/// @notice G4 oracle — per-audit auditWindow seam (clamp-up floor, dispute inherit, floor lock).
contract WindowSeamCellTest is SpecValidationCellSetup {
    AuditCell cell;
    CellToken token;
    ClaimDisputeModule claimModule;

    address protocol = address(0xBEEF);
    address auditor = address(0xA11CE);
    address claimant = address(0xC1A1);
    address disputeAuditor = address(0xC0DE);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 resultRoot = keccak256("result.v1");
    bytes32 claimRoot = keccak256("claim.proof");

    uint256 constant BOUNTY = 10 ether;
    uint256 constant FLOOR = 1 hours;
    uint256 constant EXTENDED = 3 hours;

    WindowTarget target;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        cell = d.cell;
        token = d.token;
        claimModule = d.claimModule;
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        cell.setParam(CellParamIds.MIN_AUDIT, FLOOR);
        claimModule.setProtocolClaimDecisionWindow(1 hours);
        target = new WindowTarget();
        token.genesisMint(protocol, 100_000 ether);
        token.genesisMint(claimant, 500 ether);
        token.genesisMint(disputeAuditor, 50 ether);
        CellTestDeploy.attachMinter(d);
        vm.prank(auditor);
        cell.register();
        vm.prank(claimant);
        cell.register();
        vm.prank(disputeAuditor);
        cell.register();
    }

    function _submit(uint256 requestedWindow) internal returns (uint256 id) {
        vm.startPrank(protocol);
        token.approve(address(cell), BOUNTY);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        id = cell.submitAudit(
            address(target),
            address(target).codehash,
            specHash,
            specToolId,
            EMPTY_SPEC_ERRORS,
            BOUNTY,
            declared,
            0,
            requestedWindow
        );
        vm.stopPrank();
    }

    function test_zero_request_uses_floor() public {
        uint256 id = _submit(0);
        assertEq(cell.auditWindowOf(id), FLOOR);
    }

    function test_subfloor_request_clamps_up() public {
        uint256 id = _submit(30 minutes);
        assertEq(cell.auditWindowOf(id), FLOOR);
    }

    function test_extended_window_blocks_confirm_until_elapsed() public {
        uint256 id = _submit(EXTENDED);
        _reachAwaitingWindow(cell, id, protocol, verdictToolId, resultRoot);
        uint256 windowStart = block.timestamp;

        vm.warp(windowStart + FLOOR + 1);
        vm.expectRevert(AuditCell.AuditWindowOpen.selector);
        cell.confirmAudit(id);

        vm.warp(windowStart + EXTENDED + 1);
        cell.confirmAudit(id);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InBlock));
    }

    function test_dispute_inherits_original_window() public {
        uint256 originalId = _submit(EXTENDED);
        _reachAwaitingWindow(cell, originalId, protocol, verdictToolId, resultRoot);

        uint256 stake = cell.claimFilingStake();
        vm.startPrank(claimant);
        token.approve(address(cell), stake);
        cell.claimVulnerability(originalId, verdictToolId, claimRoot, "");
        vm.stopPrank();

        vm.prank(protocol);
        claimModule.protocolDeclineDisputeFunding(originalId);

        vm.warp(block.timestamp + claimModule.protocolClaimDecisionWindow() + 1);

        vm.startPrank(claimant);
        token.approve(address(cell), _disputeMin(BOUNTY));
        claimModule.claimantOpenDisputeReaudit(originalId, _disputeMin(BOUNTY));
        vm.stopPrank();

        uint256 disputeId = cell.activeDisputeAuditId(originalId);
        assertTrue(disputeId != 0);
        assertEq(cell.auditWindowOf(disputeId), EXTENDED);
    }

    function test_lockMinAuditWindow_freezes_floor() public {
        cell.setParam(CellParamIds.MIN_AUDIT, 2 hours);
        cell.lockParam(CellParamIds.MIN_AUDIT);
        assertTrue(cell.paramLocked(CellParamIds.MIN_AUDIT));
        vm.expectRevert(CellLogicLib.ParamLockedErr.selector);
        cell.setParam(CellParamIds.MIN_AUDIT, FLOOR);
    }

    function _disputeMin(uint256 bounty) internal pure returns (uint256) {
        return (bounty * 5000) / 10_000;
    }
}

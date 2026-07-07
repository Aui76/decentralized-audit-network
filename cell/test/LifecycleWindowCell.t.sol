// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "./helpers/SpecValidationCellSetup.sol";
import "../contracts/CellParamIds.sol";
import "../contracts/CellStorage.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/ClaimDisputeModule.sol";

contract LifecycleTarget {
    uint256 public x = 1;
}

/// @notice G5 oracle — param-ized lifecycle windows + full path under testnet time profile.
contract LifecycleWindowCellTest is SpecValidationCellSetup {
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

    uint256 constant DECISION = 5 minutes;
    uint256 constant PROTOCOL_DECISION = 5 minutes;
    uint256 constant IN_AUDIT = 10 minutes;
    uint256 constant MIN_AUDIT = 10 minutes;
    uint256 constant CLAIM_RESOLUTION = 10 minutes;
    uint256 constant PROTOCOL_CLAIM_DECISION = 2 minutes;

    LifecycleTarget target;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        cell = d.cell;
        token = d.token;
        claimModule = d.claimModule;
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        target = new LifecycleTarget();
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

    function _applyTestnetProfile() internal {
        cell.setParam(CellParamIds.DECISION, DECISION);
        cell.setParam(CellParamIds.PROTOCOL_DECISION, PROTOCOL_DECISION);
        cell.setParam(CellParamIds.IN_AUDIT, IN_AUDIT);
        cell.setParam(CellParamIds.MIN_AUDIT, MIN_AUDIT);
        cell.setParam(CellParamIds.CLAIM_RESOLUTION, CLAIM_RESOLUTION);
        claimModule.setProtocolClaimDecisionWindow(PROTOCOL_CLAIM_DECISION);
    }

    function test_setters_move_windows_pre_lock() public {
        cell.setParam(CellParamIds.DECISION, 30 minutes);
        cell.setParam(CellParamIds.PROTOCOL_DECISION, 1 hours);
        cell.setParam(CellParamIds.IN_AUDIT, 2 hours);
        assertEq(cell.decisionWindow(), 30 minutes);
        assertEq(cell.protocolDecisionWindow(), 1 hours);
        assertEq(cell.inAuditWindow(), 2 hours);
    }

    function test_lock_decision_window_freezes_param() public {
        cell.setParam(CellParamIds.DECISION, 30 minutes);
        cell.lockParam(CellParamIds.DECISION);
        assertTrue(cell.paramLocked(CellParamIds.DECISION));
        vm.expectRevert(CellLogicLib.ParamLockedErr.selector);
        cell.setParam(CellParamIds.DECISION, 1 hours);
    }

    function test_lock_protocol_decision_window_freezes_param() public {
        cell.setParam(CellParamIds.PROTOCOL_DECISION, 1 hours);
        cell.lockParam(CellParamIds.PROTOCOL_DECISION);
        assertTrue(cell.paramLocked(CellParamIds.PROTOCOL_DECISION));
        vm.expectRevert(CellLogicLib.ParamLockedErr.selector);
        cell.setParam(CellParamIds.PROTOCOL_DECISION, 2 hours);
    }

    function test_lock_in_audit_window_freezes_param() public {
        cell.setParam(CellParamIds.IN_AUDIT, 2 hours);
        cell.lockParam(CellParamIds.IN_AUDIT);
        assertTrue(cell.paramLocked(CellParamIds.IN_AUDIT));
        vm.expectRevert(CellLogicLib.ParamLockedErr.selector);
        cell.setParam(CellParamIds.IN_AUDIT, 3 hours);
    }

    function test_full_lifecycle_under_testnet_profile() public {
        _applyTestnetProfile();
        assertGt(CLAIM_RESOLUTION, PROTOCOL_CLAIM_DECISION, "R11b ordering");

        vm.startPrank(protocol);
        token.approve(address(cell), BOUNTY);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        uint256 id = cell.submitAudit(
            address(target),
            address(target).codehash,
            specHash,
            specToolId,
            EMPTY_SPEC_ERRORS,
            BOUNTY,
            declared,
            0,
            0
        );
        vm.stopPrank();

        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditor);
        cell.acceptAudit(id, EMPTY_SPEC_ERRORS);
        vm.prank(auditor);
        cell.provePass(id, verdictToolId, resultRoot);

        vm.warp(block.timestamp + MIN_AUDIT + 1);
        cell.confirmAudit(id);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InBlock));

        uint256 stake = cell.claimFilingStake();
        vm.startPrank(claimant);
        token.approve(address(cell), stake);
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");
        vm.stopPrank();

        vm.prank(protocol);
        claimModule.protocolDeclineDisputeFunding(id);
        vm.warp(block.timestamp + PROTOCOL_CLAIM_DECISION + 1);

        uint256 minB = (BOUNTY * 5000) / 10_000;
        vm.startPrank(claimant);
        token.approve(address(cell), minB);
        uint256 disputeId = claimModule.claimantOpenDisputeReaudit(id, minB);
        vm.stopPrank();
        assertGt(disputeId, id);

        address assigned = cell.auditAuditorOf(disputeId);
        vm.prank(assigned);
        cell.acceptAudit(disputeId, EMPTY_SPEC_ERRORS);
        vm.prank(assigned);
        cell.proveFail(disputeId, verdictToolId, claimRoot);
        vm.warp(block.timestamp + MIN_AUDIT + 1);
        cell.confirmAudit(disputeId);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Exploited));

        vm.expectRevert(AuditCell.NotClaimed.selector);
        cell.expireClaim(id);
    }

    function test_advance_in_audit_respects_short_window() public {
        _applyTestnetProfile();

        vm.startPrank(protocol);
        token.approve(address(cell), BOUNTY);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        uint256 id = cell.submitAudit(
            address(target),
            address(target).codehash,
            specHash,
            specToolId,
            EMPTY_SPEC_ERRORS,
            BOUNTY,
            declared,
            0,
            0
        );
        vm.stopPrank();

        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditor);
        cell.acceptAudit(id, EMPTY_SPEC_ERRORS);

        vm.expectRevert(AuditCell.InAuditWindowActive.selector);
        cell.advanceInAudit(id);

        vm.warp(block.timestamp + IN_AUDIT + 1);
        cell.advanceInAudit(id);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Assigned));
    }
}

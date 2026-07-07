// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/ClaimDisputeModule.sol";
import "./helpers/CellTestDeploy.sol";
import "../contracts/CellParamIds.sol";

contract Target {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @dev R11 / F-80: claimant-funded dispute after protocol decline or decision-window lapse.
contract ClaimantDisputeReauditCellTest is Test {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    ClaimDisputeModule claimModule;

    address protocol = address(0xA11CE);
    address auditorA = address(0xB0B);
    address claimant = address(0xDEAD);
    address auditorC = address(0xC0DE);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");
    bytes32 claimRoot = keccak256("claim.proof");

    uint256 constant ORIG_BOUNTY = 40 ether;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        claimModule = d.claimModule;
        escrow = d.escrow;
        token.genesisMint(protocol, 2_000 ether);
        token.genesisMint(claimant, 500 ether);
        token.genesisMint(auditorC, 50 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        claimModule.setProtocolClaimDecisionWindow(1 days);
    }

    function _registerAll() internal {
        vm.prank(auditorA);
        cell.register();
        vm.prank(claimant);
        cell.register();
        vm.prank(auditorC);
        cell.register();
    }

    function _disputeMin(uint256 bounty) internal pure returns (uint256) {
        return (bounty * 5000) / 10_000;
    }

    function _claimedOriginal() internal returns (uint256 id) {
        _registerAll();
        Target original = new Target(1);
        vm.prank(protocol);
        token.approve(address(cell), ORIG_BOUNTY);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        id = cell.submitAudit(address(original), address(original).codehash, specHash, specToolId, specErrors, ORIG_BOUNTY, declared, 0, 0);
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditorA);
        cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);

        uint256 stake = cell.claimFilingStake();
        vm.prank(claimant);
        token.approve(address(cell), stake);
        vm.prank(claimant);
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");
    }

    function _runClaimantFailDispute(uint256 id) internal {
        uint256 minB = _disputeMin(ORIG_BOUNTY);
        vm.startPrank(claimant);
        token.approve(address(cell), minB);
        uint256 disputeId = claimModule.claimantOpenDisputeReaudit(id, minB);
        vm.stopPrank();
        assertGt(disputeId, id);

        address disputeAuditor = cell.auditAuditorOf(disputeId);
        vm.prank(disputeAuditor);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(disputeAuditor);
        cell.proveFail(disputeId, verdictToolId, claimRoot);

        uint256 claimantBefore = token.balanceOf(claimant);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Exploited));
        (, uint256 aFailed,,,,) = cell.auditors(auditorA);
        assertEq(aFailed, 1);
        assertGt(token.balanceOf(claimant), claimantBefore, "discoverer paid + stake refund");
    }

    function test_claimant_lane_blocked_until_decline_or_window() public {
        uint256 id = _claimedOriginal();
        uint256 minB = _disputeMin(ORIG_BOUNTY);

        vm.startPrank(claimant);
        token.approve(address(cell), minB);
        vm.expectRevert(ClaimDisputeModule.ClaimantLaneNotOpen.selector);
        claimModule.claimantOpenDisputeReaudit(id, minB);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days + 1);
        vm.startPrank(claimant);
        token.approve(address(cell), minB);
        uint256 disputeId = claimModule.claimantOpenDisputeReaudit(id, minB);
        vm.stopPrank();
        assertGt(disputeId, id);
    }

    function test_decline_then_claimant_fail_dispute_pays_discoverer() public {
        uint256 id = _claimedOriginal();
        vm.prank(protocol);
        claimModule.protocolDeclineDisputeFunding(id);
        _runClaimantFailDispute(id);
    }

    function test_window_lapse_then_claimant_fail_dispute_pays_discoverer() public {
        uint256 id = _claimedOriginal();
        vm.warp(block.timestamp + 1 days + 1);
        _runClaimantFailDispute(id);
    }

    function test_expire_blocked_during_protocol_decision_window() public {
        claimModule.setProtocolClaimDecisionWindow(7 days);
        cell.setParam(CellParamIds.CLAIM_RESOLUTION, 2 days);

        uint256 id = _claimedOriginal();

        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(AuditCell.ProtocolDisputeDecisionPending.selector);
        cell.expireClaim(id);
    }

    function test_expire_restores_state_after_claimant_lane_open() public {
        uint256 id = _claimedOriginal();
        address origAuditor = cell.auditAuditorOf(id);

        vm.warp(block.timestamp + 1 days + cell.claimResolutionWindow() + 1);
        cell.expireClaim(id);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InBlock));
        (, uint256 aFailed,,,,) = cell.auditors(origAuditor);
        assertEq(aFailed, 0);
    }
}

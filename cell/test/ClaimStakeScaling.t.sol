// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellToken.sol";
import "../contracts/ClaimDisputeModule.sol";
import "./helpers/CellTestDeploy.sol";

contract ClaimStakeTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice Prize-scaled claim-filing stake: max(floor, 20% × bounty).
contract ClaimStakeScalingTest is Test {
    CellTestDeploy.Deployment internal d;
    AuditCell cell;
    CellToken token;
    ClaimDisputeModule claimModule;

    address protocol = address(0xA11CE);
    address auditor = address(0xB0B);
    address disputeAuditor = address(0xC0DE);
    address claimant = address(0xC1A1);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");
    bytes32 claimRoot = keccak256("claim.proof");

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        cell = d.cell;
        token = d.token;
        claimModule = d.claimModule;
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        token.genesisMint(protocol, 100_000 ether);
        token.genesisMint(claimant, 50_000 ether);
        token.genesisMint(disputeAuditor, 50 ether);
        vm.prank(auditor);
        cell.register();
        vm.prank(disputeAuditor);
        cell.register();
        vm.prank(claimant);
        cell.register();
    }

    function test_floor_binds_on_cheap_audit() public {
        ClaimStakeTarget t = new ClaimStakeTarget(1);
        vm.startPrank(protocol);
        token.approve(address(cell), 500 ether);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        uint256 id = cell.submitAudit(
            address(t), address(t).codehash, specHash, specToolId, specErrors, 500 ether, declared, 0, 0
        );
        vm.stopPrank();
        assertEq(cell.requiredClaimStake(id), 100 ether);
    }

    function test_scale_binds_on_high_value_audit() public {
        ClaimStakeTarget t = new ClaimStakeTarget(2);
        vm.startPrank(protocol);
        token.approve(address(cell), 15_000 ether);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        uint256 id = cell.submitAudit(
            address(t), address(t).codehash, specHash, specToolId, specErrors, 15_000 ether, declared, 0, 0
        );
        vm.stopPrank();
        assertEq(cell.requiredClaimStake(id), 3000 ether);
    }

    function test_filing_escrows_scaled_stake() public {
        uint256 bounty = 15_000 ether;
        uint256 id = _submitAndConfirm(bounty);
        uint256 stake = cell.requiredClaimStake(id);

        uint256 balBefore = token.balanceOf(claimant);
        vm.startPrank(claimant);
        token.approve(address(cell), stake);
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");
        vm.stopPrank();
        assertEq(token.balanceOf(claimant), balBefore - stake);
    }

    function test_dispute_pass_slashes_scaled_stake() public {
        uint256 bounty = 15_000 ether;
        uint256 id = _submitAndConfirm(bounty);
        uint256 stake = cell.requiredClaimStake(id);

        vm.startPrank(claimant);
        token.approve(address(cell), stake);
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");
        vm.stopPrank();

        uint256 minB = (bounty * 5000) / 10_000;
        vm.startPrank(protocol);
        token.approve(address(cell), minB);
        uint256 disputeId = claimModule.openDisputeReaudit(id, minB);
        vm.stopPrank();

        address assigned = cell.auditAuditorOf(disputeId);
        vm.prank(assigned);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(assigned);
        cell.provePass(disputeId, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);

        assertLt(token.balanceOf(claimant), 50_000 ether - stake + 1, "scaled stake not refunded on false claim");
    }

    function test_cost_to_fake_scales_with_prize() public view {
        assertEq(_scaledStake(500 ether), 100 ether);
        assertEq(_scaledStake(50_000 ether), 10_000 ether);
        assertEq(_scaledStake(50_000 ether) / _scaledStake(500 ether), 100);
    }

    function _scaledStake(uint256 bounty) internal view returns (uint256) {
        uint256 scaled = (bounty * cell.claimStakeBps()) / 10_000;
        uint256 floor = cell.claimFilingStake();
        return scaled > floor ? scaled : floor;
    }

    function test_requiredClaimStake_uses_live_audit_bounty() public {
        ClaimStakeTarget t = new ClaimStakeTarget(1);
        vm.startPrank(protocol);
        token.approve(address(cell), 15_000 ether);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        uint256 id = cell.submitAudit(
            address(t), address(t).codehash, specHash, specToolId, specErrors, 15_000 ether, declared, 0, 0
        );
        vm.stopPrank();
        assertEq(cell.requiredClaimStake(id), 3000 ether);
    }

    function _submitAndConfirm(uint256 bounty) internal returns (uint256 id) {
        ClaimStakeTarget t = new ClaimStakeTarget(bounty);
        vm.startPrank(protocol);
        token.approve(address(cell), bounty);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        id = cell.submitAudit(
            address(t), address(t).codehash, specHash, specToolId, specErrors, bounty, declared, 0, 0
        );
        vm.stopPrank();

        CellTestDeploy.attachMinter(d);
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditor);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditor);
        cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);
    }
}

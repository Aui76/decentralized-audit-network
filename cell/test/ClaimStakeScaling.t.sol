// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellToken.sol";
import "../contracts/ClaimDisputeModule.sol";
import "../contracts/CellParamIds.sol";
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

    // ---------------------------------------------------------------- INV-4.2
    // Reporting a real flaw stays +EV at EVERY scale - the payout floor must out-scale the
    // filing stake. INV-4.1's converse, and the reason that deterrent is not a muzzle.
    //
    // Submitting pass=false on a normal audit is NOT free: submitVerdictAfterProof's else-branch
    // transfers max(bounty * claimStakeBps, claimFilingStake) FROM the auditor and opens a
    // VulnerabilityClaim. Clearing (pass=true) costs nothing. That asymmetry is deliberate - an
    // accusation is bonded, a clearance is appealable through the exploit window - but it is only
    // safe while the upside out-scales the bond. Both terms are bounty-proportional, so the ratio
    // is scale-invariant: 20% at risk against a 50% floor = 2.5:1 for the honest reporter.
    //
    // SCOPE, stated honestly: these assert the payout CEILING exceeds the stake. The realized
    // payout is min(escrowDraw, effectiveCap, bounty), so a thin escrowDraw can still pay less.
    // What is proved is that the PARAMETERISATION permits +EV, not that every upheld claim clears
    // its stake.

    function test_payout_floor_outscales_claim_stake() public view {
        assertGt(cell.discoveryFloorBps(), cell.claimStakeBps());
    }

    function test_reporting_is_positive_ev_on_cheap_audit() public {
        ClaimStakeTarget t = new ClaimStakeTarget(11);
        vm.startPrank(protocol);
        token.approve(address(cell), 500 ether);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        uint256 id = cell.submitAudit(
            address(t), address(t).codehash, specHash, specToolId, specErrors, 500 ether, declared, 0, 0
        );
        vm.stopPrank();

        uint256 stake = cell.requiredClaimStake(id); // floor binds: 100 ether
        uint256 floorCap = (500 ether * cell.discoveryFloorBps()) / 10_000; // 250 ether
        assertGt(floorCap, stake);
    }

    function test_reporting_is_positive_ev_on_high_value_audit() public {
        ClaimStakeTarget t = new ClaimStakeTarget(12);
        vm.startPrank(protocol);
        token.approve(address(cell), 15_000 ether);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        uint256 id = cell.submitAudit(
            address(t), address(t).codehash, specHash, specToolId, specErrors, 15_000 ether, declared, 0, 0
        );
        vm.stopPrank();

        uint256 stake = cell.requiredClaimStake(id); // scale binds: 3000 ether
        uint256 floorCap = (15_000 ether * cell.discoveryFloorBps()) / 10_000; // 7500 ether
        assertGt(floorCap, stake);
    }

    /// @dev The RED direction, mechanized: the two bps knobs are INDEPENDENT admin levers with
    ///      nothing coupling them, so a calibration that raises the stake past the floor silently
    ///      inverts honest reporting to -EV. Admin is address(this) (CellTestDeploy.deploy), so no
    ///      prank is needed. If this ever stops reverting, the guard above has lost its teeth.
    function test_raising_claim_stake_past_floor_inverts_the_incentive() public {
        cell.setParam(CellParamIds.CLAIM_STAKE_BPS, 6000); // > discoveryFloorBps (5000)
        assertLt(cell.discoveryFloorBps(), cell.claimStakeBps());
    }
}

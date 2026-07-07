// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/ClaimDisputeModule.sol";
import "./helpers/CellTestDeploy.sol";

contract DyadTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice R8+R9 oracle — claimant dyad + triangle dispute exclusions (cathedral: ClaimantDyadExclusion.t.sol).
contract ClaimantDyadExclusionCellTest is Test {
    CellTestDeploy.Deployment internal d;

    address internal protocol = address(0xBEEF);
    address internal auditorA = address(0xA11CE);
    address internal auditorB = address(0xB0B);
    address internal auditorC = address(0xCAFE);
    address internal claimant = address(0xD15C0);

    bytes32 internal specToolId = keccak256("spec.tool.v1");
    bytes32 internal verdictToolId = keccak256("verdict.tool.v1");
    bytes32 internal specHash = keccak256("spec.v1");
    bytes32 internal specErrors = keccak256("errors.v1");
    bytes32 internal resultRoot = keccak256("result.v1");
    bytes32 internal claimRoot = keccak256("claim.proof");

    uint256 internal deploySalt;
    uint256 internal constant BOUNTY = 40 ether;

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        d.token.genesisMint(protocol, 2_000 ether);
        d.token.genesisMint(claimant, 500 ether);
        d.token.genesisMint(auditorA, 50 ether);
        d.token.genesisMint(auditorB, 50 ether);
        d.token.genesisMint(auditorC, 50 ether);
        CellTestDeploy.attachMinter(d);
        d.cell.registerTool(specToolId, true);
        d.cell.registerTool(verdictToolId, false);

        vm.prank(auditorA);
        d.cell.register();
        vm.prank(auditorB);
        d.cell.register();
        vm.prank(auditorC);
        d.cell.register();
        vm.prank(claimant);
        d.cell.register();

        assertFalse(
            d.claimModule.claimantDyadExclusionActive(d.cell.queueLength()),
            "N<100: exclusion off by default"
        );
    }

    function test_small_pool_skips_claimant_dyad_exclusion() public {
        uint256 id1 = _submitOrdinary();
        _completePass(id1);
        _fileClaim(id1);
        uint256 disputeId1 = _resolveClaimViaDispute(id1, true);
        address warmAuditor = d.cell.auditAuditorOf(disputeId1);
        assertGt(d.claimModule.claimantAuditorCompleted(claimant, warmAuditor), 0);
        assertFalse(
            d.claimModule.disputeCandidateBlocked(claimant, protocol, warmAuditor, d.cell.queueLength()),
            "N<100: warm dyad not assignment-blocked"
        );

        uint256 id2 = _submitOrdinary();
        _completePass(id2);
        _fileClaim(id2);

        uint256 minB = (BOUNTY * 5000) / 10_000;
        vm.prank(protocol);
        d.token.approve(address(d.cell), minB);
        vm.prank(protocol);
        d.claimModule.openDisputeReaudit(id2, minB);

        assertFalse(
            d.claimModule.disputeCandidateBlocked(claimant, protocol, warmAuditor, d.cell.queueLength()),
            "N<100: filter still off after second claim"
        );
    }

    function test_fleet_pool_applies_claimant_dyad_exclusion() public {
        d.claimModule.setClaimantDyadExclusionMinQueue(4);
        assertTrue(d.claimModule.claimantDyadExclusionActive(d.cell.queueLength()));

        uint256 id1 = _submitOrdinary();
        _completePass(id1);
        _fileClaim(id1);

        uint256 disputeId1 = _resolveClaimViaDispute(id1, true);
        address warmAuditor = d.cell.auditAuditorOf(disputeId1);
        assertEq(d.claimModule.claimantAuditorCompleted(claimant, warmAuditor), 1);
        assertEq(d.claimModule.claimantProtocolAuditorTriangle(claimant, protocol, warmAuditor), 1);
        assertTrue(
            d.claimModule.disputeCandidateBlocked(claimant, protocol, warmAuditor, d.cell.queueLength()),
            "warm dyad blocked at fleet scale"
        );

        uint256 id2 = _submitOrdinary();
        _completePass(id2);
        _fileClaim(id2);

        uint256 minB = (BOUNTY * 5000) / 10_000;
        vm.prank(protocol);
        d.token.approve(address(d.cell), minB);
        vm.prank(protocol);
        uint256 disputeId2 = d.claimModule.openDisputeReaudit(id2, minB);

        address assigned = d.cell.auditAuditorOf(disputeId2);
        assertTrue(assigned != warmAuditor, "warm claimant dyad excluded at fleet scale");
    }

    function test_fleet_pool_triangle_blocked_when_dyad_cap_allows_one_repeat() public {
        d.claimModule.setClaimantDyadExclusionMinQueue(4);
        d.claimModule.setMaxClaimantDyadRepeats(1);
        d.claimModule.setMaxTriangleRepeats(0);
        assertTrue(d.claimModule.claimantDyadExclusionActive(d.cell.queueLength()));

        uint256 id1 = _submitOrdinary();
        _completePass(id1);
        _fileClaim(id1);

        uint256 disputeId1 = _resolveClaimViaDispute(id1, true);
        address warmAuditor = d.cell.auditAuditorOf(disputeId1);
        assertEq(d.claimModule.claimantAuditorCompleted(claimant, warmAuditor), 1);
        assertEq(d.claimModule.claimantProtocolAuditorTriangle(claimant, protocol, warmAuditor), 1);
        assertTrue(
            d.claimModule.disputeCandidateBlocked(claimant, protocol, warmAuditor, d.cell.queueLength()),
            "warm triangle blocked at fleet scale (dyad cap allows one repeat)"
        );
    }

    function _submitOrdinary() internal returns (uint256 auditId) {
        deploySalt += 1;
        DyadTarget target = new DyadTarget(deploySalt);
        vm.prank(protocol);
        d.token.approve(address(d.cell), BOUNTY);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        auditId = d.cell.submitAudit(
            address(target), address(target).codehash, specHash, specToolId, specErrors, BOUNTY, declared, 0, 0
        );
    }

    function _completePass(uint256 auditId) internal {
        vm.prank(protocol);
        d.cell.protocolAcceptAuditor(auditId);
        address assigned = d.cell.auditAuditorOf(auditId);
        vm.prank(assigned);
        d.cell.acceptAudit(auditId, specErrors);
        vm.prank(assigned);
        d.cell.provePass(auditId, verdictToolId, resultRoot);
        vm.warp(block.timestamp + d.cell.minAuditWindow() + 1);
        vm.prank(assigned);
        d.cell.confirmAudit(auditId);
    }

    function _fileClaim(uint256 auditId) internal {
        uint256 stake = d.cell.claimFilingStake();
        vm.prank(claimant);
        d.token.approve(address(d.cell), stake);
        vm.prank(claimant);
        d.cell.claimVulnerability(auditId, verdictToolId, claimRoot, "");
    }

    function _resolveClaimViaDispute(uint256 auditId, bool failReproduces)
        internal
        returns (uint256 disputeId)
    {
        uint256 minB = (BOUNTY * 5000) / 10_000;
        vm.prank(protocol);
        d.token.approve(address(d.cell), minB);
        vm.prank(protocol);
        disputeId = d.claimModule.openDisputeReaudit(auditId, minB);
        address disputeAuditor = d.cell.auditAuditorOf(disputeId);
        vm.prank(disputeAuditor);
        d.cell.acceptAudit(disputeId, specErrors);
        vm.prank(disputeAuditor);
        if (failReproduces) {
            d.cell.proveFail(disputeId, verdictToolId, claimRoot);
        } else {
            d.cell.provePass(disputeId, verdictToolId, resultRoot);
        }
        vm.warp(block.timestamp + d.cell.minAuditWindow() + 1);
        d.cell.confirmAudit(disputeId);
    }
}

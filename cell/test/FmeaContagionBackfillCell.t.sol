// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/FmeaRegistry.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/CellStorage.sol";
import "../contracts/ClaimDisputeModule.sol";
import "./helpers/CellTestDeploy.sol";

contract Target {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice F-66 / X6: unclassified claim class backfills toolKnownGaps for contagion (oracle: cathedral FmeaContagionBackfill.t.sol).
contract FmeaContagionBackfillCellTest is Test {
    CellTestDeploy.Deployment d;
    AuditCell cell;
    ClaimDisputeModule claimModule;
    FmeaRegistry fmea;

    address protocol = address(0xBEEF);
    address auditor = address(0xA11CE);
    address discoverer = address(0xD15C0);
    address disputeAuditor = address(0xC0DE);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");
    bytes32 claimRoot = keccak256("claim.proof");

    uint256 constant BOUNTY = 40 ether;

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        cell = d.cell;
        claimModule = d.claimModule;
        fmea = d.fmeaRegistry;
        d.token.genesisMint(protocol, 2_000 ether);
        d.token.genesisMint(discoverer, 500 ether);
        d.token.genesisMint(disputeAuditor, 50 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);

        vm.prank(auditor);
        cell.register();
        vm.prank(discoverer);
        cell.register();
        vm.prank(disputeAuditor);
        cell.register();
    }

    function _declared() internal view returns (bytes32[] memory tools) {
        tools = new bytes32[](1);
        tools[0] = verdictToolId;
    }

    function test_unclassified_claim_records_tool_known_gap_on_exploit() external {
        Target t = new Target(1);
        vm.prank(protocol);
        d.token.approve(address(cell), BOUNTY);
        vm.prank(protocol);
        uint256 auditId = cell.submitAudit(address(t), address(t).codehash, specHash, specToolId, specErrors, BOUNTY, _declared(), 0, 0);
        vm.prank(protocol);
        cell.protocolAcceptAuditor(auditId);
        vm.prank(auditor);
        cell.acceptAudit(auditId, specErrors);
        vm.prank(auditor);
        cell.provePass(auditId, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(auditId);

        assertEq(fmea.toolKnownGapCount(specToolId), 0);

        uint256 stake = cell.claimFilingStake();
        vm.prank(discoverer);
        d.token.approve(address(cell), stake);
        vm.prank(discoverer);
        cell.claimVulnerability(auditId, verdictToolId, claimRoot, "");

        uint256 minB = (BOUNTY * 5000) / 10_000;
        vm.prank(protocol);
        d.token.approve(address(cell), minB);
        vm.prank(protocol);
        uint256 disputeId = claimModule.openDisputeReaudit(auditId, minB);

        address assignedDisputeAuditor = cell.auditAuditorOf(disputeId);
        vm.prank(assignedDisputeAuditor);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(assignedDisputeAuditor);
        cell.proveFail(disputeId, verdictToolId, claimRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);

        assertEq(uint256(cell.auditStateOf(auditId)), uint256(CellTypeDefs.AuditState.Exploited));
        assertEq(fmea.toolKnownGapCount(specToolId), 1);
        assertEq(fmea.toolKnownGapAt(specToolId, 0), fmea.unclassifiedVulnerabilityClass());
        (,, bool classExists) = fmea.vulnerabilityClasses(fmea.unclassifiedVulnerabilityClass());
        assertTrue(classExists);
    }

    function test_registered_class_recorded_on_exploit() external {
        bytes32 classId = keccak256("reentrancy.v1");
        bytes32 meta = keccak256("meta.reentrancy");
        fmea.registerVulnerabilityClass(classId, meta);

        Target t = new Target(2);
        vm.prank(protocol);
        d.token.approve(address(cell), BOUNTY);
        vm.prank(protocol);
        uint256 auditId = cell.submitAudit(address(t), address(t).codehash, specHash, specToolId, specErrors, BOUNTY, _declared(), 0, 0);
        vm.prank(protocol);
        cell.protocolAcceptAuditor(auditId);
        vm.prank(auditor);
        cell.acceptAudit(auditId, specErrors);
        vm.prank(auditor);
        cell.provePass(auditId, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(auditId);

        uint256 stake = cell.claimFilingStake();
        vm.prank(discoverer);
        d.token.approve(address(cell), stake);
        vm.prank(discoverer);
        cell.claimVulnerability(auditId, verdictToolId, claimRoot, "", classId);

        uint256 minB = (BOUNTY * 5000) / 10_000;
        vm.prank(protocol);
        d.token.approve(address(cell), minB);
        vm.prank(protocol);
        uint256 disputeId = claimModule.openDisputeReaudit(auditId, minB);
        address assignedDisputeAuditor = cell.auditAuditorOf(disputeId);
        vm.prank(assignedDisputeAuditor);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(assignedDisputeAuditor);
        cell.proveFail(disputeId, verdictToolId, claimRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);

        assertEq(fmea.toolKnownGapAt(specToolId, 0), classId);
    }
}

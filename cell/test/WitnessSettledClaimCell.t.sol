// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/CellStorage.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/WitnessClaimLib.sol";
import "genesis-tools/AuditResultV1.sol";
import "../contracts/ClaimDisputeModule.sol";
import "./helpers/CellTestDeploy.sol";

contract WitnessTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice F-83 Part A: witness+evaluator dispute settlement on the live cell (not digest match).
contract WitnessSettledClaimCellTest is Test {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    ClaimDisputeModule claimModule;

    address protocol = address(0xA11CE);
    address auditorA = address(0xB0B);
    address claimant = address(0xDEAD);
    address auditorC = address(0xC0DE);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 finderToolId = keccak256("finder-tool");
    bytes32 evaluatorToolId = keccak256("eval-tool");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 invariantId = keccak256("INVARIANT_DEMO");
    bytes32 locationCommitment = keccak256("loc-commit");
    bytes32 witnessCommitment = keccak256("witness-bytes");
    bytes32 contextRoot = bytes32(0);
    bytes32 passRoot = keccak256("verdict-pass");

    uint256 constant BOUNTY = 40 ether;
    uint256 nextSalt = 1;

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
        CellTestDeploy.registerDefaultTools(d, specToolId, finderToolId);
        cell.registerTool(evaluatorToolId, false);
        cell.setToolWitnessFlags(evaluatorToolId, true, true);

        vm.prank(auditorA);
        cell.register();
        vm.prank(claimant);
        cell.register();
        vm.prank(auditorC);
        cell.register();
    }

    function _witnessResultRoot(bytes32 pinnedArtifactHash, uint8 verdict) internal view returns (bytes32) {
        WitnessClaimLib.Binding memory b = WitnessClaimLib.Binding({
            evaluatorToolId: evaluatorToolId,
            invariantId: invariantId,
            locationCommitment: locationCommitment,
            witnessCommitment: witnessCommitment,
            contextRoot: contextRoot
        });
        return WitnessClaimLib.resultRoot(b, pinnedArtifactHash, specHash, verdict);
    }

    function _claimedOriginal() internal returns (uint256 id, bytes32 pinnedArtifactHash) {
        WitnessTarget original = new WitnessTarget(nextSalt++);
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = finderToolId;
        vm.prank(protocol);
        id = cell.submitAudit(address(original), address(original).codehash, specHash, specToolId, specErrors, BOUNTY, declared, 0, 0);

        pinnedArtifactHash = address(original).codehash;

        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditorA);
        cell.provePass(id, finderToolId, passRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);

        bytes32 failRoot = _witnessResultRoot(pinnedArtifactHash, AuditResultV1.VERDICT_FAIL);
        uint256 stake = cell.claimFilingStake();
        vm.startPrank(claimant);
        token.approve(address(cell), stake);
        cell.claimVulnerability(
            id,
            finderToolId,
            failRoot,
            "",
            evaluatorToolId,
            invariantId,
            locationCommitment,
            witnessCommitment,
            contextRoot
        );
        vm.stopPrank();
    }

    function test_witness_fail_dispute_exploits_without_auditor_failed() public {
        (uint256 id, bytes32 pinnedArtifactHash) = _claimedOriginal();
        uint256 balBefore = token.balanceOf(claimant);

        bytes32 failRoot = _witnessResultRoot(pinnedArtifactHash, AuditResultV1.VERDICT_FAIL);
        _resolveWitnessDispute(id, failRoot, false);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Exploited));
        assertGt(token.balanceOf(claimant), balBefore);
        (, uint256 aFailed,,,,) = cell.auditors(auditorA);
        assertEq(aFailed, 0, "witness path: no failed++ on original auditor");
    }

    function test_witness_pass_dispute_vindicates_claimant() public {
        (uint256 id, bytes32 pinnedArtifactHash) = _claimedOriginal();
        uint256 stake = cell.claimFilingStake();
        uint256 escrowBefore = escrow.escrowBalance();

        bytes32 passWitnessRoot = _witnessResultRoot(pinnedArtifactHash, AuditResultV1.VERDICT_PASS);
        _resolveWitnessDispute(id, passWitnessRoot, true);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InBlock));
        (,,,,, bool resolved, bool exists,,,,,,) = cell.vulnerabilityClaims(id);
        assertTrue(exists);
        assertTrue(resolved);
        assertGe(escrow.escrowBalance(), escrowBefore + stake, "claim stake slashed to escrow");
    }

    function test_legacy_digest_claim_unchanged() public {
        WitnessTarget original = new WitnessTarget(nextSalt++);
        bytes32 claimRoot = keccak256("claim");

        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = finderToolId;
        vm.prank(protocol);
        uint256 id = cell.submitAudit(address(original), address(original).codehash, specHash, specToolId, specErrors, BOUNTY, declared, 0, 0);

        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditorA);
        cell.provePass(id, finderToolId, passRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);

        vm.startPrank(claimant);
        token.approve(address(cell), cell.claimFilingStake());
        cell.claimVulnerability(id, finderToolId, claimRoot, "");
        vm.stopPrank();

        uint256 minB = (BOUNTY * 5000) / 10_000;
        vm.startPrank(protocol);
        token.approve(address(cell), minB);
        uint256 disputeId = claimModule.openDisputeReaudit(id, minB);
        vm.stopPrank();

        address disputeAuditor = cell.auditAuditorOf(disputeId);
        vm.prank(disputeAuditor);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(disputeAuditor);
        cell.proveFail(disputeId, finderToolId, claimRoot);

        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Exploited));
        (, uint256 aFailed,,,,) = cell.auditors(auditorA);
        assertEq(aFailed, 1, "legacy digest path still failed++");
    }

    function _resolveWitnessDispute(uint256 auditId, bytes32 disputeResultRoot, bool passVerdict) internal {
        uint256 minB = (BOUNTY * 5000) / 10_000;
        vm.startPrank(protocol);
        token.approve(address(cell), minB);
        uint256 disputeId = claimModule.openDisputeReaudit(auditId, minB);
        vm.stopPrank();

        address disputeAuditor = cell.auditAuditorOf(disputeId);
        vm.prank(disputeAuditor);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(disputeAuditor);
        if (passVerdict) {
            cell.provePass(disputeId, evaluatorToolId, disputeResultRoot);
        } else {
            cell.proveFail(disputeId, evaluatorToolId, disputeResultRoot);
        }

        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);
    }
}

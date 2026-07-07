// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/CellStorage.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/ClaimDisputeModule.sol";
import "./helpers/CellTestDeploy.sol";

/// @dev Distinct audited targets — `immutable salt` is embedded in runtime code, so two
///      instances have different codehashes and pass the cell's artifact double-spend pin.
contract Target {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/*
 * The in-vitro heartbeat: does the carved cell metabolize a full cycle the way the
 * cathedral did? Beats — PASS to mint; break (claim -> dispute re-audit on O -> resolve).
 * Faithfulness check on the carving, not new design.
 */
contract CellHeartbeat is Test {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    ClaimDisputeModule claimModule;

    address protocol  = address(0xA11CE);
    address auditorA  = address(0xB0B);
    address adversary = address(0xDEAD);
    address auditorC  = address(0xC0DE);

    bytes32 specToolId    = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash      = keccak256("spec.v1");
    bytes32 specErrors    = keccak256("errors.v1");
    bytes32 resultRoot    = keccak256("result.v1");

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        claimModule = d.claimModule;
        escrow = d.escrow;
        token.genesisMint(protocol, 1_000 ether);
        token.genesisMint(adversary, 300 ether);
        token.genesisMint(auditorC, 50 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
    }

    // ----------------------------------------------------------- beat 1: PASS

    function test_pass_cycle_mints_and_pays() public {
        vm.prank(auditorA);
        cell.register(); // position 1, zero hold

        Target target = new Target(1);
        uint256 bounty = 50 ether;
        vm.prank(protocol);
        token.approve(address(cell), bounty);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        uint256 id = cell.submitAudit(address(target), address(target).codehash, specHash, specToolId, specErrors, bounty, declared, 0, 0);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Assigned), "assigned");
        assertEq(cell.auditAuditorOf(id), auditorA, "auditor is A");

        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);

        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors); // re-run must match Gate A digest

        vm.prank(auditorA);
        cell.provePass(id, verdictToolId, resultRoot);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.AwaitingWindow), "awaiting window");

        uint256 balBefore = token.balanceOf(auditorA);
        vm.warp(block.timestamp + 14 days + 1);
        cell.confirmAudit(id);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InBlock), "in block");
        // auditor received bounty + a non-zero positive-block reward
        assertGt(token.balanceOf(auditorA), balBefore + bounty, "auditor paid bounty + reward");
        (uint256 successful,,,,,) = cell.auditors(auditorA);
        assertEq(successful, 1, "auditor successful++");
    }

    // -------------------------------------------------- beat 2: break + resolve

    function test_break_cycle_resolves_and_pays_discoverer() public {
        vm.prank(auditorA);
        cell.register();
        vm.prank(adversary);
        cell.register();
        vm.prank(auditorC);
        cell.register();

        Target original = new Target(1);
        uint256 bounty = 40 ether;
        vm.prank(protocol);
        token.approve(address(cell), bounty);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        uint256 id = cell.submitAudit(address(original), address(original).codehash, specHash, specToolId, specErrors, bounty, declared, 0, 0);

        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditorA);
        cell.provePass(id, verdictToolId, resultRoot);

        bytes32 claimProof = keccak256("claim.proof");
        uint256 advBefore = token.balanceOf(adversary);
        uint256 claimStake = cell.claimFilingStake();
        vm.prank(adversary);
        token.approve(address(cell), claimStake);
        vm.prank(adversary);
        cell.claimVulnerability(id, verdictToolId, claimProof, "");

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Claimed), "claimed");

        uint256 disputeBounty = (bounty * 5000) / 10_000;
        vm.prank(protocol);
        token.approve(address(cell), disputeBounty);
        vm.prank(protocol);
        uint256 disputeId = claimModule.openDisputeReaudit(id, disputeBounty);

        address disputeAuditor = cell.auditAuditorOf(disputeId);
        assertEq(disputeAuditor, auditorC, "independent third auditor");

        vm.prank(disputeAuditor);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(disputeAuditor);
        cell.proveFail(disputeId, verdictToolId, claimProof);

        vm.warp(block.timestamp + 14 days + 1);
        cell.confirmAudit(disputeId);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Exploited), "original exploited");
        (, uint256 aFailed,,,,) = cell.auditors(auditorA);
        assertEq(aFailed, 1, "original PASS auditor failed++");
        (,, uint256 advFound,,,) = cell.auditors(adversary);
        assertEq(advFound, 1, "discoverer found++");
        assertGt(token.balanceOf(adversary), advBefore, "discoverer net positive (pay + stake refund)");
    }

    // ----------------------------------------------------- beat 3: deadline path

    function test_expire_claim_slashes_stake_restores_original() public {
        vm.prank(auditorA);
        cell.register();
        vm.prank(adversary);
        cell.register();

        Target target = new Target(1);
        uint256 bounty = 40 ether;
        vm.prank(protocol);
        token.approve(address(cell), bounty);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        uint256 id = cell.submitAudit(address(target), address(target).codehash, specHash, specToolId, specErrors, bounty, declared, 0, 0);

        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditorA);
        cell.provePass(id, verdictToolId, resultRoot);

        uint256 claimStake = cell.claimFilingStake();
        vm.prank(adversary);
        token.approve(address(cell), claimStake);
        uint256 advBefore = token.balanceOf(adversary);
        vm.prank(adversary);
        cell.claimVulnerability(id, verdictToolId, keccak256("claim.proof"), "");

        // No fix lands; resolution window elapses; anyone expires the claim.
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        cell.expireClaim(id);

        assertEq(
            uint256(cell.auditStateOf(id)),
            uint256(CellTypeDefs.AuditState.AwaitingWindow),
            "restored to pre-claim state on expire"
        );
        // Deadline path: third-party stake slashed, no discoverer pay, no failed++ on PASS auditor.
        assertLt(token.balanceOf(adversary), advBefore, "claimant lost the stake");
        (, uint256 aFailed,,,,) = cell.auditors(auditorA);
        assertEq(aFailed, 0, "no failed++ on deadline path");
    }
}

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

contract Target {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @dev Claim dispute re-audit (openDisputeReaudit) — settlement by reproduction on O.
contract ClaimDisputeTest is Test {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    ClaimDisputeModule claimModule;

    address protocol = address(0xA11CE);
    address auditorA = address(0xB0B);
    address adversary = address(0xDEAD);
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
        token.genesisMint(adversary, 500 ether);
        token.genesisMint(auditorC, 50 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
    }

    function _registerAll() internal {
        vm.prank(auditorA);
        cell.register();
        vm.prank(adversary);
        cell.register();
        vm.prank(auditorC);
        cell.register();
    }

    function _disputeMin(uint256 bounty) internal pure returns (uint256) {
        return (bounty * 5000) / 10_000;
    }

    function _claimedOriginal() internal returns (uint256 id, Target original) {
        _registerAll();
        original = new Target(1);
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

        uint256 stake = cell.claimFilingStake();
        vm.prank(adversary);
        token.approve(address(cell), stake);
        vm.prank(adversary);
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");
    }

    function test_dispute_reaudit_pins_artifact_and_spec_from_original() public {
        (uint256 id, Target original) = _claimedOriginal();
        uint256 minB = _disputeMin(ORIG_BOUNTY);
        vm.prank(protocol);
        token.approve(address(cell), minB);
        vm.prank(protocol);
        uint256 disputeId = claimModule.openDisputeReaudit(id, minB);

        assertEq(cell.auditProtocolOf(disputeId), protocol);
        assertEq(cell.auditAuditorOf(disputeId), auditorC, "third auditor assigned");
        assertEq(cell.activeDisputeAuditId(id), disputeId);
        (
            ,
            ,
            address deployed,
            ,
            ,
            ,
            bytes32 sHash,
            bytes32 artHash,
            ,
            ,
            ,
            ,
            bool isVuln,
            bool isDisp,
            uint256 linked,
            ,
            ,
            ,
            bytes32 caseRoot,
            uint256 supersedesId
        ) = cell.audits(disputeId);
        assertEq(deployed, address(original));
        assertEq(artHash, address(original).codehash);
        assertEq(sHash, specHash);
        assertEq(caseRoot, cell.caseRootOf(id));
        assertEq(supersedesId, 0);
        assertTrue(isDisp);
        assertFalse(isVuln);
        assertEq(cell.auditLinkedOf(disputeId), id);
    }

    function test_dispute_confirm_skips_positive_block_mint() public {
        (uint256 id,) = _claimedOriginal();
        uint256 supplyBefore = token.totalSupply();
        uint256 heightBefore = cell.blockHeight();
        uint256 minB = _disputeMin(ORIG_BOUNTY);
        vm.prank(protocol);
        token.approve(address(cell), minB);
        vm.prank(protocol);
        uint256 disputeId = claimModule.openDisputeReaudit(id, minB);

        address disputeAuditor = cell.auditAuditorOf(disputeId);
        vm.prank(disputeAuditor);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(disputeAuditor);
        cell.provePass(disputeId, verdictToolId, resultRoot);

        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);

        assertEq(cell.blockHeight(), heightBefore, "G-15: dispute confirm must not advance blockHeight");
        assertEq(token.totalSupply(), supplyBefore, "G-15: dispute confirm must not mint supply");
        assertEq(cell.auditPositiveBlock(disputeId), 0, "G-15: no positive block on dispute row");
        (, uint256 dSuccessful,,,,) = cell.auditors(disputeAuditor);
        assertEq(dSuccessful, 0, "G-15: dispute auditor not successful++");
    }

    function test_dispute_fail_reproduces_pays_and_exploits() public {
        (uint256 id,) = _claimedOriginal();
        uint256 minB = _disputeMin(ORIG_BOUNTY);
        vm.prank(protocol);
        token.approve(address(cell), minB);
        vm.prank(protocol);
        uint256 disputeId = claimModule.openDisputeReaudit(id, minB);

        address disputeAuditor = cell.auditAuditorOf(disputeId);
        vm.prank(disputeAuditor);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(disputeAuditor);
        cell.proveFail(disputeId, verdictToolId, claimRoot);

        uint256 advBefore = token.balanceOf(adversary);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Exploited));
        (, uint256 aFailed,,,,) = cell.auditors(auditorA);
        assertEq(aFailed, 1);
        assertGt(token.balanceOf(adversary), advBefore, "discoverer paid + stake refund");
    }

    function test_dispute_pass_vindicates_original_slashes_claimant() public {
        _registerAll();
        Target original = new Target(1);
        vm.prank(protocol);
        token.approve(address(cell), ORIG_BOUNTY);
        vm.prank(protocol);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        uint256 id = cell.submitAudit(address(original), address(original).codehash, specHash, specToolId, specErrors, ORIG_BOUNTY, declared, 0, 0);
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditorA);
        cell.provePass(id, verdictToolId, resultRoot);

        uint256 advBeforeClaim = token.balanceOf(adversary);
        uint256 stake = cell.claimFilingStake();
        vm.prank(adversary);
        token.approve(address(cell), stake);
        vm.prank(adversary);
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");
        uint256 advAfterClaim = token.balanceOf(adversary);
        assertEq(advAfterClaim, advBeforeClaim - stake, "stake escrowed at claim");

        uint256 minB = _disputeMin(ORIG_BOUNTY);
        vm.prank(protocol);
        token.approve(address(cell), minB);
        vm.prank(protocol);
        uint256 disputeId = claimModule.openDisputeReaudit(id, minB);

        address disputeAuditor = cell.auditAuditorOf(disputeId);
        vm.prank(disputeAuditor);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(disputeAuditor);
        cell.provePass(disputeId, verdictToolId, resultRoot);

        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);

        assertEq(
            uint256(cell.auditStateOf(id)),
            uint256(CellTypeDefs.AuditState.AwaitingWindow),
            "original restored"
        );
        assertEq(token.balanceOf(adversary), advAfterClaim, "stake not refunded on false claim");
        assertLt(token.balanceOf(adversary), advBeforeClaim, "claimant lost stake");
        (, uint256 aFailed,,,,) = cell.auditors(auditorA);
        assertEq(aFailed, 0);
    }

    function test_fix_confirm_no_longer_resolves_claim() public {
        (uint256 id,) = _claimedOriginal();
        Target fixTarget = new Target(2);
        vm.prank(protocol);
        token.approve(address(cell), 20 ether);
        vm.prank(protocol);
        uint256 fixId = cell.submitFixAudit(address(fixTarget), specHash, specToolId, specErrors, 20 ether, id);
        address fixAuditor = cell.auditAuditorOf(fixId);
        vm.prank(fixAuditor);
        cell.acceptAudit(fixId, specErrors);
        vm.prank(fixAuditor);
        cell.provePass(fixId, verdictToolId, keccak256("fix.result"));

        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(fixId);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Claimed), "still claimed");
    }

    function test_dispute_no_eligible_auditor_blocks_expire_g16() public {
        vm.prank(auditorA);
        cell.register();
        vm.prank(adversary);
        cell.register();
        // No fourth auditor — only P, A, C in the story; queue has A + C, both excluded.

        Target original = new Target(99);
        vm.prank(protocol);
        token.approve(address(cell), ORIG_BOUNTY);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        uint256 id = cell.submitAudit(address(original), address(original).codehash, specHash, specToolId, specErrors, ORIG_BOUNTY, declared, 0, 0);
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditorA);
        cell.provePass(id, verdictToolId, resultRoot);

        uint256 stake = cell.claimFilingStake();
        vm.prank(adversary);
        token.approve(address(cell), stake);
        vm.prank(adversary);
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");

        uint256 minB = _disputeMin(ORIG_BOUNTY);
        vm.prank(protocol);
        token.approve(address(cell), minB);
        vm.prank(protocol);
        uint256 disputeId = claimModule.openDisputeReaudit(id, minB);

        assertEq(cell.auditAuditorOf(disputeId), address(0), "no eligible dispute auditor");
        assertEq(uint256(cell.auditStateOf(disputeId)), uint256(CellTypeDefs.AuditState.Submitted));

        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        vm.expectRevert(AuditCell.DisputeOpen.selector);
        cell.expireClaim(id);

        uint256 protocolBefore = token.balanceOf(protocol);
        claimModule.expireDispute(id);
        assertEq(cell.activeDisputeAuditId(id), 0, "dispute slot cleared");
        assertEq(token.balanceOf(protocol), protocolBefore + minB, "bounty refunded to funder");

        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        cell.expireClaim(id);
        assertEq(
            uint256(cell.auditStateOf(id)),
            uint256(CellTypeDefs.AuditState.AwaitingWindow),
            "claim expirable after G-16 unlock"
        );
    }

    function test_dispute_assignee_not_claimant_nor_original_auditor() public {
        (uint256 id,) = _claimedOriginal();
        uint256 minB = _disputeMin(ORIG_BOUNTY);
        vm.prank(protocol);
        token.approve(address(cell), minB);
        vm.prank(protocol);
        uint256 disputeId = claimModule.openDisputeReaudit(id, minB);
        address d = cell.auditAuditorOf(disputeId);
        assertTrue(d != auditorA && d != adversary && d != protocol);
    }

    function test_claim_rejects_undeclared_verdict_tool() public {
        _registerAll();
        bytes32 otherTool = keccak256("other.verdict.tool");
        cell.registerTool(otherTool, false);

        Target original = new Target(99);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        token.approve(address(cell), ORIG_BOUNTY);
        vm.prank(protocol);
        uint256 id = cell.submitAudit(address(original), address(original).codehash, specHash, specToolId, specErrors, ORIG_BOUNTY, declared, 0, 0);
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditorA);
        cell.provePass(id, verdictToolId, resultRoot);

        uint256 stake = cell.claimFilingStake();
        vm.prank(adversary);
        token.approve(address(cell), stake);
        vm.prank(adversary);
        vm.expectRevert(AuditCell.ToolNotDeclared.selector);
        cell.claimVulnerability(id, otherTool, claimRoot, "");
    }
}

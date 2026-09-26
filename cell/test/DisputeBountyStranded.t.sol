// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellToken.sol";
import "../contracts/ClaimDisputeModule.sol";
import "../contracts/IntegrityReviewModule.sol";
import "./helpers/CellTestDeploy.sol";

contract StrandTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice PC-87, FLIPPED in the hull window's G1 (VD-199, D1 option A: the cell pays a dispute row's bounty at confirm).
///
///         WHAT THIS FILE PINNED UNTIL G1: a claim dispute's bounty was pulled from its funder
///         (`ClaimDisputeModule._openDisputeReaudit`) and written to the dispute row as `a.bounty` with `bountyEscrowed`
///         never set (`CellLogicLib.initDisputeRow`). `confirmAudit` pays only `if (a.bountyEscrowed)`, so a SETTLED
///         dispute left the cell holding exactly the dispute bounty, owed to no one, and the drawn dispute auditor - who
///         did the work - received 0. Measured from an empty cell on both verdicts (2026-09-15, `ce69b80`).
///
///         WHAT IT ASSERTS NOW, one invariant per test (walkthrough section 2, I1 and VD-101's custody rule):
///           - a settled dispute pays its drawn auditor and leaves the cell holding NOTHING, on both verdicts;
///           - an EXPIRED dispute row is terminal (`Invalidated`), its bounty zeroed and its flag cleared, the funder
///             refunded once, `DisputeExpired` emitted (PC-110), and the drawn auditor's verdict REFUSED (PC-95(2));
///           - a VOIDED dispute row refunds the party that FUNDED it, once, never the disputed protocol.
///
///         THE ACCOUNTING LINE (VD-182(1), VD-199(4)): on the FAIL branch the protocol also receives the undisbursed
///         half of the ORIGINAL bounty - the discoverer is paid half, the protocol the rest - which is why the first
///         draft of this file, asserting "the funder got nothing back", was wrong. It is asserted below as a line of
///         its own so the payout this flip adds is not confused with that refund.
contract DisputeBountyStrandedTest is Test {
    CellToken token;
    AuditCell cell;
    ClaimDisputeModule claimModule;
    IntegrityReviewModule integrity;

    address protocol = address(0xA11CE);
    address auditorA = address(0xB0B);
    address adversary = address(0xDEAD);
    address auditorC = address(0xC0DE);
    address opener = address(0x0FE4);
    address reviewer = address(0x4E71);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 integrityToolId = keccak256("integrity.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");
    bytes32 claimRoot = keccak256("claim.proof");
    uint256 constant ORIG_BOUNTY = 40 ether;

    event DisputeExpired(uint256 indexed originalAuditId, uint256 indexed disputeAuditId);

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        claimModule = d.claimModule;
        integrity = d.integrityReviewModule;
        token.genesisMint(protocol, 2_000 ether);
        token.genesisMint(adversary, 500 ether);
        token.genesisMint(auditorC, 50 ether);
        token.genesisMint(opener, 2_000 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        cell.registerTool(integrityToolId, false);
        vm.prank(auditorA);
        cell.register();
        vm.prank(adversary);
        cell.register();
        vm.prank(auditorC);
        cell.register();
    }

    function _claimedOriginal() internal returns (uint256 id) {
        StrandTarget original = new StrandTarget(1);
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
        vm.prank(adversary);
        token.approve(address(cell), type(uint256).max);
        vm.prank(adversary);
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");
    }

    function _openDispute(uint256 id) internal returns (uint256 disputeId, uint256 bounty) {
        bounty = (ORIG_BOUNTY * 5000) / 10_000;
        vm.prank(protocol);
        token.approve(address(cell), bounty);
        vm.prank(protocol);
        disputeId = claimModule.openDisputeReaudit(id, bounty);
    }

    function _assertTerminalAndEmpty(uint256 disputeId) internal view {
        assertEq(
            uint256(cell.auditStateOf(disputeId)), uint256(CellTypeDefs.AuditState.Invalidated),
            "an ended dispute row is TERMINAL (I1)"
        );
        assertEq(cell.getAudit(disputeId).bounty, 0, "its bounty field is zeroed, so no later exit can pay it again");
        assertFalse(cell.auditBountyEscrowed(disputeId), "the flag clears where custody ends (VD-101)");
    }

    /// FAIL reproduces: the claimant wins (original row Exploited, claim resolved), the dispute settles.
    function test_after_a_FAIL_dispute_settles_the_drawn_auditor_is_paid_and_the_cell_holds_nothing() public {
        assertEq(token.balanceOf(address(cell)), 0, "empty cell");
        uint256 id = _claimedOriginal();
        uint256 protocolBeforeDispute = token.balanceOf(protocol);
        (uint256 disputeId, uint256 bounty) = _openDispute(id);
        assertTrue(cell.auditBountyEscrowed(disputeId), "D1 option A: the dispute row holds its bounty in escrow");
        address disputeAuditor = cell.auditAuditorOf(disputeId);
        uint256 auditorBefore = token.balanceOf(disputeAuditor);

        vm.prank(disputeAuditor);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(disputeAuditor);
        cell.proveFail(disputeId, verdictToolId, claimRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Exploited), "original settled: Exploited");
        assertEq(cell.activeDisputeAuditId(id), 0, "dispute settled");
        assertEq(token.balanceOf(disputeAuditor), auditorBefore + bounty, "the drawn dispute auditor is PAID the dispute bounty");
        assertFalse(cell.auditBountyEscrowed(disputeId), "and the flag cleared where custody ended");
        assertEq(token.balanceOf(address(cell)), 0, "the cell holds NOTHING once every row has settled");
        // THE ACCOUNTING LINE: the protocol funded the dispute (-bounty) and receives the undisbursed half of the
        // ORIGINAL bounty (+ORIG_BOUNTY/2). Those two happen to be equal here, so its net over the dispute is zero.
        assertEq(
            token.balanceOf(protocol), protocolBeforeDispute - bounty + ORIG_BOUNTY / 2,
            "the protocol: dispute bounty out, undisbursed half of the original bounty back"
        );

        vm.expectRevert(); // nothing left to refund: the lane is closed once the dispute has settled
        claimModule.expireDispute(id);
    }

    /// PASS reproduces: the original auditor is vindicated; confirm the original too, so every row has settled.
    function test_after_a_PASS_dispute_and_the_original_settle_the_drawn_auditor_is_paid_and_the_cell_holds_nothing() public {
        assertEq(token.balanceOf(address(cell)), 0, "empty cell");
        uint256 id = _claimedOriginal();
        (uint256 disputeId, uint256 bounty) = _openDispute(id);
        address disputeAuditor = cell.auditAuditorOf(disputeId);
        uint256 auditorBefore = token.balanceOf(disputeAuditor);

        vm.prank(disputeAuditor);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(disputeAuditor);
        cell.provePass(disputeId, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);
        assertEq(cell.activeDisputeAuditId(id), 0, "dispute settled");

        vm.warp(block.timestamp + cell.claimResolutionWindow() + cell.minAuditWindow() + 1);
        cell.confirmAudit(id); // the vindicated original pays its auditor
        // >= : the auditor also receives a MINTED reward (0.625 here), which comes from issuance, not the cell's balance.
        assertGe(token.balanceOf(auditorA), ORIG_BOUNTY, "the original auditor was paid its bounty (plus minted reward)");

        assertEq(token.balanceOf(disputeAuditor), auditorBefore + bounty, "the drawn dispute auditor is PAID the dispute bounty");
        assertEq(token.balanceOf(address(cell)), 0, "the cell holds NOTHING once every row has settled");
    }

    /// PC-87's expiry half, PC-95(2) and PC-110: an expired dispute row ends, and says so.
    function test_an_expired_claim_dispute_row_is_terminal_zeroed_emits_and_refuses_the_verdict() public {
        uint256 id = _claimedOriginal();
        uint256 cellBeforeDispute = token.balanceOf(address(cell));
        uint256 protocolBeforeDispute = token.balanceOf(protocol);
        (uint256 disputeId,) = _openDispute(id);
        address disputeAuditor = cell.auditAuditorOf(disputeId);
        vm.prank(disputeAuditor);
        cell.acceptAudit(disputeId, specErrors); // the drawn auditor holds the row, then goes silent

        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        vm.expectEmit(true, true, false, false, address(cell));
        emit DisputeExpired(id, disputeId);
        claimModule.expireDispute(id);

        _assertTerminalAndEmpty(disputeId);
        assertEq(token.balanceOf(protocol), protocolBeforeDispute, "the funder is refunded");
        // PC-115 (G4): the protocol-funded dispute ended unverdicted, so the claim resolved UNADJUDICATED with it and the
        // claimant's stake left the cell too. What the cell still holds is the original's escrowed bounty.
        (,,,, uint256 claimStake,,,,,,,,) = cell.vulnerabilityClaims(id);
        assertEq(token.balanceOf(address(cell)), cellBeforeDispute - claimStake, "the cell keeps nothing of the dispute");

        vm.prank(disputeAuditor);
        vm.expectRevert(); // a zombie row must not take a verdict (PC-95(2))
        cell.proveFail(disputeId, verdictToolId, claimRoot);

        vm.expectRevert(); // one expiry, one refund
        claimModule.expireDispute(id);
    }

    /// Custody on the VOID exit: a claimant-funded dispute row voided by an integrity review refunds the CLAIMANT, once.
    function test_a_voided_claimant_funded_dispute_row_refunds_its_funder_once() public {
        uint256 id = _claimedOriginal();
        vm.warp(block.timestamp + cell.protocolDecisionWindow() + claimModule.protocolClaimDecisionWindow() + 1);
        uint256 bounty = (ORIG_BOUNTY * 5000) / 10_000;
        uint256 claimantBefore = token.balanceOf(adversary);
        vm.prank(adversary);
        uint256 disputeId = claimModule.claimantOpenDisputeReaudit(id, bounty);
        address disputeAuditor = cell.auditAuditorOf(disputeId);
        vm.prank(disputeAuditor);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(disputeAuditor);
        cell.provePass(disputeId, verdictToolId, resultRoot);

        // registered AFTER the draw, so neither can be the dispute row's auditor
        vm.prank(opener);
        cell.register();
        vm.prank(reviewer);
        cell.register();
        uint256 reviewBounty = 10 ether;
        vm.startPrank(opener);
        token.approve(address(cell), integrity.integrityFilingStake() + reviewBounty);
        integrity.openIntegrityReview(disputeId, integrityToolId, reviewBounty);
        vm.stopPrank();
        vm.prank(reviewer);
        integrity.submitIntegrityVerdict(disputeId, false, keccak256("integrity-fail"));
        vm.warp(block.timestamp + integrity.integrityContestWindow() + 1);

        uint256 protocolBefore = token.balanceOf(protocol);
        integrity.finalizeIntegrityReview(disputeId);

        _assertTerminalAndEmpty(disputeId);
        assertEq(token.balanceOf(adversary), claimantBefore, "the claimant who FUNDED the row is refunded");
        assertEq(token.balanceOf(protocol), protocolBefore, "the disputed protocol receives nothing of it");

        (,,,, uint256 claimStake,,,,,,,,) = cell.vulnerabilityClaims(id);
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        claimModule.expireDispute(id); // the lane still unwinds, and pays the bounty nothing twice
        // G3 (VD-207(2)): this expiry also resolves the claimant-funded claim UNADJUDICATED, so the claim STAKE comes back
        // - and nothing else: the dispute bounty was refunded once, by the void.
        assertEq(token.balanceOf(adversary), claimantBefore + claimStake, "no second bounty refund; only the claim stake");
    }
}

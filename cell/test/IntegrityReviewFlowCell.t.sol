// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./helpers/SpecValidationCellSetup.sol";
import "../contracts/CellStorage.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/IntegrityReviewModule.sol";

contract IntegrityTarget {
    uint256 public x = 1;
}

/// @notice F-52 integrity review on puzzle cell + IntegrityReviewModule (X4 oracle).
contract IntegrityReviewFlowCellTest is SpecValidationCellSetup {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    IntegrityReviewModule integrity;
    IntegrityTarget target;

    address protocol = address(0xBEEF);
    address auditor = address(0xA11CE);
    address opener = address(0x999999);
    address reviewer = address(0xE00E);

    bytes32 specToolId = keccak256("spec-tool");
    bytes32 verdictToolId = keccak256("audit-tool");
    bytes32 integrityToolId = keccak256("integrity-tool");
    bytes32 specHash = keccak256("spec-hash");
    bytes32 resultRoot = keccak256("verdict-pass");

    uint256 bounty = 10_000 ether;
    uint256 reviewBounty = 1_000 ether;

    function setUp() external {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        escrow = d.escrow;
        cell = d.cell;
        integrity = d.integrityReviewModule;
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        cell.registerTool(integrityToolId, false);

        target = new IntegrityTarget();
        token.genesisMint(protocol, 100_000 ether);
        token.genesisMint(auditor, 10_000 ether);
        token.genesisMint(opener, 50_000 ether);
        token.genesisMint(reviewer, 10_000 ether);
        CellTestDeploy.attachMinter(d);

        vm.prank(auditor);
        cell.register();
        vm.prank(reviewer);
        cell.register();
        vm.prank(opener);
        cell.register();
    }

    function _awaitingWindowAudit() internal returns (uint256 auditId) {
        vm.startPrank(protocol);
        token.approve(address(cell), bounty);
        bytes32[] memory tools = new bytes32[](1);
        tools[0] = verdictToolId;
        auditId = cell.submitAudit(
            address(target), address(target).codehash,
            specHash,
            specToolId,
            EMPTY_SPEC_ERRORS,
            bounty,
            tools,
            0,
            0
        );
        vm.stopPrank();

        _reachAwaitingWindow(cell, auditId, protocol, verdictToolId, resultRoot);
    }

    function _openReview(uint256 auditId) internal {
        uint256 total = integrity.integrityFilingStake() + reviewBounty;
        vm.startPrank(opener);
        token.approve(address(cell), total);
        integrity.openIntegrityReview(auditId, integrityToolId, reviewBounty);
        vm.stopPrank();
    }

    function _submitVerdictAndWaitContest(uint256 auditId, bool pass, bytes32 root) internal {
        vm.prank(reviewer);
        integrity.submitIntegrityVerdict(auditId, pass, root);
        vm.warp(block.timestamp + integrity.integrityContestWindow() + 1);
    }

    function _inBlockAudit() internal returns (uint256 auditId) {
        auditId = _awaitingWindowAudit();
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(auditId);
        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.InBlock));
    }

    function test_integrity_run_digest() external view {
        bytes32 root = keccak256("integrity-pass");
        bytes32 expected = keccak256(
            abi.encodePacked("AUDIT_INTEGRITY_RUN_V1", uint256(7), integrityToolId, bytes1(0x01), root)
        );
        assertEq(integrity.integrityRunDigest(7, integrityToolId, true, root), expected);
    }

    function test_open_blocks_confirm() external {
        uint256 auditId = _awaitingWindowAudit();
        _openReview(auditId);

        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        vm.expectRevert(AuditCell.IntegrityReviewActive.selector);
        cell.confirmAudit(auditId);
    }

    function test_pass_finalize_pays_reviewer() external {
        uint256 auditId = _awaitingWindowAudit();
        _openReview(auditId);

        bytes32 root = keccak256("integrity-cleared");
        _submitVerdictAndWaitContest(auditId, true, root);

        uint256 reviewerBefore = token.balanceOf(reviewer);
        integrity.finalizeIntegrityReview(auditId);

        assertEq(token.balanceOf(reviewer), reviewerBefore + reviewBounty);
        assertEq(
            uint256(integrity.integrityReviewStatusOf(auditId)),
            uint256(IntegrityReviewModule.IntegrityReviewStatus.Cleared)
        );

        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(auditId);
        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.InBlock));
    }

    function test_reverts_finalize_before_contest_window() external {
        uint256 auditId = _awaitingWindowAudit();
        _openReview(auditId);

        vm.prank(reviewer);
        integrity.submitIntegrityVerdict(auditId, true, keccak256("integrity-cleared"));

        vm.expectRevert(IntegrityReviewModule.ContestWindowOpen.selector);
        integrity.finalizeIntegrityReview(auditId);
    }

    function test_reverts_open_when_opener_is_protocol() external {
        uint256 auditId = _awaitingWindowAudit();
        uint256 total = integrity.integrityFilingStake() + reviewBounty;

        vm.startPrank(protocol);
        token.approve(address(cell), total);
        vm.expectRevert(IntegrityReviewModule.OpenerCannotBeProtocol.selector);
        integrity.openIntegrityReview(auditId, integrityToolId, reviewBounty);
        vm.stopPrank();
    }

    function test_fail_voids_awaiting_window() external {
        uint256 auditId = _awaitingWindowAudit();
        uint256 failedBefore = _auditorFailed(cell, auditor);
        _openReview(auditId);

        _submitVerdictAndWaitContest(auditId, false, keccak256("integrity-fail"));

        integrity.finalizeIntegrityReview(auditId);

        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.Invalidated));
        assertEq(
            uint256(integrity.integrityReviewStatusOf(auditId)),
            uint256(IntegrityReviewModule.IntegrityReviewStatus.Sustained)
        );
        assertEq(_auditorFailed(cell, auditor), failedBefore + 1);
    }

    function test_fail_invalidates_in_block() external {
        uint256 auditId = _inBlockAudit();
        bytes32 artifactHash = address(target).codehash;
        assertTrue(cell.artifactRegistered(artifactHash));
        uint256 failedBefore = _auditorFailed(cell, auditor);

        _openReview(auditId);
        _submitVerdictAndWaitContest(auditId, false, keccak256("integrity-fail-inblock"));

        integrity.finalizeIntegrityReview(auditId);

        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.Invalidated));
        assertFalse(cell.artifactRegistered(artifactHash));
        assertEq(_auditorFailed(cell, auditor), failedBefore + 1);
    }

    function test_expire_slash_filing_refund_bounty() external {
        uint256 auditId = _awaitingWindowAudit();
        uint256 filing = integrity.integrityFilingStake();
        uint256 escrowBefore = escrow.escrowBalance();
        uint256 openerBefore = token.balanceOf(opener);

        _openReview(auditId);

        vm.warp(block.timestamp + integrity.integrityReviewWindow() + 1);
        integrity.expireIntegrityReview(auditId);

        assertEq(escrow.escrowBalance(), escrowBefore + filing);
        assertEq(token.balanceOf(opener), openerBefore - filing);
        assertEq(
            uint256(integrity.integrityReviewStatusOf(auditId)),
            uint256(IntegrityReviewModule.IntegrityReviewStatus.Expired)
        );
    }

    /// @notice REPLACES `test_treasury_match_paid_on_finalize_pass` (section B-2, VD-89(4)). The
    ///         `integrityMatchBps` limb it exercised is REMOVED, so the behaviour it pinned no longer
    ///         exists to pin. What survives is the fact the removal must not disturb: the integrity escrow
    ///         bucket is no longer touched by an opening at all, whatever it holds.
    function test_open_no_longer_draws_on_the_integrity_escrow_bucket() external {
        uint256 escrowFund = 50_000 ether;
        vm.prank(protocol);
        token.transfer(address(escrow), escrowFund);
        escrow.seedIntegrityBucket(escrowFund);

        uint256 auditId = _awaitingWindowAudit();
        uint256 integrityBefore = escrow.integrityEscrowBalance();

        _openReview(auditId);
        assertEq(escrow.integrityEscrowBalance(), integrityBefore, "opening must not draw a treasury match");

        _submitVerdictAndWaitContest(auditId, true, keccak256("integrity-cleared-match"));

        uint256 reviewerBefore = token.balanceOf(reviewer);
        integrity.finalizeIntegrityReview(auditId);

        assertEq(token.balanceOf(reviewer), reviewerBefore + reviewBounty);
        assertEq(escrow.integrityEscrowBalance(), integrityBefore);
    }

    /// @notice REPLACES `test_protocol_contest_overturns_fail_to_cleared`, and the replacement is a DELIBERATE
    ///         BEHAVIOUR CHANGE, not an update for a removed parameter - it is the only one in this file, and
    ///         it is reported as such. That test pinned the two things VD-89 struck out together: the protocol
    ///         as the sole holder of the contest right, and `finalPass = contested ? contestPass : pass`, a
    ///         contest that OVERWRITES a verdict with no adjudication. A SUSTAINED verdict pays the protocol,
    ///         so under VD-89(2) the protocol has no standing against it; the auditor does, and its contest
    ///         escalates to a drawn adjudicator (driven in IntegrityLaneAdjudication.t.sol).
    function test_protocol_may_not_contest_a_sustained_verdict() external {
        uint256 auditId = _awaitingWindowAudit();
        _openReview(auditId);

        vm.prank(reviewer);
        integrity.submitIntegrityVerdict(auditId, false, keccak256("integrity-fail"));

        uint256 contestStake = integrity.integrityContestStake();
        vm.startPrank(protocol);
        token.approve(address(cell), contestStake);
        vm.expectRevert(IntegrityReviewModule.NoStanding.selector);
        integrity.contestIntegrityVerdict(auditId, true, keccak256("protocol-contest-pass"));
        vm.stopPrank();

        // The verdict stands unamended and settles as an UNCONTESTED sustain.
        vm.warp(block.timestamp + integrity.integrityContestWindow() + 1);
        integrity.finalizeIntegrityReview(auditId);
        assertEq(
            uint256(integrity.integrityReviewStatusOf(auditId)),
            uint256(IntegrityReviewModule.IntegrityReviewStatus.Sustained)
        );
    }
}

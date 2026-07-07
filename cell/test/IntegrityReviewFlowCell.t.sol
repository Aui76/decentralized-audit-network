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

    function test_treasury_match_paid_on_finalize_pass() external {
        uint256 escrowFund = 50_000 ether;
        vm.prank(protocol);
        token.transfer(address(escrow), escrowFund);
        escrow.seedIntegrityBucket(escrowFund);

        integrity.setIntegrityMatchBps(5_000);

        uint256 auditId = _awaitingWindowAudit();
        uint256 matchExpected = (reviewBounty * 5_000) / 10_000;
        uint256 integrityBefore = escrow.integrityEscrowBalance();

        _openReview(auditId);
        assertEq(escrow.integrityEscrowBalance(), integrityBefore - matchExpected);

        _submitVerdictAndWaitContest(auditId, true, keccak256("integrity-cleared-match"));

        uint256 reviewerBefore = token.balanceOf(reviewer);
        integrity.finalizeIntegrityReview(auditId);

        assertEq(token.balanceOf(reviewer), reviewerBefore + reviewBounty);
        assertEq(escrow.integrityEscrowBalance(), integrityBefore);
    }

    function test_protocol_contest_overturns_fail_to_cleared() external {
        uint256 auditId = _awaitingWindowAudit();
        _openReview(auditId);

        vm.prank(reviewer);
        integrity.submitIntegrityVerdict(auditId, false, keccak256("integrity-fail"));

        uint256 contestStake = integrity.integrityContestStake();
        vm.startPrank(protocol);
        token.approve(address(cell), contestStake);
        integrity.contestIntegrityVerdict(auditId, true, keccak256("protocol-contest-pass"));
        vm.stopPrank();

        vm.warp(block.timestamp + integrity.integrityContestWindow() + 1);
        integrity.finalizeIntegrityReview(auditId);

        assertEq(
            uint256(integrity.integrityReviewStatusOf(auditId)),
            uint256(IntegrityReviewModule.IntegrityReviewStatus.Cleared)
        );
        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.AwaitingWindow));
    }
}

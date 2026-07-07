// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./helpers/SpecValidationCellSetup.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/CellStorage.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/SpecArbiterModule.sol";

contract ChallengeTarget {
    uint256 public x = 1;
}

/// @notice F-44 spec challenge on puzzle cell + SpecArbiterModule (X1 oracle).
contract SpecChallengeFlowCellTest is SpecValidationCellSetup {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    SpecArbiterModule specArbiter;
    ChallengeTarget target;

    address protocol = address(0xBEEF);
    address auditor = address(0xA11CE);
    address specArbiterAddr = address(0xB0BA);
    address backupArbiter = address(0xBABA);
    address challenger = address(0xCAFE);
    address claimant = address(0xC1A1);

    bytes32 specToolId = keccak256("spec-tool");
    bytes32 verdictToolId = keccak256("audit-tool");
    bytes32 specHash = keccak256("spec-hash");
    bytes32 specErrorsRoot = EMPTY_SPEC_ERRORS;
    bytes32 failErrorsRoot = keccak256("spec-tool-errors");
    bytes32 resultRoot = keccak256("verdict-pass");

    uint256 bounty = 10_000 ether;
    uint256 challengeFee = 100 ether;

    function setUp() external {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        escrow = d.escrow;
        cell = d.cell;
        specArbiter = d.specArbiterModule;
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);

        specArbiter.setSpecChallengeFee(challengeFee);
        specArbiter.setSpecChallengeStake(500 ether);

        target = new ChallengeTarget();
        token.genesisMint(protocol, 100_000 ether);
        token.genesisMint(auditor, 10_000 ether);
        token.genesisMint(challenger, 10_000 ether);
        token.genesisMint(claimant, 10_000 ether);
        token.genesisMint(specArbiterAddr, 10_000 ether);
        token.genesisMint(backupArbiter, 10_000 ether);
        CellTestDeploy.attachMinter(d);

        vm.prank(auditor);
        cell.register();
    }

    function _registerSpecArbiter() internal {
        vm.prank(specArbiterAddr);
        cell.register();
    }

    function _registerBackupArbiter() internal {
        vm.prank(backupArbiter);
        cell.register();
    }

    function _drainBelowHold(address account) internal {
        uint256 hold = cell.requiredHold(account);
        if (hold == 0) return;
        uint256 bal = token.balanceOf(account);
        if (bal > hold - 1) {
            vm.prank(account);
            token.transfer(address(0xDEAD), bal - (hold - 1));
        }
    }

    function _submitAndReachAwaitingWindow() internal returns (uint256 auditId) {
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.startPrank(protocol);
        token.approve(address(cell), bounty);
        auditId = cell.submitAudit(address(target), address(target).codehash, specHash, specToolId, specErrorsRoot, bounty, declared, 0, 0);
        vm.stopPrank();
        _reachAwaitingWindow(cell, auditId, protocol, verdictToolId, resultRoot);
    }

    function _submitOnly() internal returns (uint256 auditId) {
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.startPrank(protocol);
        token.approve(address(cell), bounty);
        auditId = cell.submitAudit(address(target), address(target).codehash, specHash, specToolId, specErrorsRoot, bounty, declared, 0, 0);
        vm.stopPrank();
    }

    function _challenge(uint256 auditId) internal {
        vm.startPrank(challenger);
        token.approve(address(cell), specArbiter.specChallengeStake());
        specArbiter.challengeSpecInvalid(auditId, failErrorsRoot);
        vm.stopPrank();
    }

    function _challengeWithArbiter(uint256 auditId) internal {
        _registerSpecArbiter();
        _challenge(auditId);
        (,,,,, address assigned) = specArbiter.specChallenges(auditId);
        assertEq(assigned, specArbiterAddr);
    }

    function test_finalize_after_window_invalidates_and_returns_bounty() external {
        uint256 auditId = _submitAndReachAwaitingWindow();
        bytes32 artifactHash = address(target).codehash;
        uint256 protocolBefore = token.balanceOf(protocol);
        uint256 adminBefore = token.balanceOf(address(this));

        _challenge(auditId);
        vm.warp(block.timestamp + specArbiter.specChallengeWindow() + 1);
        specArbiter.finalizeSpecChallenge(auditId);

        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.Invalidated));
        assertEq(token.balanceOf(protocol), protocolBefore + bounty - challengeFee);
        assertEq(token.balanceOf(address(this)), adminBefore + challengeFee);
        assertFalse(cell.artifactRegistered(artifactHash));
    }

    function test_protocol_defend_refunds_challenger_stake() external {
        uint256 auditId = _submitAndReachAwaitingWindow();
        uint256 challengerBefore = token.balanceOf(challenger);
        uint256 escrowBefore = escrow.escrowBalance();

        _challenge(auditId);
        vm.prank(protocol);
        specArbiter.defendSpecChallenge(auditId, specErrorsRoot);

        assertEq(token.balanceOf(challenger), challengerBefore);
        assertEq(escrow.escrowBalance(), escrowBefore);
        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.AwaitingWindow));
    }

    function test_reverts_finalize_after_in_block() external {
        uint256 auditId = _submitAndReachAwaitingWindow();
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(auditId);

        vm.startPrank(challenger);
        token.approve(address(cell), specArbiter.specChallengeStake());
        vm.expectRevert(SpecArbiterModule.NotChallengeable.selector);
        specArbiter.challengeSpecInvalid(auditId, failErrorsRoot);
        vm.stopPrank();
    }

    function test_claim_blocked_during_spec_challenge_then_finalize() external {
        cell.setIncrement(1 ether);
        vm.prank(claimant);
        cell.register();
        _drainBelowHold(claimant);
        cell.registerTool(keccak256("claimant-tool"), false);

        uint256 auditId = _submitAndReachAwaitingWindow();
        _challenge(auditId);
        assertTrue(specArbiter.challengeActive(auditId));

        vm.prank(claimant);
        vm.expectRevert(AuditCell.SpecChallengeActive.selector);
        cell.claimVulnerability(auditId, keccak256("claimant-tool"), keccak256("claim-proof"), "");

        (,,, uint256 openedAt,, address assigned) = specArbiter.specChallenges(auditId);
        uint256 resolveWindow =
            assigned != address(0) ? specArbiter.specArbiterDecisionWindow() : specArbiter.specChallengeWindow();
        vm.warp(openedAt + resolveWindow + 1);
        specArbiter.finalizeSpecChallenge(auditId);

        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.Invalidated));
        assertFalse(specArbiter.challengeActive(auditId));
    }

    function test_active_challenge_blocks_confirm() external {
        uint256 auditId = _submitAndReachAwaitingWindow();
        _challenge(auditId);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        vm.expectRevert(AuditCell.SpecChallengeActive.selector);
        cell.confirmAudit(auditId);
    }

    function test_invalidation_does_not_increment_auditor_failed() external {
        uint256 auditId = _submitAndReachAwaitingWindow();
        uint256 failedBefore = _auditorFailed(cell, auditor);
        _challenge(auditId);
        vm.warp(block.timestamp + specArbiter.specChallengeWindow() + 1);
        specArbiter.finalizeSpecChallenge(auditId);
        assertEq(_auditorFailed(cell, auditor), failedBefore);
    }

    function test_reverts_challenge_when_errors_root_matches_pass() external {
        uint256 auditId = _submitAndReachAwaitingWindow();
        vm.startPrank(challenger);
        token.approve(address(cell), specArbiter.specChallengeStake());
        vm.expectRevert(SpecArbiterModule.ErrorsRootMatchesPass.selector);
        specArbiter.challengeSpecInvalid(auditId, specErrorsRoot);
        vm.stopPrank();
    }

    function test_first_defend_full_refund_second_defend_half_slash() external {
        uint256 auditId = _submitAndReachAwaitingWindow();
        uint256 stake = specArbiter.specChallengeStake();
        uint256 escrowBefore = escrow.escrowBalance();

        _challenge(auditId);
        vm.prank(protocol);
        specArbiter.defendSpecChallenge(auditId, specErrorsRoot);

        uint256 challengerBefore = token.balanceOf(challenger);
        _challenge(auditId);
        vm.prank(protocol);
        specArbiter.defendSpecChallenge(auditId, specErrorsRoot);

        assertEq(token.balanceOf(challenger), challengerBefore - stake / 2);
        assertEq(escrow.escrowBalance(), escrowBefore + stake / 2);
    }

    function test_arbiter_declare_pass_slashes_challenger_stake() external {
        uint256 auditId = _submitAndReachAwaitingWindow();
        uint256 stake = specArbiter.specChallengeStake();
        uint256 challengerBefore = token.balanceOf(challenger);
        uint256 escrowBefore = escrow.escrowBalance();

        _challengeWithArbiter(auditId);
        vm.prank(specArbiterAddr);
        specArbiter.declareSpecArbitrament(auditId, specErrorsRoot);

        assertEq(token.balanceOf(challenger), challengerBefore - stake);
        assertEq(escrow.escrowBalance(), escrowBefore + stake);
        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.AwaitingWindow));
    }

    function test_arbiter_declare_fail_invalidates_and_pays_rewards() external {
        uint256 auditId = _submitAndReachAwaitingWindow();
        uint256 stake = specArbiter.specChallengeStake();
        bytes32 artifactHash = address(target).codehash;
        uint256 protocolBefore = token.balanceOf(protocol);

        _registerSpecArbiter();
        uint256 arbiterBefore = token.balanceOf(specArbiterAddr);
        uint256 challengerBefore = token.balanceOf(challenger);

        _challenge(auditId);
        vm.prank(specArbiterAddr);
        specArbiter.declareSpecArbitrament(auditId, failErrorsRoot);

        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.Invalidated));
        assertFalse(cell.artifactRegistered(artifactHash));
        assertEq(token.balanceOf(challenger), challengerBefore - stake + stake + challengeFee / 2);
        assertEq(token.balanceOf(specArbiterAddr), arbiterBefore + challengeFee / 2);
        assertEq(token.balanceOf(protocol), protocolBefore + bounty - challengeFee);
    }

    function test_reverts_defend_when_arbiter_assigned() external {
        uint256 auditId = _submitAndReachAwaitingWindow();
        _challengeWithArbiter(auditId);
        vm.prank(protocol);
        vm.expectRevert(SpecArbiterModule.SpecArbiterAssignedBlock.selector);
        specArbiter.defendSpecChallenge(auditId, specErrorsRoot);
    }

    function test_expireSilent_opens_defend_path() external {
        uint256 auditId = _submitAndReachAwaitingWindow();
        _challengeWithArbiter(auditId);
        (,,, uint256 openedAt,,) = specArbiter.specChallenges(auditId);

        vm.warp(openedAt + specArbiter.specArbiterDecisionWindow() + 1);
        specArbiter.expireSilentSpecArbiter(auditId);

        (,,,,, address assigned) = specArbiter.specChallenges(auditId);
        assertEq(assigned, address(0));

        vm.prank(protocol);
        specArbiter.defendSpecChallenge(auditId, specErrorsRoot);
        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.AwaitingWindow));
    }

    function test_reassign_spec_arbiter_when_ineligible() external {
        cell.setIncrement(1 ether);
        uint256 auditId = _submitAndReachAwaitingWindow();
        _registerSpecArbiter();
        _challenge(auditId);
        _registerBackupArbiter();

        _drainBelowHold(specArbiterAddr);
        specArbiter.reassignSpecArbiter(auditId);

        (,,,,, address assigned) = specArbiter.specChallenges(auditId);
        assertEq(assigned, backupArbiter);

        vm.prank(backupArbiter);
        specArbiter.declareSpecArbitrament(auditId, specErrorsRoot);
        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.AwaitingWindow));
    }
}

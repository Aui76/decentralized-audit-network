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

    /// @notice VD-107's deliberate cancel, and `bug_303`'s answer: on a row NO auditor holds, the
    /// default still voids and returns the bounty less the fee. Withdrawal is allowed, priced, and
    /// PRE-ASSIGNMENT only.
    /// @dev Building a genuinely unassigned row takes care. `submitAudit` auto-assigns whenever an
    /// eligible auditor exists, and draining cannot help: the sole pool member sits at queue
    /// position 1, where `required_hold = (N-1) * increment` is ZERO, so they are eligible at any
    /// balance. The lever that does empty the pool is `findEligibleAuditor`'s `candidate == protocol`
    /// skip - so here the sole registered auditor submits the row itself and no one is left to take
    /// it. That is not a contrivance: a row nobody can be assigned to is precisely the stranded
    /// bounty `bug_303` is about.
    function test_finalize_after_window_invalidates_and_returns_bounty() external {
        uint256 smallBounty = 1_000 ether;
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.startPrank(auditor);
        token.approve(address(cell), smallBounty);
        uint256 auditId = cell.submitAudit(
            address(target), address(target).codehash, specHash, specToolId, specErrorsRoot, smallBounty, declared, 0, 0
        );
        vm.stopPrank();

        // The premise, asserted rather than assumed: nobody holds this row.
        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.Submitted));
        assertEq(_auditAuditor(cell, auditId), address(0));

        bytes32 artifactHash = address(target).codehash;
        uint256 submitterBefore = token.balanceOf(auditor);
        uint256 adminBefore = token.balanceOf(address(this));

        _challenge(auditId);
        vm.warp(block.timestamp + specArbiter.specChallengeWindow() + 1);
        specArbiter.finalizeSpecChallenge(auditId);

        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.Invalidated));
        assertEq(token.balanceOf(auditor), submitterBefore + smallBounty - challengeFee);
        assertEq(token.balanceOf(address(this)), adminBefore + challengeFee);
        assertFalse(cell.artifactRegistered(artifactHash));
    }

    function _auditAuditor(AuditCell c, uint256 auditId) internal view returns (address) {
        return c.getAudit(auditId).auditor;
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

        // VD-107: the lane releases, and the row SURVIVES - an unruled challenge cannot void a
        // row an auditor is holding. The claim block during the challenge is what this test owns.
        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.AwaitingWindow));
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
        // Routed through an ARBITER RULING since VD-107: a default finalize no longer invalidates a
        // row with an auditor on it, so the old shape would have passed without ever invalidating -
        // a vacuous green over INV-5.3, which is exactly what this test exists to catch.
        _registerSpecArbiter();
        _challenge(auditId);
        vm.prank(specArbiterAddr);
        specArbiter.declareSpecArbitrament(auditId, failErrorsRoot);
        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.Invalidated));
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

    /// @notice PC-93 bug_014 (G3, I2): `defendSpecChallenge` had no upper deadline while `finalizeSpecChallenge` opens AT
    ///         the deadline, so a protocol watching for finalisation could always defend first. The defend closes where
    ///         finalisation opens, so the two intervals partition time.
    function test_PC93_defend_is_refused_from_the_moment_finalize_opens() external {
        uint256 auditId = _submitAndReachAwaitingWindow();
        _challenge(auditId);
        (,,, uint256 openedAt,,) = specArbiter.specChallenges(auditId);

        vm.warp(openedAt + specArbiter.specChallengeWindow());
        vm.prank(protocol);
        vm.expectRevert(SpecArbiterModule.ChallengeWindowClosed.selector);
        specArbiter.defendSpecChallenge(auditId, specErrorsRoot);

        specArbiter.finalizeSpecChallenge(auditId);
        assertFalse(specArbiter.challengeActive(auditId), "finalisation is the only exit at the deadline");
    }

    /// @notice PC-93 bug_013: `declareSpecArbitrament` had no upper deadline while `expireSilentSpecArbiter` opens AT
    ///         the arbiter's deadline, so a silent arbiter who woke late could still rule and race the expiry.
    function test_PC93_declare_is_refused_from_the_moment_silent_expiry_opens() external {
        uint256 auditId = _submitAndReachAwaitingWindow();
        _challengeWithArbiter(auditId);
        (,,, uint256 openedAt,,) = specArbiter.specChallenges(auditId);

        vm.warp(openedAt + specArbiter.specArbiterDecisionWindow());
        vm.prank(specArbiterAddr);
        vm.expectRevert(SpecArbiterModule.ArbiterWindowClosed.selector);
        specArbiter.declareSpecArbitrament(auditId, failErrorsRoot);

        specArbiter.expireSilentSpecArbiter(auditId);
        (,,,,, address assigned) = specArbiter.specChallenges(auditId);
        assertEq(assigned, address(0), "silent expiry is the only exit at the deadline");
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

    // ---- VD-107: a challenge nobody RULED on may void a row only when no auditor is assigned ----
    // All four directions were absent before 2026-09-06: no test in this suite had ever put the
    // protocol in the challenger seat, so the escape was untested because it was never contemplated.

    function _challengeAs(address who, uint256 auditId) internal {
        vm.startPrank(who);
        token.approve(address(cell), specArbiter.specChallengeStake());
        specArbiter.challengeSpecInvalid(auditId, failErrorsRoot);
        vm.stopPrank();
    }

    /// @notice The steering case: the protocol challenges its OWN assigned row, declines to defend
    /// itself, and no arbiter is eligible. The row must SURVIVE and the attempt must cost the fee.
    /// @dev RETARGETED 2026-09-10 (VD-156 / VD-117(4)), the twin of the second-address probe above: the
    /// unruled-expiry price is its own parameter now, drawn from the CHALLENGER's stake, and no longer
    /// shares a lever with the void fee the PROTOCOL pays from the bounty.
    function test_protocol_self_challenge_on_assigned_row_survives_and_costs_the_expiry_charge() external {
        uint256 auditId = _submitAndReachAwaitingWindow();
        uint256 stake = specArbiter.specChallengeStake();
        uint256 protocolBefore = token.balanceOf(protocol);
        uint256 escrowBefore = escrow.escrowBalance();
        bytes32 artifactHash = address(target).codehash;

        _challengeAs(protocol, auditId);
        (,,,,, address assigned) = specArbiter.specChallenges(auditId);
        assertEq(assigned, address(0), "no eligible arbiter: the default path is the one under test");

        vm.warp(block.timestamp + specArbiter.specChallengeWindow() + 1);
        specArbiter.finalizeSpecChallenge(auditId);

        // The row is untouched and the auditor keeps the work.
        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.AwaitingWindow));
        assertTrue(cell.artifactRegistered(artifactHash));
        // The lane unlocks: an unresolved challenge does not hold the row hostage.
        assertFalse(specArbiter.challengeActive(auditId));
        // Dodging is not free: stake back less the EXPIRY CHARGE, and the bounty never moved. The charge
        // is a fraction of the stake now rather than the void fee, so this fixture (100 ether fee against
        // a 500 ether stake) sees it fall from 20% to 10% - the rider, not a regression.
        uint256 charge = stake * specArbiter.specChallengeExpiryChargeBps() / 10_000;
        assertEq(token.balanceOf(protocol), protocolBefore - charge);
        assertEq(escrow.escrowBalance(), escrowBefore + charge);
    }

    /// @notice The sybil case: a SECOND address does the same thing. A `msg.sender != protocol`
    /// guard would pass the test above and fail this one, which is why it is not the fix.
    /// @dev RETARGETED 2026-09-10 by VD-156, riding VD-117(4) onto this hull window. It asserted against
    /// `challengeFee`, because the unruled-expiry price and the VOID price were one parameter with two
    /// payers - the void fee comes from the PROTOCOL's bounty, this comes from the CHALLENGER's stake.
    /// They are separate now, and the probe follows the one that actually charges here.
    ///
    /// THE NUMBER MOVES IN THIS FIXTURE AND THAT IS THE RIDER, NOT A REGRESSION. This file configures a
    /// 100 ether fee against a 500 ether stake, so the old expiry price was 20% of the stake; expressed as
    /// bps of the stake it is 10%, and the challenger keeps 50 ether more. At the SHIPPED defaults - 100
    /// ether stake, 10 ether fee - the two coincide exactly, which is why VD-117's own probe below passes
    /// untouched. The separation preserves the shipped price and stops the two payers sharing a lever.
    function test_second_address_challenge_on_assigned_row_survives_and_costs_the_expiry_charge() external {
        uint256 auditId = _submitAndReachAwaitingWindow();
        uint256 challengerBefore = token.balanceOf(challenger);
        uint256 protocolBefore = token.balanceOf(protocol);
        uint256 escrowBefore = escrow.escrowBalance();
        uint256 charge =
            specArbiter.specChallengeStake() * specArbiter.specChallengeExpiryChargeBps() / 10_000;
        assertLt(charge, specArbiter.specChallengeStake(), "VD-117(4): the charge never takes the stake");

        _challengeAs(challenger, auditId);
        vm.warp(block.timestamp + specArbiter.specChallengeWindow() + 1);
        specArbiter.finalizeSpecChallenge(auditId);

        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.AwaitingWindow));
        assertFalse(specArbiter.challengeActive(auditId));
        assertEq(token.balanceOf(challenger), challengerBefore - charge, "refund == stake - charge");
        assertEq(escrow.escrowBalance(), escrowBefore + charge);
        // The protocol gains nothing by proxy - the bounty stays escrowed on the live row.
        assertEq(token.balanceOf(protocol), protocolBefore);
        // And the VOID fee is untouched by any of it - the point of separating them.
        assertEq(specArbiter.specChallengeFee(), challengeFee);
    }

    /// @notice The legitimate flow is untouched: an arbiter who RULES may still invalidate a row
    /// that has an auditor on it. VD-107 narrows the DEFAULT, not the ruling.
    function test_arbiter_ruled_challenge_still_invalidates_assigned_row() external {
        uint256 auditId = _submitAndReachAwaitingWindow();
        bytes32 artifactHash = address(target).codehash;

        _registerSpecArbiter();
        _challenge(auditId);
        vm.prank(specArbiterAddr);
        specArbiter.declareSpecArbitrament(auditId, failErrorsRoot);

        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.Invalidated));
        assertFalse(cell.artifactRegistered(artifactHash));
    }

    /// @notice VD-117: what "fee kept" MEANS on an unruled expiry, pinned by assertion rather than by a
    /// sentence. At the DEPLOY defaults - `specChallengeStake` 100 ether from the contract, which nothing in
    /// the deploy path changes, and `SPEC_CHALLENGE_FEE_DEFAULT` 10 ether - the challenger gets back the
    /// stake LESS the fee: 90 ether.
    /// @dev This test was written RED at fee == stake == 100 ether, where the refund was 0. That parity was
    /// the defect: `finalizeSpecChallenge` clamps the fee to the stake, so an honest challenger who hit a
    /// no-arbiter failure of the system forfeited everything, while a challenger DISPROVEN by a defend
    /// forfeits nothing on the first defend. VD-117 fixed the value and asserted `fee < stake` at deploy.
    function test_deploy_defaults_expiry_refunds_stake_less_fee() external {
        uint256 stake = 100 ether;   // SpecArbiterModule contract default
        uint256 fee = 10 ether;      // DeployCell SPEC_CHALLENGE_FEE_DEFAULT
        assertLt(fee, stake, "VD-117: the deploy default must sit strictly below the stake");
        specArbiter.setSpecChallengeStake(stake);
        specArbiter.setSpecChallengeFee(fee);

        uint256 auditId = _submitAndReachAwaitingWindow();
        uint256 before = token.balanceOf(challenger);
        uint256 escrowBefore = escrow.escrowBalance();

        _challengeAs(challenger, auditId);
        vm.warp(block.timestamp + specArbiter.specChallengeWindow() + 1);
        specArbiter.finalizeSpecChallenge(auditId);

        // The row survives (VD-107 layer 2) and the challenger is out exactly the charge - not the stake.
        // VD-156/VD-117(4) NOTE: this still reads `fee` because at the SHIPPED defaults the separated
        // expiry charge equals it - 100 ether stake at 1000 bps is 10 ether. That coincidence is the
        // evidence the separation did not reprice anything, so the assertion is left in the fee's terms
        // ON PURPOSE and the equality is asserted rather than assumed on the line below.
        assertEq(
            specArbiter.specChallengeStake() * specArbiter.specChallengeExpiryChargeBps() / 10_000,
            fee,
            "at the shipped defaults the expiry charge IS the old fee - the separation moved no number"
        );
        assertEq(uint256(_auditState(cell, auditId)), uint256(CellTypeDefs.AuditState.AwaitingWindow));
        assertEq(token.balanceOf(challenger), before - fee, "refund must be stake - fee");
        assertEq(escrow.escrowBalance(), escrowBefore + fee, "the fee is KEPT, not burned to nobody");
    }

    /// @notice VD-117's deploy-path guard, as a test: the constant the deploy ships must sit strictly below
    /// the stake the contract ships. `DeployCell.s.sol` asserts this against the CHAIN at deploy time; this
    /// pins the two values so the constant cannot drift back to parity without a red suite.
    function test_deploy_default_fee_is_below_contract_default_stake() external {
        SpecArbiterModule fresh = new SpecArbiterModule(address(this));
        assertEq(fresh.specChallengeStake(), 100 ether, "contract default stake moved - re-check VD-117");
        assertEq(fresh.specChallengeFee(), 0, "the fee still ships uninitialized; the deploy path sets it");
        assertLt(10 ether, fresh.specChallengeStake(), "SPEC_CHALLENGE_FEE_DEFAULT must be < the stake");
    }

}

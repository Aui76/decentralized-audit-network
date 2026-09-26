// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./helpers/SpecValidationCellSetup.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/ClaimDisputeModule.sol";
import "../contracts/SpecArbiterModule.sol";

contract FreezeTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice The hull window's G4 (walkthrough section 3; invariants I3 "a freeze is a freeze" and I4 "no state without an exit
///         the other party cannot block"), beside the pins it flips in place (SecondReviewHighs, StructuralReviewHighs,
///         DisputeExpiryPayee's G3 control).
///
///         (a) PC-91 bug_003 and VD-216(4): the in-audit and decision clocks do not run while a settlement overlay freezes
///             the row. Both timeouts refuse under the freeze, and a spec challenge that ends WITHOUT voiding the row gives
///             the frozen time back (`pickupTime` moves forward by it). A self-claim whose dispute dies unadjudicated gives
///             back its Claimed time, bounded by one self-claim per row; the auditor's OWN lapse gives back nothing.
///         (c) PC-98: a dispute verdict that reproduces neither side is an OUTCOME at confirm, not a revert; and a verdicted
///             claim dispute nobody confirmed for one full resolution window after its audit window is released, with
///             confirm closed at that same instant (I2).
///         PC-115 / PC-116 (VD-216(3)): an unverdicted dispute resolves the claim unadjudicated for BOTH funders, and a
///             funder whose dispute on an original ended that way may not fund another on it.
///
///         New entry points and errors are reached through encoded signatures so this file compiles, and goes RED, on the
///         pre-G4 bytes as it stands.
contract FreezesAndExitsTest is SpecValidationCellSetup {
    CellTestDeploy.Deployment d;
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    ClaimDisputeModule claimModule;
    SpecArbiterModule specArbiter;

    address protocol = address(0xBEEF);
    address auditor = address(0xA11CE);
    address challenger = address(0xCAFE);
    address arbiter = address(0xA4B1);
    address claimant = address(0xDEAD);
    address claimant2 = address(0xD2);
    address reAuditor = address(0xC0DE);

    bytes32 specToolId = keccak256("spec-tool");
    bytes32 verdictToolId = keccak256("audit-tool");
    bytes32 specHash = keccak256("spec-hash");
    bytes32 failErrorsRoot = keccak256("spec-tool-errors");
    bytes32 resultRoot = keccak256("verdict-pass");
    bytes32 failRoot = keccak256("verdict-fail");
    bytes32 claimRoot = keccak256("claim-proof");

    uint256 constant BOUNTY = 1_000 ether;
    uint256 nextSalt = 1;

    function setUp() external {
        d = CellTestDeploy.deploy(address(this));
        token = d.token;
        escrow = d.escrow;
        cell = d.cell;
        claimModule = d.claimModule;
        specArbiter = d.specArbiterModule;
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        specArbiter.setSpecChallengeFee(100 ether);
        specArbiter.setSpecChallengeStake(500 ether);
        token.genesisMint(protocol, 100_000 ether);
        token.genesisMint(challenger, 10_000 ether);
        token.genesisMint(auditor, 10_000 ether);
        token.genesisMint(claimant, 10_000 ether);
        token.genesisMint(claimant2, 10_000 ether);
        CellTestDeploy.attachMinter(d);
    }

    // ------------------------------------------------------------------ helpers

    function _declared() internal view returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = verdictToolId;
    }

    function _submit() internal returns (uint256 id) {
        FreezeTarget t = new FreezeTarget(nextSalt++);
        vm.startPrank(protocol);
        token.approve(address(cell), BOUNTY);
        id = cell.submitAudit(address(t), address(t).codehash, specHash, specToolId, EMPTY_SPEC_ERRORS, BOUNTY, _declared(), 0, 0);
        vm.stopPrank();
    }

    /// A row held InAudit by `auditor`, the only registered address.
    function _held() internal returns (uint256 id, uint256 pickup) {
        vm.prank(auditor);
        cell.register();
        id = _submit();
        _protocolAcceptAndAssignedAccept(cell, id, protocol, EMPTY_SPEC_ERRORS);
        pickup = cell.getAudit(id).pickupTime;
    }

    function _challenge(uint256 id) internal {
        vm.startPrank(challenger);
        token.approve(address(cell), specArbiter.specChallengeStake());
        specArbiter.challengeSpecInvalid(id, failErrorsRoot);
        vm.stopPrank();
    }

    function _selfClaim(uint256 id) internal returns (uint256 claimedAt) {
        vm.startPrank(auditor);
        token.approve(address(cell), cell.requiredClaimStake(id));
        cell.proveFail(id, verdictToolId, failRoot);
        vm.stopPrank();
        claimedAt = block.timestamp;
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Claimed), "the auditor's own claim");
    }

    function _resolved(uint256 id) internal view returns (bool resolved) {
        (, , , , , resolved, , , , , , , ) = cell.vulnerabilityClaims(id);
    }

    /// An original audit passed by `auditor` (AwaitingWindow), claimed by `claimant`, with `reAuditor` registered to draw.
    function _claimedOriginal() internal returns (uint256 id) {
        vm.prank(auditor);
        cell.register();
        vm.prank(claimant);
        cell.register();
        vm.prank(reAuditor);
        cell.register();
        id = _submit();
        _reachAwaitingWindow(cell, id, protocol, verdictToolId, resultRoot);
        _fileClaim(claimant, id);
    }

    function _fileClaim(address who, uint256 id) internal {
        vm.startPrank(who);
        token.approve(address(cell), cell.requiredClaimStake(id));
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");
        vm.stopPrank();
    }

    function _minDispute() internal pure returns (uint256) {
        return (BOUNTY * 5000) / 10_000;
    }

    function _protocolFunds(uint256 id) internal returns (bool ok, uint256 disputeId) {
        vm.startPrank(protocol);
        token.approve(address(cell), _minDispute());
        bytes memory ret;
        (ok, ret) = address(claimModule).call(abi.encodeCall(claimModule.openDisputeReaudit, (id, _minDispute())));
        vm.stopPrank();
        if (ok) disputeId = abi.decode(ret, (uint256));
    }

    function _claimantFunds(address who, uint256 id) internal returns (bool ok, bytes memory ret) {
        vm.startPrank(who);
        token.approve(address(cell), _minDispute());
        (ok, ret) = address(claimModule).call(abi.encodeCall(claimModule.claimantOpenDisputeReaudit, (id, _minDispute())));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ (a) the clock does not run through a freeze

    /// The UNRESOLVED-expiry exit of a challenge (VD-107: an auditor is on the row, so nobody's ruling voids it): the row
    /// survives, and so does the auditor's time.
    function test_G4a_a_finalized_challenge_gives_the_auditor_back_the_frozen_time() public {
        (uint256 id, uint256 pickup) = _held();
        vm.warp(pickup + 6 days);
        _challenge(id);

        vm.warp(pickup + cell.inAuditWindow() + 1);
        vm.expectRevert(CellLogicLib.SpecChallengeActive.selector);
        cell.advanceInAudit(id); // I3: the timeout honours the freeze

        vm.warp(pickup + 6 days + specArbiter.specChallengeWindow());
        specArbiter.finalizeSpecChallenge(id);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InAudit), "the row survived the challenge");
        assertEq(cell.getAudit(id).pickupTime, pickup + specArbiter.specChallengeWindow(), "the frozen time is given back");

        vm.expectRevert(CellLogicLib.InAuditWindowActive.selector);
        cell.advanceInAudit(id); // past the ORIGINAL deadline, and the timeout is still closed
        vm.prank(auditor);
        cell.provePass(id, verdictToolId, resultRoot);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.AwaitingWindow), "and the auditor delivers");
    }

    /// The arbiter's pass ruling ends the freeze without a void too.
    function test_G4a_an_arbiter_ruling_the_spec_valid_gives_the_frozen_time_back() public {
        (uint256 id, uint256 pickup) = _held();
        vm.prank(arbiter);
        cell.register(); // after the draw, so it can only be the arbiter
        vm.warp(pickup + 6 days);
        _challenge(id);
        (, , , , , address drawn) = specArbiter.specChallenges(id);
        assertEq(drawn, arbiter, "the arbiter was drawn");

        vm.warp(pickup + 6 days + 1 hours);
        vm.prank(arbiter);
        specArbiter.declareSpecArbitrament(id, EMPTY_SPEC_ERRORS);
        assertFalse(specArbiter.challengeActive(id), "ruled");
        assertEq(cell.getAudit(id).pickupTime, pickup + 1 hours, "exactly the frozen hour is given back");
    }

    /// The decision clock of an ASSIGNED row: the auditor may not accept under the challenge, so the timeout may not fire
    /// under it either, and the decision window resumes once it is defended.
    function test_G4a_the_decision_clock_of_an_assigned_row_does_not_run_through_a_freeze() public {
        vm.prank(auditor);
        cell.register();
        uint256 id = _submit();
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        uint256 t0 = cell.getAudit(id).pickupTime;
        vm.warp(t0 + 12 hours);
        _challenge(id);

        vm.warp(t0 + cell.decisionWindow() + 1);
        vm.expectRevert(CellLogicLib.SpecChallengeActive.selector);
        cell.advanceAssignment(id);

        vm.prank(protocol);
        specArbiter.defendSpecChallenge(id, EMPTY_SPEC_ERRORS);
        vm.prank(auditor);
        cell.acceptAudit(id, EMPTY_SPEC_ERRORS); // past the original decision deadline, inside the resumed one
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InAudit));
    }

    // ------------------------------------------------------------------ (a) VD-216(4): the self-claim's Claimed time

    /// The no-fault path: the auditor's own claim, disputed, dies unverdicted. The claim resolves unadjudicated and the
    /// Claimed time is excluded from the in-audit clock - once: the row admits ONE self-claim.
    function test_G4a_a_self_claim_whose_dispute_dies_unverdicted_gives_back_its_claimed_time_once() public {
        (uint256 id, uint256 pickup) = _held();
        vm.warp(pickup + 6 days);
        uint256 claimedAt = _selfClaim(id);
        vm.prank(protocol);
        claimModule.protocolDeclineDisputeFunding(id);
        (bool funded,) = _claimantFunds(auditor, id);
        assertTrue(funded, "the auditor funds its own claim's dispute after the protocol declined");

        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        claimModule.expireDispute(id);
        assertTrue(_resolved(id), "resolved unadjudicated");
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InAudit), "the row is back InAudit");
        assertEq(cell.getAudit(id).pickupTime, pickup + (block.timestamp - claimedAt), "the Claimed time is given back");

        vm.startPrank(auditor);
        token.approve(address(cell), cell.requiredClaimStake(id));
        vm.expectRevert(CellLogicLib.ClaimAlreadyExists.selector); // ONE self-claim per row: no second free extension
        cell.proveFail(id, verdictToolId, failRoot);
        cell.provePass(id, verdictToolId, resultRoot); // the auditor still has the day it had left
        vm.stopPrank();
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.AwaitingWindow));
    }

    /// PC-115 on the self-claim: a PROTOCOL-funded dispute that dies unverdicted is no-fault for the auditor as well.
    function test_G4a_a_self_claim_whose_protocol_funded_dispute_dies_gives_back_its_claimed_time() public {
        (uint256 id, uint256 pickup) = _held();
        vm.warp(pickup + 6 days);
        uint256 claimedAt = _selfClaim(id);
        (bool funded,) = _protocolFunds(id);
        assertTrue(funded);
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        claimModule.expireDispute(id);
        assertTrue(_resolved(id), "resolved unadjudicated, whoever funded the dispute");
        assertEq(cell.getAudit(id).pickupTime, pickup + (block.timestamp - claimedAt), "the Claimed time is given back");
    }

    /// VD-218(3): ONE SELF-CLAIM PER AUDITOR PER ROW. The bound rode on `exists`, which no exit clears, so after one auditor's
    /// self-claim resolved a REDRAWN auditor could never report a failure on that row (I1 on the self-claim lane). Another
    /// auditor's resolved claim does not bind; the same auditor's does (the fixture above).
    function test_G4a_a_redrawn_auditor_may_self_claim_after_the_first_auditors_claim_resolved() public {
        (uint256 id, uint256 pickup) = _held();
        address second = address(0x5EC0);
        vm.prank(protocol);
        token.transfer(second, 10_000 ether); // the minter is attached in setUp, so no genesis mint here
        vm.prank(second);
        cell.register();
        vm.warp(pickup + 6 days);
        _selfClaim(id);
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        cell.expireClaim(id); // the first auditor's own lapse: resolved, clock burnt
        cell.advanceInAudit(id); // timed out and redrawn
        if (cell.auditAuditorOf(id) == auditor) {
            vm.prank(protocol); // FIFO drew the first auditor back; the protocol's reject moves the row on
            cell.protocolRejectAuditor(id);
        }
        assertEq(cell.auditAuditorOf(id), second, "the row is redrawn to the second auditor");
        _protocolAcceptAndAssignedAccept(cell, id, protocol, EMPTY_SPEC_ERRORS);

        vm.startPrank(second);
        token.approve(address(cell), cell.requiredClaimStake(id));
        cell.proveFail(id, verdictToolId, keccak256("second-fail"));
        vm.stopPrank();
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Claimed), "the redrawn auditor reports it");
        (address c, , , , , bool resolved, , , , , , , ) = cell.vulnerabilityClaims(id);
        assertEq(c, second);
        assertFalse(resolved);
    }

    /// CONTROL (VD-216(4)): the auditor's OWN lapse - the claim window passing with no proof - pauses nothing.
    function test_G4a_control_the_auditors_own_lapse_gives_back_nothing() public {
        (uint256 id, uint256 pickup) = _held();
        vm.warp(pickup + 6 days);
        _selfClaim(id);
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        cell.expireClaim(id);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InAudit));
        assertEq(cell.getAudit(id).pickupTime, pickup, "no time given back");
        vm.prank(auditor);
        vm.expectRevert(CellLogicLib.InAuditWindowPassed.selector);
        cell.provePass(id, verdictToolId, resultRoot);
        cell.advanceInAudit(id);
    }

    // ------------------------------------------------------------------ (c) PC-98

    /// A verdict that reproduces NEITHER side is an outcome: confirm lands, the claim resolves unadjudicated (stake back,
    /// row back), and the lane is free. Before G4 the resolver reverted and the drawn re-auditor froze the lane at will.
    function test_G4c_a_non_reproducing_dispute_verdict_is_an_outcome_not_a_freeze() public {
        uint256 id = _claimedOriginal();
        (bool funded, uint256 disputeId) = _protocolFunds(id);
        assertTrue(funded);
        address drawn = cell.auditAuditorOf(disputeId);
        assertEq(drawn, reAuditor, "the only address not a party");
        vm.prank(drawn);
        cell.acceptAudit(disputeId, EMPTY_SPEC_ERRORS);
        vm.prank(drawn);
        cell.provePass(disputeId, verdictToolId, keccak256("reproduces-nothing"));

        uint256 claimantBefore = token.balanceOf(claimant);
        (, , , , uint256 stake, , , , , , , , ) = cell.vulnerabilityClaims(id);
        vm.warp(block.timestamp + cell.getAudit(disputeId).auditWindow + 1);
        cell.confirmAudit(disputeId);

        assertTrue(_resolved(id), "the claim resolved - unadjudicated");
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.AwaitingWindow), "the original is back");
        assertEq(cell.activeDisputeAuditId(id), 0, "the dispute slot is clear");
        assertEq(token.balanceOf(claimant) - claimantBefore, stake, "no adjudicated loser: the stake comes back");
    }

    /// The belt beside it: a verdicted claim dispute nobody confirms for a full resolution window after its audit window is
    /// released - the funder refunded, the claim unadjudicated - and confirm closes at that same instant (I2).
    function test_G4c_an_unconfirmed_verdict_is_released_after_one_grace_window_and_confirm_closes_there() public {
        uint256 id = _claimedOriginal();
        (, uint256 disputeId) = _protocolFunds(id);
        vm.prank(reAuditor);
        cell.acceptAudit(disputeId, EMPTY_SPEC_ERRORS);
        vm.prank(reAuditor);
        cell.provePass(disputeId, verdictToolId, resultRoot); // reproduces the original: confirm WOULD vindicate
        uint256 releaseAt = cell.getAudit(disputeId).windowStart + cell.getAudit(disputeId).auditWindow
            + cell.claimResolutionWindow();

        vm.warp(releaseAt - 1);
        vm.expectRevert();
        claimModule.expireDispute(id); // not yet: the winner has the whole window to confirm

        vm.warp(releaseAt);
        uint256 protocolBefore = token.balanceOf(protocol);
        vm.expectRevert();
        cell.confirmAudit(disputeId); // closed where the release opens
        claimModule.expireDispute(id);

        assertEq(uint256(cell.auditStateOf(disputeId)), uint256(CellTypeDefs.AuditState.Invalidated), "the row ended");
        assertEq(token.balanceOf(protocol) - protocolBefore, _minDispute(), "its funder refunded");
        assertTrue(_resolved(id), "and the claim resolved unadjudicated");
        assertEq(token.balanceOf(reAuditor), 0, "nobody confirmed, so nobody was paid");
    }

    // ------------------------------------------------------------------ PC-116: one funded dispute per funder per original

    /// VD-218(1): VD-216(3)'s reopen FIRED - refusing the claimant at the FUNDING site stranded an honest second claim on the
    /// lapse, which slashes. The refusal for a claimant moves to the FILING gate, before any stake moves: one voice per
    /// original per claimant. The finding stays reportable by any other registrant.
    function test_PC116_a_claimant_whose_dispute_died_cannot_file_again_on_that_original() public {
        uint256 id = _claimedOriginal();
        vm.warp(block.timestamp + cell.protocolDecisionWindow() + 1);
        (bool funded,) = _claimantFunds(claimant, id);
        assertTrue(funded);
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        claimModule.expireDispute(id);
        assertTrue(_resolved(id));

        uint256 before = token.balanceOf(claimant);
        vm.startPrank(claimant);
        token.approve(address(cell), cell.requiredClaimStake(id));
        vm.expectRevert(abi.encodeWithSignature("DisputeAlreadySpent()"));
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");
        vm.stopPrank();
        assertEq(token.balanceOf(claimant), before, "refused before any stake moved: nothing to strand");

        vm.prank(claimant2);
        cell.register();
        _fileClaim(claimant2, id); // another registrant still reports it
        assertFalse(_resolved(id), "the finding is still reportable");
    }

    function test_PC116_a_protocol_whose_dispute_died_cannot_fund_another_but_a_fresh_funder_can() public {
        uint256 id = _claimedOriginal();
        (bool funded,) = _protocolFunds(id);
        assertTrue(funded);
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        claimModule.expireDispute(id);
        assertTrue(_resolved(id), "PC-115: resolved unadjudicated although the protocol funded it");

        vm.prank(claimant2);
        cell.register();
        _fileClaim(claimant2, id);
        (bool again,) = _protocolFunds(id);
        assertFalse(again, "the cycle is closed for the protocol");
        vm.warp(block.timestamp + cell.protocolDecisionWindow() + 1);
        (bool fresh,) = _claimantFunds(claimant2, id);
        assertTrue(fresh, "per FUNDER: a claimant who has not spent a dispute on this original still may");
    }
}

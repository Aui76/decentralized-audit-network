// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellToken.sol";
import "../contracts/ClaimDisputeModule.sol";
import "./helpers/CellTestDeploy.sol";

contract ClaimTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice PC-81 and PC-97, FLIPPED in the hull window's G2 (walkthrough section 3, invariant I1: a lane clears on every exit).
///
///         WHAT THIS FILE PINNED UNTIL G2 (bug_001 of the 2026-09-15 second-family review, VD-177/178): a vulnerability
///         claim record was never cleared - every terminal exit wrote only `claim.resolved = true` - while
///         `ClaimDisputeModule.claimVulnerability` refused on `exists`. A lapsed claim returns the audit to a claim-eligible
///         state, so ONE weak claim, lapsed, blocked every later claim on that audit for good; a protocol shielding an
///         exploitable contract paid one stake. PC-97 was masked behind it: a vindicated claim left `activeFixAuditId` set,
///         so the NEXT claim's fix submission would revert `FixAuditAlreadyOpen` - reachable only once PC-81 is cured,
///         which is why the two land in one commit.
///
///         WHAT IT ASSERTS NOW: a claim is refused only while an earlier one is still OPEN; a new filing starts a fresh
///         claim (the protocol's dispute-funding decision included); and the fix pointer clears on every claim exit.
contract ClaimRecordNeverClearedTest is Test {
    CellToken token;
    AuditCell cell;
    ClaimDisputeModule claimModule;
    address integrityModule;

    address protocol = address(0xA11CE);
    address auditorA = address(0xB0B);
    address weakClaimant = address(0xDEAD);
    address honestDiscoverer = address(0xC0DE);
    address disputeAuditor = address(0xD15);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");

    uint256 constant ORIG_BOUNTY = 40 ether;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        claimModule = d.claimModule;
        integrityModule = address(d.integrityReviewModule);
        token.genesisMint(protocol, 2_000 ether);
        token.genesisMint(weakClaimant, 500 ether);
        token.genesisMint(honestDiscoverer, 500 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        vm.prank(auditorA);
        cell.register();
        vm.prank(weakClaimant);
        cell.register();
        // honestDiscoverer registers only when it claims (`_claim`), so it is never a drawable dispute auditor.
    }

    function _passedAudit() internal returns (uint256 id) {
        ClaimTarget original = new ClaimTarget(1);
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
    }

    function _claim(address who, uint256 id, bytes32 root) internal {
        (,,, uint256 position,,) = cell.auditors(who);
        if (position == 0) {
            vm.prank(who);
            cell.register();
        }
        vm.prank(who);
        token.approve(address(cell), type(uint256).max);
        vm.prank(who);
        cell.claimVulnerability(id, verdictToolId, root, "");
    }

    function _claimant(uint256 id) internal view returns (address c, bool resolved, bool exists) {
        (c,,,,, resolved, exists,,,,,,) = cell.vulnerabilityClaims(id);
    }

    /// The weak claim is VINDICATED against by a dispute PASS (the original auditor was right).
    function _vindicateByDispute(uint256 id) internal {
        vm.prank(disputeAuditor);
        cell.register(); // registered after the claim, so it is the only drawable dispute auditor
        uint256 bounty = (ORIG_BOUNTY * 5000) / 10_000;
        vm.prank(protocol);
        token.approve(address(cell), bounty);
        vm.prank(protocol);
        uint256 disputeId = claimModule.openDisputeReaudit(id, bounty);
        assertEq(cell.auditAuditorOf(disputeId), disputeAuditor, "fixture: the only drawable dispute auditor");
        vm.prank(disputeAuditor);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(disputeAuditor);
        cell.provePass(disputeId, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);
    }

    /// Control: a FIRST claim on a passed audit is accepted.
    function test_first_claim_on_a_passed_audit_is_accepted() public {
        uint256 id = _passedAudit();
        _claim(honestDiscoverer, id, keccak256("honest.proof"));
        (,, bool exists) = _claimant(id);
        assertTrue(exists, "the claim is recorded");
    }

    /// Still refused: a second claim while the first is OPEN - one claim at a time is the lane's rule, not the defect.
    function test_a_second_claim_is_refused_while_the_first_is_open() public {
        uint256 id = _passedAudit();
        _claim(weakClaimant, id, keccak256("weak.proof"));
        vm.prank(honestDiscoverer);
        cell.register();
        vm.prank(honestDiscoverer);
        token.approve(address(cell), type(uint256).max);
        vm.expectRevert(); // the audit is Claimed, so it is not even eligible - either refusal is the right one
        vm.prank(honestDiscoverer);
        cell.claimVulnerability(id, verdictToolId, keccak256("honest.proof"), "");
    }

    /// PC-81 FLIPPED: a lapsed weak claim no longer immunises the audit - the honest discoverer's claim is accepted.
    function test_a_lapsed_claim_does_not_block_a_later_claim_on_that_audit() public {
        uint256 id = _passedAudit();
        CellTypeDefs.AuditState before = cell.auditStateOf(id);

        _claim(weakClaimant, id, keccak256("weak.proof"));
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 30 days);
        cell.expireClaim(id);
        assertEq(uint256(cell.auditStateOf(id)), uint256(before), "the audit is back in a claim-eligible state");

        _claim(honestDiscoverer, id, keccak256("honest.proof"));
        (address c, bool resolved, bool exists) = _claimant(id);
        assertEq(c, honestDiscoverer, "the record now describes the NEW claim");
        assertFalse(resolved, "and it is open");
        assertTrue(exists);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Claimed));
    }

    /// PC-81 on the SETTLEMENT exit, and the per-claim state the module keeps: a claim vindicated against by a dispute
    /// does not block the next one, and the protocol's earlier dispute-funding DECISION does not carry into it.
    function test_a_vindicated_claim_does_not_block_a_later_claim_and_its_funding_decision_does_not_carry() public {
        uint256 id = _passedAudit();
        _claim(weakClaimant, id, keccak256("weak.proof"));
        vm.prank(protocol);
        claimModule.protocolDeclineDisputeFunding(id);
        assertTrue(claimModule.claimantDisputeLaneOpen(id), "fixture: the protocol declined funding for the FIRST claim");

        // ... then changes its mind within the lane's rules and funds the dispute itself
        _vindicateByDispute(id);
        (, bool resolved,) = _claimant(id);
        assertTrue(resolved, "the weak claim is settled");

        _claim(honestDiscoverer, id, keccak256("honest.proof"));
        (address c, bool resolved2,) = _claimant(id);
        assertEq(c, honestDiscoverer, "the next claim is accepted");
        assertFalse(resolved2);
        assertFalse(claimModule.disputeFundingDeclined(id), "a decision about the LAST claim is not a decision about this one");
        assertFalse(claimModule.claimantDisputeLaneOpen(id), "so the protocol's own decision window applies afresh");
    }

    /// PC-97, reachable now that PC-81 is cured: the vindicated exit clears the fix pointer, so the next claim's fix
    /// submission is accepted instead of reverting `FixAuditAlreadyOpen` on a lane whose claim is long settled.
    function test_a_vindicated_claim_clears_its_fix_pointer_so_the_next_claims_fix_is_accepted() public {
        uint256 id = _passedAudit();
        _claim(weakClaimant, id, keccak256("weak.proof"));
        ClaimTarget fix1 = new ClaimTarget(2);
        vm.prank(protocol);
        token.approve(address(cell), type(uint256).max);
        vm.prank(protocol);
        uint256 fixId = cell.submitFixAudit(address(fix1), specHash, specToolId, specErrors, 10 ether, id);
        assertEq(cell.activeFixAuditId(id), fixId, "fixture: a fix audit is open during the claim");

        _vindicateByDispute(id);
        assertEq(cell.activeFixAuditId(id), 0, "I1: the vindicated exit clears the fix pointer, as lapse and release do");

        _claim(honestDiscoverer, id, keccak256("honest.proof"));
        ClaimTarget fix2 = new ClaimTarget(3);
        vm.prank(protocol);
        token.approve(address(cell), type(uint256).max); // the dispute's approval replaced the earlier allowance
        vm.prank(protocol);
        uint256 fixId2 = cell.submitFixAudit(address(fix2), specHash, specToolId, specErrors, 10 ether, id);
        assertEq(cell.activeFixAuditId(id), fixId2, "the next claim's fix audit is accepted");
    }

    // ------------------------------------------------------------------ VD-212(a): I4 for the fix audit
    //
    // G2 clears the fix POINTER on every claim exit and does NOT void the fix audit row. That is only sound if the row
    // still has an exit of its own once its claim is gone - if any path of its confirm read the claim record and
    // reverted, the pointer cure would have made a state with no exit (I4). So each claim exit is driven with a fix
    // audit in flight, and the fix audit is taken to a terminal state on its own lifecycle afterwards.

    /// Opens a fix audit on the claimed row and takes it to AwaitingWindow BEFORE the claim exits.
    function _fixInFlight(uint256 id, uint256 salt) internal returns (uint256 fixId) {
        ClaimTarget fix = new ClaimTarget(salt);
        vm.prank(protocol);
        token.approve(address(cell), type(uint256).max);
        vm.prank(protocol);
        fixId = cell.submitFixAudit(address(fix), specHash, specToolId, specErrors, 10 ether, id);
        address fixAuditor = cell.auditAuditorOf(fixId);
        vm.prank(fixAuditor);
        cell.acceptAudit(fixId, specErrors);
        vm.prank(fixAuditor);
        cell.provePass(fixId, verdictToolId, keccak256("fix.result"));
    }

    function _assertFixCompletesAlone(uint256 id, uint256 fixId) internal {
        assertTrue(cell.auditStateOf(id) != CellTypeDefs.AuditState.Claimed, "the original is no longer Claimed");
        assertEq(cell.activeFixAuditId(id), 0, "the pointer cleared on the claim's exit");
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(fixId);
        assertEq(
            uint256(cell.auditStateOf(fixId)), uint256(CellTypeDefs.AuditState.InBlock),
            "I4: the fix audit reaches a terminal state on its OWN lifecycle, with its claim gone"
        );
    }

    function test_I4_after_a_LAPSE_the_fix_audit_still_completes() public {
        uint256 id = _passedAudit();
        _claim(weakClaimant, id, keccak256("weak.proof"));
        uint256 fixId = _fixInFlight(id, 11);
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 30 days);
        cell.expireClaim(id);
        _assertFixCompletesAlone(id, fixId);
    }

    function test_I4_after_a_VINDICATION_the_fix_audit_still_completes() public {
        uint256 id = _passedAudit();
        _claim(weakClaimant, id, keccak256("weak.proof"));
        uint256 fixId = _fixInFlight(id, 12);
        _vindicateByDispute(id);
        _assertFixCompletesAlone(id, fixId);
    }

    function test_I4_after_a_RELEASE_by_void_the_fix_audit_still_completes() public {
        uint256 id = _passedAudit();
        _claim(weakClaimant, id, keccak256("weak.proof"));
        uint256 fixId = _fixInFlight(id, 13);
        vm.prank(integrityModule); // the integrity arm's void, driven directly as IntegrityVoidStrandedStake.t.sol does
        cell.settlementOverlay(1, 2, id, address(0));
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Invalidated), "the original was voided");
        _assertFixCompletesAlone(id, fixId);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/ClaimDisputeModule.sol";
import "../contracts/IntegrityReviewModule.sol";
import "../contracts/SpecArbiterModule.sol";
import "./helpers/CellTestDeploy.sol";

contract Target {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/*
 * bug_104 - an integrity void STRANDS an open claim's stake, permanently.
 *
 * `settlementOverlay` has two arms and they disagree:
 *
 *   kind == 0 (spec arbiter)  - refunds the claimant's stake, sets `claim.resolved = true`,
 *                               clears `activeFixAuditId`, THEN invalidates the row.
 *   kind == 1 (integrity)     - caller check, `_voidAuditRow`, return. The claim is never touched.
 *
 * After the kind==1 arm the row is `Invalidated` and `claim.resolved` is still false - and EVERY
 * stake-release route gates on `Claimed`:
 *     AuditCell.expireClaim:1188        `if (a.state != AuditState.Claimed) revert NotClaimed();`
 *     ClaimDisputeModule:256, :357, :397 `if (uint8(state) != STATE_CLAIMED) revert ...`
 * So the stake is held by the cell with no path that can release it. Not delayed - unreachable.
 *
 * This is the stranding-latch family VD-91(2) opened the window to kill, and the fix is to make the
 * two arms agree: voiding a row releases any open claim on it.
 */
contract IntegrityVoidStrandedStakeTest is Test {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    ClaimDisputeModule claimModule;
    IntegrityReviewModule integrityModule;
    SpecArbiterModule specArbiter;

    address protocol = address(0xA11CE);
    address auditorA = address(0xB0B);
    address claimant = address(0xDEAD);
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
        integrityModule = d.integrityReviewModule;
        specArbiter = d.specArbiterModule;
        token.genesisMint(protocol, 2_000 ether);
        token.genesisMint(claimant, 500 ether);
        token.genesisMint(auditorC, 50 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
    }

    function _registerAll() internal {
        vm.prank(auditorA);
        cell.register();
        vm.prank(claimant);
        cell.register();
        vm.prank(auditorC);
        cell.register();
    }

    /// @dev an audit taken to Claimed, with the claimant's stake held by the cell.
    function _claimedOriginal() internal returns (uint256 id, uint256 stake) {
        _registerAll();
        Target original = new Target(1);
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
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);

        stake = cell.claimFilingStake();
        vm.prank(claimant);
        token.approve(address(cell), stake);
        vm.prank(claimant);
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Claimed), "row is Claimed");
    }

    function _claimResolved(uint256 id) internal view returns (bool resolved) {
        (, , , , , resolved, , , , , , , ) = cell.vulnerabilityClaims(id);
    }

    /* ---------------------------------------------------------------------
     * RED: an integrity void must not leave the claimant's stake unreachable.
     * Before the fix, `resolved` stays false and the balance never moves.
     * ------------------------------------------------------------------- */
    function test_integrity_void_releases_the_open_claim_stake() public {
        (uint256 id, uint256 stake) = _claimedOriginal();
        assertGt(stake, 0, "the claim posted a real stake");

        uint256 before = token.balanceOf(claimant);

        vm.prank(address(integrityModule));
        cell.settlementOverlay(1, 2, id, address(0));

        assertEq(
            uint256(cell.auditStateOf(id)),
            uint256(CellTypeDefs.AuditState.Invalidated),
            "the void itself still happens - this fix adds to it, it does not replace it"
        );
        assertTrue(_claimResolved(id), "the open claim must be resolved by the void");
        assertEq(
            token.balanceOf(claimant) - before,
            stake,
            "the claimant's stake must come back - after Invalidated no path can ever release it"
        );
    }

    /* ---------------------------------------------------------------------
     * The stranding, stated as the reason the above matters: once the row is
     * Invalidated, the release routes all refuse. This pins WHY a delayed
     * refund is not an option - there is no later.
     * ------------------------------------------------------------------- */
    function test_after_void_every_release_route_refuses() public {
        (uint256 id, ) = _claimedOriginal();

        vm.prank(address(integrityModule));
        cell.settlementOverlay(1, 2, id, address(0));

        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        vm.expectRevert(AuditCell.NotClaimed.selector);
        cell.expireClaim(id);
    }

    /* ---------------------------------------------------------------------
     * VD-101 acceptance, the THEFT direction pinned by its own assertion.
     *
     * The bounty is paid to the auditor at confirm. `bountyEscrowed` used to
     * stay true afterwards, so a later void believed it still held those
     * tokens and transferred them to the protocol - out of whatever the cell
     * happened to hold, which on a claimed row is the claimant's stake.
     * `state != InBlock` was meant to prevent it; filing a claim moves the row
     * to Claimed and walks around the guard.
     *
     * This asserts the direction directly rather than inferring it from the
     * stake test passing: after the void, the protocol receives NOTHING.
     * ------------------------------------------------------------------- */
    function test_void_of_confirmed_then_claimed_row_pays_the_protocol_nothing() public {
        (uint256 id, ) = _claimedOriginal();

        // The bounty has already left: the auditor was paid at confirm, and the
        // cell now holds only the claimant's stake.
        assertGe(token.balanceOf(auditorA), ORIG_BOUNTY, "auditor was paid the bounty at confirm");
        assertEq(
            token.balanceOf(address(cell)),
            cell.claimFilingStake(),
            "the cell holds the claim stake and NOTHING else - there is no bounty left to refund"
        );
        assertFalse(
            cell.auditBountyEscrowed(id),
            "VD-101: the flag must be FALSE once the bounty has been paid out"
        );

        uint256 protocolBefore = token.balanceOf(protocol);

        vm.prank(address(integrityModule));
        cell.settlementOverlay(1, 2, id, address(0));

        assertEq(
            token.balanceOf(protocol),
            protocolBefore,
            "the void must transfer NOTHING to the protocol - the bounty was already spent"
        );
    }

    /* ---------------------------------------------------------------------
     * CONTROL: the spec-arbiter arm already did this correctly. It must keep
     * doing it - the fix factors the shared behaviour out, so this pins that
     * the refactor did not move kind==0's semantics.
     * ------------------------------------------------------------------- */
    function test_spec_arbiter_arm_still_refunds_and_resolves() public {
        (uint256 id, uint256 stake) = _claimedOriginal();
        uint256 before = token.balanceOf(claimant);

        vm.prank(address(specArbiter));
        cell.settlementOverlay(0, 2, id, address(0));

        assertTrue(_claimResolved(id), "kind==0 resolves, as it always did");
        assertEq(token.balanceOf(claimant) - before, stake, "kind==0 refunds, as it always did");
        assertEq(
            uint256(cell.auditStateOf(id)),
            uint256(CellTypeDefs.AuditState.Invalidated),
            "kind==0 still invalidates"
        );
    }
}

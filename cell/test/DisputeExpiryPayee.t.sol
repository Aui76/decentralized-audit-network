// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/ClaimDisputeModule.sol";
import "./helpers/CellTestDeploy.sol";
import "../contracts/CellParamIds.sol";

contract Target {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/*
 * bug_203 / bug_302 (one finding, two ids) - the dispute expiry refund pays the WRONG PARTY.
 *
 * `claimantOpenDisputeReaudit` pulls the bounty from the CLAIMANT (ClaimDisputeModule:407,
 * `settlementToken(0, funder, ...)` with `funder = msg.sender`), and `initDisputeRow` records that
 * funder in `a.lastDiscoverer` while setting `a.protocol = orig.protocol` - the party being disputed.
 * `settlementExpireClaimDispute` then refunded `d.protocol`.
 *
 * So an expired dispute handed the funder's stake to the party they were disputing. The in-repo oracle
 * for the correct pattern is `SpecGapModule`:308, which reads `address funder = ad.lastDiscoverer;`
 * before refunding - same situation, right answer, in a sibling module.
 *
 * WHY THIS SURVIVED: no test in the suite called `settlementExpireClaimDispute` or the module's
 * `expireDispute` at all. The path had zero coverage, so nothing disagreed with it.
 */
contract DisputeExpiryPayeeTest is Test {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    ClaimDisputeModule claimModule;

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
        token.genesisMint(protocol, 2_000 ether);
        token.genesisMint(claimant, 500 ether);
        token.genesisMint(auditorC, 50 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        claimModule.setProtocolClaimDecisionWindow(1 days);
    }

    function _registerAll() internal {
        vm.prank(auditorA);
        cell.register();
        vm.prank(claimant);
        cell.register();
        vm.prank(auditorC);
        cell.register();
    }

    function _disputeMin(uint256 bounty) internal pure returns (uint256) {
        return (bounty * 5000) / 10_000;
    }

    /// @dev an original audit taken to Claimed, with the claimant holding an open claim.
    ///      Copied from ClaimantDisputeReauditCell.t.sol so the two agree on the setup shape.
    function _claimedOriginal() internal returns (uint256 id) {
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

        uint256 stake = cell.claimFilingStake();
        vm.prank(claimant);
        token.approve(address(cell), stake);
        vm.prank(claimant);
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");
    }

    /* ---------------------------------------------------------------------
     * RED: the funder must get the bounty back when the dispute expires.
     * Before the fix this fails on its own assertion - the balance that moves
     * is the disputed PROTOCOL's, not the claimant's.
     * ------------------------------------------------------------------- */
    function test_expired_dispute_refunds_the_FUNDER_not_the_disputed_protocol() public {
        uint256 id = _claimedOriginal();
        vm.warp(block.timestamp + 1 days + 1);          // clear the protocol decision window

        uint256 bounty = _disputeMin(ORIG_BOUNTY);
        vm.startPrank(claimant);
        token.approve(address(cell), bounty);
        uint256 disputeId = claimModule.claimantOpenDisputeReaudit(id, bounty);
        vm.stopPrank();

        // The funder is the claimant, and the cell recorded it.
        assertEq(cell.getAudit(disputeId).lastDiscoverer, claimant, "funder recorded as lastDiscoverer");
        assertEq(cell.getAudit(disputeId).protocol, protocol, "row protocol is the DISPUTED party");
        assertEq(cell.getAudit(disputeId).bounty, bounty, "bounty escrowed on the dispute row");

        uint256 claimantBefore = token.balanceOf(claimant);
        uint256 protocolBefore = token.balanceOf(protocol);

        // Let the dispute lapse unresolved, then expire it.
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        claimModule.expireDispute(id);

        // G3 (VD-207(2)): a claimant-funded dispute that expires unverdicted ALSO resolves the claim unadjudicated, so
        // the claimant's stake comes back beside the bounty. The bug_203 point this test pins is unchanged - none of it
        // reaches the disputed protocol.
        assertEq(
            token.balanceOf(claimant) - claimantBefore,
            bounty + cell.claimFilingStake(),
            "the funder must be made whole - the bounty they paid in, and (G3) the claim stake"
        );
        assertEq(
            token.balanceOf(protocol),
            protocolBefore,
            "the DISPUTED party must not receive the funder's bounty"
        );
    }

    /* ---------------------------------------------------------------------
     * GREEN companion: the protocol-opened lane funds from the protocol, so
     * there `lastDiscoverer` IS the protocol and the refund correctly returns
     * to it. This pins that the fix does not simply move the bug to the other
     * lane - `lastDiscoverer` is the funder in BOTH, which is why one word
     * fixes both.
     * ------------------------------------------------------------------- */
    function test_protocol_opened_dispute_still_refunds_the_protocol() public {
        uint256 id = _claimedOriginal();

        uint256 bounty = _disputeMin(ORIG_BOUNTY);
        vm.startPrank(protocol);
        token.approve(address(cell), bounty);
        uint256 disputeId = claimModule.openDisputeReaudit(id, bounty);
        vm.stopPrank();

        assertEq(cell.getAudit(disputeId).lastDiscoverer, protocol, "protocol funded, so it is the funder");

        uint256 protocolBefore = token.balanceOf(protocol);
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        claimModule.expireDispute(id);

        assertEq(
            token.balanceOf(protocol) - protocolBefore,
            bounty,
            "protocol funded and is refunded - unchanged by the fix"
        );
    }

    /* ---------------------------------------------------------------------
     * G3 (PC-88(b)+(e), ruled as ONE change by VD-207(2)): when a CLAIMANT-funded
     * dispute expires with no verdict, the claim resolves UNADJUDICATED - the
     * stake is refunded (VD-117: no adjudicated outcome, no adjudicated loser),
     * the row returns to its pre-claim state, and the claim cannot be disputed
     * again (one dispute per claim). The protocol cannot forfeit a prosecuted
     * claim; the claimant cannot stall by re-opening.
     * ------------------------------------------------------------------- */
    function _claimantDisputeExpired() internal returns (uint256 id) {
        id = _claimedOriginal();
        vm.warp(block.timestamp + 1 days + 1);
        uint256 bounty = _disputeMin(ORIG_BOUNTY);
        vm.startPrank(claimant);
        token.approve(address(cell), bounty);
        claimModule.claimantOpenDisputeReaudit(id, bounty);
        vm.stopPrank();
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
    }

    function test_G3_an_expired_claimant_funded_dispute_resolves_the_claim_unadjudicated() public {
        uint256 id = _claimantDisputeExpired();
        uint256 escrowBefore = escrow.escrowBalance();
        claimModule.expireDispute(id);

        (, , , , , bool resolved, , , , , , , ) = cell.vulnerabilityClaims(id);
        assertTrue(resolved, "the claim is resolved - unadjudicated");
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InBlock), "the row is back in its pre-claim state");
        assertEq(escrow.escrowBalance(), escrowBefore, "nobody was slashed: no verdict, no loser");

        uint256 bounty = _disputeMin(ORIG_BOUNTY);
        vm.startPrank(claimant);
        token.approve(address(cell), bounty);
        vm.expectRevert(); // one dispute per claim: the claim is resolved, so the lane is shut
        claimModule.claimantOpenDisputeReaudit(id, bounty);
        vm.stopPrank();
    }

    /// The F2 composability shape (PC-88's note): `expireDispute` then `expireClaim` in ONE transaction used to let the
    /// accused protocol forfeit a prosecuted claim and slash the claimant atomically.
    function test_G3_the_protocol_cannot_forfeit_a_prosecuted_claim_atomically() public {
        uint256 id = _claimantDisputeExpired();
        uint256 escrowBefore = escrow.escrowBalance();
        vm.startPrank(protocol);
        claimModule.expireDispute(id);
        vm.expectRevert(); // the claim already resolved unadjudicated - there is nothing left to slash
        cell.expireClaim(id);
        vm.stopPrank();
        assertEq(escrow.escrowBalance(), escrowBefore, "the claimant's stake was not slashed");
    }

    /// PC-115, FLIPPED in G4 (VD-216(3), Edge 1): this was the G3 CONTROL - a PROTOCOL-funded dispute that expired left the
    /// claim open, and `expireClaim` then slashed a claimant nobody had adjudicated. VD-207(2)'s last clause is withdrawn:
    /// ANY dispute that ends unverdicted resolves the claim unadjudicated, whoever funded it.
    function test_G4_an_expired_protocol_funded_dispute_resolves_the_claim_unadjudicated() public {
        uint256 id = _claimedOriginal();
        uint256 bounty = _disputeMin(ORIG_BOUNTY);
        vm.startPrank(protocol);
        token.approve(address(cell), bounty);
        claimModule.openDisputeReaudit(id, bounty);
        vm.stopPrank();
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        uint256 claimantBefore = token.balanceOf(claimant);
        uint256 escrowBefore = escrow.escrowBalance();
        claimModule.expireDispute(id);

        (, , , , , bool resolved, , , , , , , ) = cell.vulnerabilityClaims(id);
        assertTrue(resolved, "the claim is resolved - unadjudicated");
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InBlock), "the row is back in its pre-claim state");
        assertEq(token.balanceOf(claimant) - claimantBefore, cell.claimFilingStake(), "the claimant's stake comes back");
        vm.expectRevert(); // nothing left for the lapse to slash
        cell.expireClaim(id);
        assertEq(escrow.escrowBalance(), escrowBefore, "no verdict, no loser");
    }
}

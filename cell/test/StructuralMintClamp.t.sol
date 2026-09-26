// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/IssuanceModule.sol";
import "./helpers/CellTestDeploy.sol";

/*
 * VD-92 (bug_102) - the two STRUCTURAL mint levers had a per-event bound and no lifetime one.
 *
 * `mintUpgradeAdopt` (:685) and `mintToolCanonization` (:689) both called the raw `_mint` (:374,
 * `token.mint`, nothing else). Neither read nor wrote any cumulative, so both kept minting after PC-3's
 * lifetime cap had clamped positive blocks to zero. Each EVENT is gated and sized ~one positive-block
 * reward; the EVENT COUNT was unbounded and uncounted, and that was the entire defect.
 *
 * The file states the invariant itself three times over - `positiveBlockMintedCumulative` (:427-433),
 * `greenLightMintedCumulative` (:636-643), `founderCapRemaining` (:447): every mint lever carries a
 * lifetime clamp. These two were the exceptions, and the G-20 comment claimed they did not exist.
 *
 * These tests drive the clamp at IssuanceModule's own boundary rather than through the adoption and
 * canonization flows, because the clamp LIVES here - `onlyCell` / `onlyCellOrStructural` is the seam, and
 * a fixture that reached an adopted gap would be testing StructuralUpgradeModule's gates, not this budget.
 */
contract Seed {
    uint256 public immutable salt;
    constructor() { salt = 1; }
}

contract StructuralMintClampTest is Test {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    IssuanceModule issuance;

    address recipient = address(0xBEEF);
    address protocol  = address(0xA11CE);
    address auditorA  = address(0xB0B);

    bytes32 specToolId    = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash      = keccak256("spec.v1");
    bytes32 specErrors    = keccak256("errors.v1");
    bytes32 resultRoot    = keccak256("result.v1");

    /// @dev THE FIXTURE IS BUILT FIRST, and it has to be: `nextPositiveBlockReward()` is derived from
    ///      `emaSlow`, which is written only by the settle path (:616-618). On a virgin deployment the
    ///      reward is ZERO, so every clamp assertion would pass vacuously against a lever that mints
    ///      nothing. One confirmed audit seeds the EMA and gives the levers a real amount to clamp.
    ///      VD-92's own reopen names this case - an undriveable red is a hope, not a test.
    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        escrow = d.escrow;
        issuance = d.issuance;
        token.genesisMint(protocol, 10_000 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);

        vm.prank(auditorA);
        cell.register();

        Seed target = new Seed();
        vm.prank(protocol);
        token.approve(address(cell), 40 ether);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        uint256 id = cell.submitAudit(address(target), address(target).codehash, specHash, specToolId, specErrors, 40 ether, declared, 0, 0);
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditorA);
        cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);

        assertGt(issuance.nextPositiveBlockReward(), 0, "fixture: the EMA is seeded and the levers pay");
    }

    /* ---------------------------------------------------------------------
     * The budget exists at all, and is supply-scaled like its G-20 sibling.
     * ------------------------------------------------------------------- */
    function test_structural_headroom_is_supply_scaled_and_starts_full() public view {
        uint256 expected = (token.totalSupply() * issuance.structuralCumulativeCapBps()) / 10_000;
        assertEq(issuance.structuralMintHeadroom(), expected, "headroom = cap x supply, nothing spent yet");
        assertEq(issuance.structuralMintedCumulative(), 0, "counter starts at zero");
    }

    /* ---------------------------------------------------------------------
     * An under-budget mint STILL PAYS - VD-92's second acceptance direction.
     * A clamp that starves the legitimate path is not a fix.
     * ------------------------------------------------------------------- */
    function test_under_budget_canonization_still_pays_in_full() public {
        uint256 want = issuance.nextPositiveBlockReward();
        assertGt(want, 0, "the lever mints a real amount");
        assertGt(issuance.structuralMintHeadroom(), want, "and the budget comfortably covers it");

        uint256 before = token.balanceOf(recipient);
        vm.prank(address(cell));
        uint256 minted = issuance.mintToolCanonization(recipient);

        assertEq(minted, want, "paid in full, unclamped");
        assertEq(token.balanceOf(recipient) - before, want, "and the tokens actually moved");
        assertEq(issuance.structuralMintedCumulative(), minted, "the counter recorded it");
    }

    /* ---------------------------------------------------------------------
     * RED DIRECTION: a mint past the cap must NOT pay. With the budget spent,
     * the lever returns zero and mints nothing - it does not revert, and it
     * does not quietly pay anyway, which is what it did before VD-92.
     * ------------------------------------------------------------------- */
    function test_mint_past_the_cap_pays_nothing() public {
        // Spend the budget to exactly zero by setting the cap to 0 bps.
        issuance.setStructuralCumulativeCapBps(0);
        assertEq(issuance.structuralMintHeadroom(), 0, "budget deliberately exhausted");

        uint256 supplyBefore = token.totalSupply();
        uint256 before = token.balanceOf(recipient);

        vm.prank(address(cell));
        uint256 minted = issuance.mintToolCanonization(recipient);

        assertEq(minted, 0, "past the cap the lever mints ZERO - this is the bug_102 direction");
        assertEq(token.balanceOf(recipient), before, "no tokens moved");
        assertEq(token.totalSupply(), supplyBefore, "and nothing was minted into existence");
    }

    /* ---------------------------------------------------------------------
     * PARTIAL AT THE BOUNDARY, not all-or-nothing - the G-20 shape exactly.
     * ------------------------------------------------------------------- */
    function test_partial_mint_at_the_boundary() public {
        uint256 want = issuance.nextPositiveBlockReward();
        assertGt(want, 0, "the lever pays a real amount");

        // A sub-reward cap is not expressible in whole bps at this supply, so the boundary is reached by
        // SPENDING the budget down rather than by sizing it small: one full mint at a 1-bps cap leaves
        // less than one reward of headroom behind it.
        // A sub-reward cap is not expressible in whole bps at this supply (one reward is ~0.0117 AUDIT
        // against a 1-bps cap of ~1.0), so the boundary is reached by SPENDING the budget down. The loop
        // is bounded and asserts it actually converged - an unreached boundary must fail, not pass quietly.
        issuance.setStructuralCumulativeCapBps(1);
        assertGt(issuance.structuralMintHeadroom(), want, "budget starts above one reward");

        uint256 guard;
        while (issuance.structuralMintHeadroom() >= want && guard < 500) {
            vm.prank(address(cell));
            issuance.mintToolCanonization(recipient);
            guard++;
        }
        assertLt(guard, 500, "the loop converged rather than hitting its bound");

        uint256 headroom = issuance.structuralMintHeadroom();
        assertLt(headroom, want, "less than one reward remains");
        assertGt(headroom, 0, "but the budget is not yet spent");

        vm.prank(address(cell));
        uint256 minted = issuance.mintToolCanonization(recipient);
        assertEq(minted, headroom, "clamped to exactly the headroom - PARTIAL, not refused");

        // A SUPPLY-SCALED CAP NEVER REACHES EXACTLY ZERO WHILE MINTING, and that is a property of the
        // G-20 pattern rather than of this fix: `capTotal = supply x capBps`, so every mint raises the cap
        // by `amount x capBps` even as it spends `amount` of the budget. The residue therefore SHRINKS
        // geometrically toward zero instead of hitting it. Asserting `headroom == 0` here would be
        // asserting something the pattern cannot do - the honest invariant is that the residue is strictly
        // smaller than the mint that produced it, so the budget converges rather than reopening.
        uint256 residue = issuance.structuralMintHeadroom();
        assertLt(residue, minted, "the residue is smaller than the mint that produced it - converging");

        vm.prank(address(cell));
        uint256 tail = issuance.mintToolCanonization(recipient);
        assertEq(tail, residue, "the next mint takes only the residue, never a fresh full reward");
        assertLt(tail, want, "and it is far below one reward - the lever is bounded, as designed");
    }

    /* ---------------------------------------------------------------------
     * BOTH levers draw on the SAME budget - the shared-class reading of
     * VD-92, pinned so the choice is visible rather than implied.
     * ------------------------------------------------------------------- */
    function test_both_levers_share_one_budget() public {
        vm.prank(address(cell));
        uint256 a = issuance.mintToolCanonization(recipient);
        assertGt(a, 0, "canonization drew from the budget");
        uint256 afterFirst = issuance.structuralMintedCumulative();
        assertEq(afterFirst, a, "counter holds the canonization mint");

        vm.prank(address(cell));
        uint256 b = issuance.mintUpgradeAdopt(recipient);
        assertEq(
            issuance.structuralMintedCumulative(),
            afterFirst + b,
            "the adopt lever charged the SAME counter - one class, one lifetime budget"
        );
    }

    /* ---------------------------------------------------------------------
     * The cap is a parameter like its siblings: tunable, and LOCKABLE.
     * ------------------------------------------------------------------- */
    function test_structural_cap_is_lockable_like_its_siblings() public {
        issuance.setStructuralCumulativeCapBps(150);
        assertEq(issuance.structuralCumulativeCapBps(), 150, "tunable while unlocked");

        issuance.lockIssuanceParam(issuance.LOCK_STRUCTURAL_CAP());
        vm.expectRevert();
        issuance.setStructuralCumulativeCapBps(300);
        assertEq(issuance.structuralCumulativeCapBps(), 150, "locked value holds");
    }
}

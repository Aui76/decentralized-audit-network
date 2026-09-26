// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/StructuralUpgradeModule.sol";

// Oracle for Phase B1 (admin-door-residue-verdicts, VD-26 amendments) — StructuralUpgradeModule doors
// 12-15, including F2 (upgradeClaimCapBps had TWO write paths: :314 setUpgradeClaimCapBps and :331
// inside setStructuralUpgradeEscrowParams). Ported from IssuanceModule's issuanceParamLockMask shape
// (A1: capability now, armed later per parameter — ships UNARMED, mask = 0).
contract StructuralUpgradeParamLock is Test {
    StructuralUpgradeModule internal structural;

    function setUp() external {
        structural = new StructuralUpgradeModule(address(this));
    }

    // ---- t1 ships UNARMED, every guarded setter still works untouched ----
    function test_ships_unarmed_all_doors_mutable() external {
        assertEq(structural.structuralParamLockMask(), 0, "no param locked at deploy");
        assertFalse(structural.structuralParamLocked(structural.LOCK_GAP_FILING_STAKE()));

        structural.setGapFilingStake(200 ether);
        structural.setPassPayoutBps(5000);
        structural.setUpgradeClaimCapBps(600);
        structural.setStructuralUpgradeEscrowParams(400 ether, 8, 40, 4, 8);

        assertEq(structural.gapFilingStake(), 200 ether);
        assertEq(structural.passPayoutBps(), 5000);
        assertEq(structural.upgradeClaimCapBps(), 600);
        assertEq(structural.upgradeProposalBase(), 400 ether);
        assertEq(structural.upgradeMaturityMax(), 8);
        assertEq(structural.upgradeMaturityUnit(), 40);
        assertEq(structural.upgradeProposerMax(), 4);
        assertEq(structural.upgradeProposerUnit(), 8);
    }

    // ---- door 12 setGapFilingStake: lock only ----
    function test_door12_gap_filing_stake_lock() external {
        structural.lockStructuralParam(structural.LOCK_GAP_FILING_STAKE());
        assertTrue(structural.structuralParamLocked(structural.LOCK_GAP_FILING_STAKE()));
        vm.expectRevert(StructuralUpgradeModule.ParamLocked.selector);
        structural.setGapFilingStake(1 ether);
    }

    // ---- door 13 setPassPayoutBps: already bounded pre-existing (WrongState) — needs the lock, not the bound ----
    function test_door13_pass_payout_bound_preexisting() external {
        structural.setPassPayoutBps(10_000); // boundary: allowed
        vm.expectRevert(StructuralUpgradeModule.WrongState.selector);
        structural.setPassPayoutBps(10_001);
    }

    function test_door13_pass_payout_lock() external {
        structural.lockStructuralParam(structural.LOCK_PASS_PAYOUT());
        assertTrue(structural.structuralParamLocked(structural.LOCK_PASS_PAYOUT()));
        vm.expectRevert(StructuralUpgradeModule.ParamLocked.selector);
        structural.setPassPayoutBps(3000);
    }

    // ---- door 14 setUpgradeClaimCapBps: bound (new) ----
    function test_door14_claim_cap_bound() external {
        structural.setUpgradeClaimCapBps(10_000); // boundary: allowed
        vm.expectRevert(StructuralUpgradeModule.WrongState.selector);
        structural.setUpgradeClaimCapBps(10_001);
    }

    // ---- door 14 setUpgradeClaimCapBps: lock ----
    function test_door14_claim_cap_lock() external {
        structural.lockStructuralParam(structural.LOCK_CLAIM_CAP());
        assertTrue(structural.structuralParamLocked(structural.LOCK_CLAIM_CAP()));
        vm.expectRevert(StructuralUpgradeModule.ParamLocked.selector);
        structural.setUpgradeClaimCapBps(700);
    }

    // ---- door 15 setStructuralUpgradeEscrowParams: lock (now 5-param, claimCapBps arm deleted) ----
    function test_door15_escrow_params_lock() external {
        structural.lockStructuralParam(structural.LOCK_ESCROW_PARAMS());
        assertTrue(structural.structuralParamLocked(structural.LOCK_ESCROW_PARAMS()));
        vm.expectRevert(StructuralUpgradeModule.ParamLocked.selector);
        structural.setStructuralUpgradeEscrowParams(1 ether, 1, 1, 1, 1);
    }

    // ==== F2 — the two-writer bug on upgradeClaimCapBps ====
    //
    // Pre-fix, setStructuralUpgradeEscrowParams(uint256,uint256,uint256,uint256,uint256,uint256) wrote
    // upgradeClaimCapBps unconditionally at its 6th argument, bypassing any lock placed only on
    // setUpgradeClaimCapBps. What closes F2 is that the second writer is GONE: the old 6-arg selector
    // no longer resolves to any function, and this contract defines no fallback/receive, so the
    // low-level call below reverts. On the pre-fix contract the same call resolves, succeeds, and
    // writes 9999 — so BOTH assertions here go red against it.
    //
    // HONEST NOTE ON WHAT THIS TEST DOES AND DOES NOT PROVE (review, 2026-08-22):
    //   * The `lockStructuralParam` call below is BELT-AND-BRACES, not the mechanism under test.
    //     Remove it and this test still passes, because the selector is absent either way. The lock's
    //     own teeth are proven separately by test_door14_claim_cap_lock above; do not read this test
    //     as evidence for the lock.
    //   * RED CAPTURED (2026-08-22, second pass): the 6th `claimCapBps` arg and its write were
    //     temporarily restored on this function (matching the pre-fix bundle), and the two other
    //     5-arg call sites in this file were patched to 6-arg so the file still compiled. Re-run
    //     against that mutated contract: `[FAIL: the old 6-arg bundle must not resolve - the second
    //     writer is deleted] test_door14_15_F2_old_six_arg_writer_is_gone()`, `ok` was true and the
    //     call actually wrote through — and as unplanned collateral, test_ships_unarmed_all_doors_mutable
    //     ALSO failed (`999 != 600`) because the restored bundle silently overwrote a value just set
    //     through the proper door, live-reproducing F2 rather than merely asserting it. 8 of 9 tests in
    //     this suite went red on that mutation; only test_locks_independent_and_guards (which never
    //     exercises the removed guards) stayed green. Reverted immediately after capture; this file and
    //     StructuralUpgradeModule.sol are confirmed byte-identical to the pre-mutation committed version.
    //   * The red direction is therefore a MEASURED run, not a derivation.
    function test_door14_15_F2_old_six_arg_writer_is_gone() external {
        structural.lockStructuralParam(structural.LOCK_CLAIM_CAP());

        // Snapshot rather than assume. An earlier version of this test asserted the value was 0
        // afterwards and FAILED with `540 != 0`, because upgradeClaimCapBps is DECLARED `= 540`
        // (StructuralUpgradeModule.sol:98) and was never 0. The assertion that matters is
        // "the old writer changed nothing", which is UNCHANGED-from-before, not equal-to-a-guess.
        uint256 capBefore = structural.upgradeClaimCapBps();

        (bool ok,) = address(structural).call(
            abi.encodeWithSignature(
                "setStructuralUpgradeEscrowParams(uint256,uint256,uint256,uint256,uint256,uint256)",
                uint256(500 ether),
                uint256(10),
                uint256(50),
                uint256(5),
                uint256(10),
                uint256(9999) // the would-be claimCapBps arm
            )
        );
        assertFalse(ok, "the old 6-arg bundle must not resolve - the second writer is deleted");
        // and the variable is provably untouched by that call
        assertEq(structural.upgradeClaimCapBps(), capBefore, "old 6-arg writer must not have moved the cap");
    }

    // ---- locks are independent + bad id + admin-only guards ----
    function test_locks_independent_and_guards() external {
        structural.lockStructuralParam(structural.LOCK_GAP_FILING_STAKE());
        structural.setUpgradeClaimCapBps(300);
        structural.setPassPayoutBps(2000);
        assertEq(structural.upgradeClaimCapBps(), 300);
        assertEq(structural.passPayoutBps(), 2000);

        vm.expectRevert(StructuralUpgradeModule.BadParamId.selector);
        structural.lockStructuralParam(4);

        uint8 gapId = structural.LOCK_GAP_FILING_STAKE();
        vm.prank(address(0xDEAD));
        vm.expectRevert(StructuralUpgradeModule.NotAdmin.selector);
        structural.lockStructuralParam(gapId);
    }
}

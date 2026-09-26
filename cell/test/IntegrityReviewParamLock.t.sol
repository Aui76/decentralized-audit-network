// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/IntegrityReviewModule.sol";

// Oracle for Phase B1 (admin-door-residue-verdicts, VD-26 amendments) — IntegrityReviewModule doors 9-10.
// Ported from IssuanceModule's issuanceParamLockMask shape (A1: capability now, armed later per
// parameter — ships UNARMED, mask = 0).
//
// DOOR 11 (`LOCK_MATCH_BPS` / `setIntegrityMatchBps`) IS GONE, with the `integrityMatchBps` limb it guarded
// (section B-2, VD-89(4)): the parameter was declared with no initializer, so it was 0, no deploy script ever
// armed it, and it sized a treasury match by a free parameter the payee's collaborator chose (bug_103). The
// two tests that exercised it are removed rather than adjusted - there is no door left to lock or bound - and
// `test_locks_independent_and_guards` now pins that id 2 is REJECTED instead of silently arming a dead bit.
contract IntegrityReviewParamLock is Test {
    IntegrityReviewModule internal integrity;

    function setUp() external {
        integrity = new IntegrityReviewModule(address(this));
    }

    // ---- t1 ships UNARMED, every guarded setter still works untouched ----
    function test_ships_unarmed_all_doors_mutable() external {
        assertEq(integrity.integrityParamLockMask(), 0, "no param locked at deploy");
        assertFalse(integrity.integrityParamLocked(integrity.LOCK_FILING_STAKE()));

        integrity.setIntegrityFilingStake(200 ether);
        integrity.setIntegrityContestStake(600 ether);

        assertEq(integrity.integrityFilingStake(), 200 ether);
        assertEq(integrity.integrityContestStake(), 600 ether);
    }

    // ---- door 9 setIntegrityFilingStake: lock only ----
    function test_door9_filing_stake_lock() external {
        integrity.lockIntegrityParam(integrity.LOCK_FILING_STAKE());
        assertTrue(integrity.integrityParamLocked(integrity.LOCK_FILING_STAKE()));
        vm.expectRevert(IntegrityReviewModule.ParamLocked.selector);
        integrity.setIntegrityFilingStake(1 ether);
    }

    // ---- door 10 setIntegrityContestStake: lock only ----
    function test_door10_contest_stake_lock() external {
        integrity.lockIntegrityParam(integrity.LOCK_CONTEST_STAKE());
        assertTrue(integrity.integrityParamLocked(integrity.LOCK_CONTEST_STAKE()));
        vm.expectRevert(IntegrityReviewModule.ParamLocked.selector);
        integrity.setIntegrityContestStake(1 ether);
    }

    // ---- locks are independent + bad id + admin-only guards ----
    function test_locks_independent_and_guards() external {
        integrity.lockIntegrityParam(integrity.LOCK_FILING_STAKE());
        integrity.setIntegrityContestStake(750 ether);
        assertEq(integrity.integrityContestStake(), 750 ether);

        // id 2 was door 11. It is now out of range, so a stale caller fails loudly.
        vm.expectRevert(IntegrityReviewModule.BadParamId.selector);
        integrity.lockIntegrityParam(2);
        vm.expectRevert(IntegrityReviewModule.BadParamId.selector);
        integrity.lockIntegrityParam(3);

        uint8 filingId = integrity.LOCK_FILING_STAKE();
        vm.prank(address(0xDEAD));
        vm.expectRevert(IntegrityReviewModule.NotAdmin.selector);
        integrity.lockIntegrityParam(filingId);
    }
}

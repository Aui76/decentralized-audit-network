// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/SpecArbiterModule.sol";

// Oracle for Phase B1 (admin-door-residue-verdicts, VD-26 amendments) — SpecArbiterModule doors 4-8.
// Ported from IssuanceModule's issuanceParamLockMask shape (A1: capability now, armed later per
// parameter — ships UNARMED, mask = 0). Bounds per A2 ("bound everywhere" for the bps doors 6-8).
contract SpecArbiterParamLock is Test {
    SpecArbiterModule internal specArbiter;

    function setUp() external {
        specArbiter = new SpecArbiterModule(address(this));
    }

    // ---- t1 ships UNARMED, every guarded setter still works untouched ----
    function test_ships_unarmed_all_doors_mutable() external {
        assertEq(specArbiter.specArbiterParamLockMask(), 0, "no param locked at deploy");
        assertFalse(specArbiter.specArbiterParamLocked(specArbiter.LOCK_CHALLENGE_FEE()));

        specArbiter.setSpecChallengeFee(50 ether);
        specArbiter.setSpecChallengeStake(200 ether);
        specArbiter.setSpecChallengeRepeatSlashBps(6000);
        specArbiter.setSpecArbiterRewardBps(4000);
        specArbiter.setSpecChallengerInvalidationRewardBps(4000);

        assertEq(specArbiter.specChallengeFee(), 50 ether);
        assertEq(specArbiter.specChallengeStake(), 200 ether);
        assertEq(specArbiter.specChallengeRepeatSlashBps(), 6000);
        assertEq(specArbiter.specArbiterRewardBps(), 4000);
        assertEq(specArbiter.specChallengerInvalidationRewardBps(), 4000);
    }

    // ---- door 4 setSpecChallengeFee: lock only (no numeric bound applies) ----
    function test_door4_challenge_fee_lock() external {
        specArbiter.lockSpecArbiterParam(specArbiter.LOCK_CHALLENGE_FEE());
        assertTrue(specArbiter.specArbiterParamLocked(specArbiter.LOCK_CHALLENGE_FEE()));
        vm.expectRevert(SpecArbiterModule.ParamLocked.selector);
        specArbiter.setSpecChallengeFee(1 ether);
    }

    // ---- door 5 setSpecChallengeStake: lock only ----
    function test_door5_challenge_stake_lock() external {
        specArbiter.lockSpecArbiterParam(specArbiter.LOCK_CHALLENGE_STAKE());
        assertTrue(specArbiter.specArbiterParamLocked(specArbiter.LOCK_CHALLENGE_STAKE()));
        vm.expectRevert(SpecArbiterModule.ParamLocked.selector);
        specArbiter.setSpecChallengeStake(1 ether);
    }

    // ---- door 6 setSpecChallengeRepeatSlashBps: bound ----
    function test_door6_repeat_slash_bound() external {
        specArbiter.setSpecChallengeRepeatSlashBps(10_000); // boundary: allowed
        vm.expectRevert(SpecArbiterModule.InvalidBps.selector);
        specArbiter.setSpecChallengeRepeatSlashBps(10_001);
    }

    // ---- door 6 setSpecChallengeRepeatSlashBps: lock ----
    function test_door6_repeat_slash_lock() external {
        specArbiter.lockSpecArbiterParam(specArbiter.LOCK_REPEAT_SLASH());
        vm.expectRevert(SpecArbiterModule.ParamLocked.selector);
        specArbiter.setSpecChallengeRepeatSlashBps(3000);
    }

    // ---- door 7 setSpecArbiterRewardBps: bound ----
    function test_door7_arbiter_reward_bound() external {
        specArbiter.setSpecArbiterRewardBps(10_000); // boundary: allowed
        vm.expectRevert(SpecArbiterModule.InvalidBps.selector);
        specArbiter.setSpecArbiterRewardBps(10_001);
    }

    // ---- door 7 setSpecArbiterRewardBps: lock ----
    function test_door7_arbiter_reward_lock() external {
        specArbiter.lockSpecArbiterParam(specArbiter.LOCK_ARBITER_REWARD());
        vm.expectRevert(SpecArbiterModule.ParamLocked.selector);
        specArbiter.setSpecArbiterRewardBps(3000);
    }

    // ---- door 8 setSpecChallengerInvalidationRewardBps: bound ----
    function test_door8_challenger_invalidation_reward_bound() external {
        specArbiter.setSpecChallengerInvalidationRewardBps(10_000); // boundary: allowed
        vm.expectRevert(SpecArbiterModule.InvalidBps.selector);
        specArbiter.setSpecChallengerInvalidationRewardBps(10_001);
    }

    // ---- door 8 setSpecChallengerInvalidationRewardBps: lock ----
    function test_door8_challenger_invalidation_reward_lock() external {
        specArbiter.lockSpecArbiterParam(specArbiter.LOCK_CHALLENGER_INVALIDATION_REWARD());
        vm.expectRevert(SpecArbiterModule.ParamLocked.selector);
        specArbiter.setSpecChallengerInvalidationRewardBps(3000);
    }

    // ---- locks are independent + bad id + admin-only guards ----
    function test_locks_independent_and_guards() external {
        specArbiter.lockSpecArbiterParam(specArbiter.LOCK_CHALLENGE_FEE());
        // other doors unaffected
        specArbiter.setSpecChallengeStake(1000 ether);
        specArbiter.setSpecArbiterRewardBps(2500);
        assertEq(specArbiter.specChallengeStake(), 1000 ether);
        assertEq(specArbiter.specArbiterRewardBps(), 2500);

        // RE-PINNED 2026-09-10 (VD-156). This asserted that id 5 was out of range, which was true when the
        // table ended at door 8. VD-156's rider added doors 9, 10 and 11 - the two bare window setters and
        // the separated expiry charge - so 5 is now LOCK_CHALLENGE_WINDOW and lockable. The test failing
        // here is the boundary being pinned working exactly as intended: widening a lock table must cost a
        // red test, or ids silently become lockable with nothing recording it.
        //
        // Pinned in BOTH directions now, which the original only did in one: the three new doors must lock,
        // and the first id past the table must still be refused.
        specArbiter.lockSpecArbiterParam(specArbiter.LOCK_CHALLENGE_WINDOW());
        specArbiter.lockSpecArbiterParam(specArbiter.LOCK_ARBITER_DECISION_WINDOW());
        specArbiter.lockSpecArbiterParam(specArbiter.LOCK_EXPIRY_CHARGE());
        assertTrue(specArbiter.specArbiterParamLocked(specArbiter.LOCK_CHALLENGE_WINDOW()));
        assertTrue(specArbiter.specArbiterParamLocked(specArbiter.LOCK_ARBITER_DECISION_WINDOW()));
        assertTrue(specArbiter.specArbiterParamLocked(specArbiter.LOCK_EXPIRY_CHARGE()));

        // Read BEFORE the cheatcode is armed: a getter is an external call and would consume it.
        uint8 pastEnd = specArbiter.LOCK_EXPIRY_CHARGE() + 1;
        vm.expectRevert(SpecArbiterModule.BadParamId.selector);
        specArbiter.lockSpecArbiterParam(pastEnd);

        uint8 feeId = specArbiter.LOCK_CHALLENGE_FEE();
        vm.prank(address(0xDEAD));
        vm.expectRevert(SpecArbiterModule.NotAdmin.selector);
        specArbiter.lockSpecArbiterParam(feeId);
    }
}

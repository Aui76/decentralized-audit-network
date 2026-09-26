// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/SpecArbiterModule.sol";

/// @notice VD-156's riders on the 2026-09-10 hull window, red half first.
///
/// ITEM 1 (VD-109(1) → VD-115 → VD-156). `setSpecChallengeWindow` was a bare `onlyAdmin` write sitting
/// beside five siblings that all carry `_requireUnlocked` and a bound — and `setSpecArbiterDecisionWindow`
/// was bare in exactly the same way, which is the half nobody had booked. Both are windows read LIVE at
/// evaluation, so an admin write moves a deadline under a challenge already in flight. A zero window
/// expires a challenge in the block it is filed.
///
/// ITEM 2 (VD-117(4)). The unruled-expiry charge shared one parameter with the void fee, which has a
/// different payer: the void fee comes from the PROTOCOL's bounty, the expiry charge from the CHALLENGER's
/// stake. At the shipped defaults the clamp bit at parity and the honest challenger forfeited everything.
///
/// FLOORS, NOT CEILINGS — deliberately. VD-156 ruled a floor; a ceiling is a bound nobody ruled.
contract SpecArbiterWindowBoundsTest is Test {
    SpecArbiterModule internal m;

    function setUp() public {
        m = new SpecArbiterModule(address(this));
    }

    // ------------------------------------------------------------ item 1: floors

    function test_challenge_window_floor_refuses_zero() external {
        vm.expectRevert(SpecArbiterModule.WindowBelowFloor.selector);
        m.setSpecChallengeWindow(0);
    }

    function test_arbiter_decision_window_floor_refuses_zero() external {
        vm.expectRevert(SpecArbiterModule.WindowBelowFloor.selector);
        m.setSpecArbiterDecisionWindow(0);
    }

    /// The control. A floor that refused every value would be worse than the bare setter it replaces.
    function test_both_windows_accept_a_value_at_or_above_the_floor() external {
        m.setSpecChallengeWindow(1 minutes);
        m.setSpecArbiterDecisionWindow(1 minutes);
        assertEq(m.specChallengeWindow(), 1 minutes);
        assertEq(m.specArbiterDecisionWindow(), 1 minutes);
        m.setSpecChallengeWindow(30 days);
        assertEq(m.specChallengeWindow(), 30 days, "no ceiling was ruled, so none is imposed");
    }

    // ------------------------------------------------------------ item 1: locks

    function test_challenge_window_setter_locks() external {
        m.lockSpecArbiterParam(m.LOCK_CHALLENGE_WINDOW());
        vm.expectRevert(SpecArbiterModule.ParamLocked.selector);
        m.setSpecChallengeWindow(3 days);
    }

    function test_arbiter_decision_window_setter_locks() external {
        m.lockSpecArbiterParam(m.LOCK_ARBITER_DECISION_WINDOW());
        vm.expectRevert(SpecArbiterModule.ParamLocked.selector);
        m.setSpecArbiterDecisionWindow(3 days);
    }

    /// The lock-id table ended at door 8 and now ends at door 11; a value past the end must still be
    /// refused, or widening the table would have quietly made every out-of-range id lockable.
    function test_lockParam_still_refuses_an_id_past_the_table() external {
        // The id is READ BEFORE the cheatcode is armed, and that is not a style choice. `expectRevert`
        // applies to the next external call, and `m.LOCK_EXPIRY_CHARGE()` IS one - written inline it
        // consumed the expectation, the getter returned 7, and `lockSpecArbiterParam` was never called
        // at all. The assertion failed honestly here; written the other way round it would have passed
        // while testing nothing.
        uint8 pastEnd = m.LOCK_EXPIRY_CHARGE() + 1;
        vm.expectRevert(SpecArbiterModule.BadParamId.selector);
        m.lockSpecArbiterParam(pastEnd);
    }

    // ------------------------------------------------------------ item 2: the expiry charge

    function test_expiry_charge_default_reproduces_the_shipped_price() external {
        // 10 ether against a 100 ether stake was VD-117(1)'s corrected default. Separating the parameter
        // must not move the number, or this rider would be a repricing wearing a refactor's clothes.
        assertEq(m.specChallengeExpiryChargeBps(), 1000);
        assertEq(m.specChallengeStake(), 100 ether);
        assertEq(m.specChallengeStake() * m.specChallengeExpiryChargeBps() / 10_000, 10 ether);
    }

    /// THE INVARIANT VD-156 ASKED FOR, structural rather than asserted at deploy: charge < stake, because
    /// the setter cannot accept a value that would make them equal.
    function test_expiry_charge_cannot_reach_the_whole_stake() external {
        vm.expectRevert(SpecArbiterModule.InvalidBps.selector);
        m.setSpecChallengeExpiryChargeBps(10_000);
        m.setSpecChallengeExpiryChargeBps(9_999);
        assertLt(
            m.specChallengeStake() * m.specChallengeExpiryChargeBps() / 10_000,
            m.specChallengeStake(),
            "charge < stake holds at the extreme the setter does allow"
        );
    }

    function test_expiry_charge_setter_locks() external {
        m.lockSpecArbiterParam(m.LOCK_EXPIRY_CHARGE());
        vm.expectRevert(SpecArbiterModule.ParamLocked.selector);
        m.setSpecChallengeExpiryChargeBps(500);
    }

    /// The two prices are now INDEPENDENT, which is the whole point of the rider: moving the void fee
    /// leaves the expiry charge alone and vice versa. Under one parameter this assertion was unwritable.
    function test_void_fee_and_expiry_charge_move_independently() external {
        m.setSpecChallengeFee(1 ether);
        assertEq(m.specChallengeExpiryChargeBps(), 1000, "the expiry charge did not follow the void fee");
        m.setSpecChallengeExpiryChargeBps(2500);
        assertEq(m.specChallengeFee(), 1 ether, "the void fee did not follow the expiry charge");
    }
}

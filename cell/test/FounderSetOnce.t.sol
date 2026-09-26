// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";

import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";

/// @dev VD-25's set-once, admitted to the 2026-08-29 hull window by VD-52 as its ONE code item.
///
///      WHAT THE GUARD PROTECTS, and it is not abstract: `founder` is the address `claimFounder` pays.
///      A bare `onlyAdmin` setter meant the admin could repoint the payee at any moment, including after
///      the founder bucket had accrued. On this guarded cell the admin, the operator and the founder are
///      the same person - so the harm is zero today, and non-zero the instant value arrives. That is why
///      the re-trigger read MANDATORY BEFORE THE FIRST VALUE-BEARING DEPLOY instead of being parked.
///
///      THE RED-DIRECTION PAIR VD-52 ORDERED, and both halves are here for different reasons:
///        · the second set REVERTS                  - the guard does its job
///        · the guard DELETED goes red              - the test can fail, so its green means something
///      The second is the one that matters. `test_the_guard_is_what_makes_this_pass` re-runs the first
///      case's exact sequence against a stand-in carrying the ORIGINAL bare setter, and asserts the
///      repoint SUCCEEDS there. Without it, `expectRevert` on a function that happened to revert for any
///      other reason would read as proof. This repo has paid for that shape twice: a test that cannot
///      fail is the test-that-cannot-fail form, and VD-51's reopen names it by that name.
contract FounderSetOnce is Test {
    CellToken internal token;
    CellEscrow internal escrow;

    address internal founder = address(0xF0);
    address internal attacker = address(0xBAD);

    function setUp() public {
        token = new CellToken();
        escrow = new CellEscrow(address(token));
    }

    function test_founder_can_be_set_exactly_once() public {
        escrow.setFounder(founder);
        assertEq(escrow.founder(), founder, "the one permitted call must land");

        vm.expectRevert(CellEscrow.FounderAlreadySet.selector);
        escrow.setFounder(attacker);

        assertEq(escrow.founder(), founder, "and the payee must be unmoved after the refused call");
    }

    /// @dev The set-once must not swallow the zero check that was already there. Order matters: a zero
    ///      address is refused as a zero address, not as an already-set founder, so the message a caller
    ///      gets still names what they did wrong.
    function test_zero_founder_still_refused_by_its_own_check() public {
        vm.expectRevert(bytes("Zero founder"));
        escrow.setFounder(address(0));
        assertEq(escrow.founder(), address(0), "and nothing was written");
    }

    /// @dev Zero is the UNSET sentinel, so the guard must not fire before the first real set - otherwise
    ///      `DeployCell.s.sol`, which never calls setFounder, would leave a cell whose founder could never
    ///      be filled. Measured this session: that script calibrates founderReleaseTarget and nothing else.
    function test_guard_does_not_fire_on_the_first_set_after_a_refused_zero() public {
        vm.expectRevert(bytes("Zero founder"));
        escrow.setFounder(address(0));

        escrow.setFounder(founder);
        assertEq(escrow.founder(), founder, "a refused zero must not consume the one permitted set");
    }

    /// @dev Only the admin may perform the one set. The set-once narrows WHO-can-repoint to nobody; it
    ///      must not widen who can perform the FIRST set.
    function test_non_admin_cannot_perform_the_one_set() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("Not admin"));
        escrow.setFounder(attacker);
        assertEq(escrow.founder(), address(0), "nothing written by a non-admin");
    }

    /// @dev THE RED DIRECTION. Same sequence as the first test against the pre-VD-25 shape; the repoint
    ///      must SUCCEED here. If this ever starts reverting, the stand-in has drifted away from the
    ///      original and the pair above is no longer evidence of anything.
    function test_the_guard_is_what_makes_this_pass() public {
        BareSetterEscrow bare = new BareSetterEscrow();
        bare.setFounder(founder);
        assertEq(bare.founder(), founder, "control: the first set lands the same way");

        bare.setFounder(attacker);
        assertEq(
            bare.founder(),
            attacker,
            "control: WITHOUT the guard the payee is repointed - which is the defect VD-25 ruled out, and "
            "the reason the assertion above is evidence rather than decoration"
        );
    }
}

/// @dev The `setFounder` of `CellEscrow` as it stood before this change, byte for byte in behaviour:
///      admin-gated, zero-checked, and repointable. Deliberately a stand-in rather than a git revert -
///      the 2026-08-27 judgement was that a safety gate is never tested by switching the real one off.
contract BareSetterEscrow {
    address public founder;
    address public admin;

    constructor() {
        admin = msg.sender;
    }

    function setFounder(address f) external {
        require(msg.sender == admin, "Not admin");
        require(f != address(0), "Zero founder");
        founder = f;
    }
}

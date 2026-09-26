// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../script/SetIncrement.s.sol";
import "./helpers/CellTestDeploy.sol";

/// @notice PC-33 oracle — the registration hold is settable on a testnet instance, and stays MOVABLE.
///
/// WHY THIS TEST EXISTS. `increment` had exactly one call site outside the tests:
/// `DeployCell._applyMainnetProfile`, which does `setIncrement(1 ether)` and `lockIncrement()` in the SAME
/// transaction and is reachable only through the `TIME_PROFILE` branch that also picks the entropy provider
/// and the time windows. Testnet profile => 0 forever, no setter. Mainnet profile => 1e18, locked before
/// anything can measure it. **PC-30's §7 acceptance probe needs an instance where the hold is non-zero AND
/// still movable, and no producible instance could be one** — so its acceptance evidence was unbuildable,
/// and PC-21's trigger ("measure the newcomer path at the live 1e18") with it. Both rows read as "not done
/// yet"; the accurate reading was "not producible". `SetIncrement.s.sol` is the fix.
///
/// This file is also the COMPILE gate for that script — the first test here to import from `script/`,
/// deliberately: a deploy script nothing compiles is one you find out about while holding keys.
///
/// FOUR HARNESS FACTS, each MEASURED after this file failed on it (2026-08-15). They are written down
/// because every one is invisible until it bites, and each cost a run to find. Note what they have in
/// common: NONE of them was a fault in the code under test. `SetIncrement.s.sol` behaved correctly from
/// the first run — every failure was this test's model of the harness. That is the argument for running a
/// test rather than reasoning about one, made four times in a row.
///
///  1. `CellTestDeploy.deploy(a)` does NOT make `a` the cell's admin. `AuditCell`'s constructor takes
///     `L.admin = msg.sender` (AuditCell.sol:255); the parameter goes to the SATELLITES only, and
///     `AssignmentModule.wire` is `onlyAdmin` — so a foreign admin makes the fixture reject its own
///     wiring call with "Not admin". Deploy as `address(this)`, then hand the cell over.
///
///  2. Do NOT assume who `vm.startBroadcast(pk)` makes the caller. TWO guesses were wrong in a row: the
///     cell rejected `NotAdmin()` both when admin was `vm.addr(ADMIN_PK)` AND when it was the script
///     instance. The likeliest cause is that `vm.envUint("PRIVATE_KEY")` does not return what this file
///     wrote — `cell/.env` carries a real PRIVATE_KEY that forge loads into the process. So setUp now
///     DERIVES the admin: `vm.addr(vm.envUint("PRIVATE_KEY"))`, read back after setting it, whatever it
///     turns out to be. Deriving beats asserting when two assertions have already failed.
///     Key-based authorisation still is NOT exercised through the script here — see
///     `test_a_stranger_cannot_move_the_hold`, which tests the cell directly and says so.
///
///  3. `vm.expectRevert` binds to the NEXT call — and `vm.setEnv` is a call. Setting the env inside the
///     helper consumed the expectation, so three cases reported "next call did not revert as expected"
///     while the revert they wanted was happening one call later. Env goes BEFORE the expectation, always.
///
///  4. `INCREMENT_WEI` could not be steered from inside a test AT ALL, in either direction: one case armed
///     0 and the run set 1e18; the next armed nothing and the run read 0. Both logged their own numbers, so
///     this is measured, not inferred — but the CAUSE is still unknown and is deliberately not guessed at
///     here. RESOLUTION: the script was split. `run()` remains the env-reading wrapper the deploy script
///     calls; `runWith(uint256)` takes the amount as an argument and is what this file drives. A script
///     whose behaviour can only be reached through process environment cannot be pinned by a test — and
///     this one exists to be trusted by a probe, so it had to become reachable.
/// The script, pointed at THIS fixture's cell by override. Until 2026-09-18 setUp wrote AUDIT_CELL instead - a
/// process-wide variable EnvCellAgreement.t.sol also writes, so the two suites were green alone and wrong
/// together, on whichever order the runner happened to pick (VD-232(7), VD-145's class). Cured at the fixture.
contract SetIncrementAt is SetIncrement {
    address private immutable at;

    constructor(address cell_) {
        at = cell_;
    }

    function _cellAddress() internal view override returns (address) {
        return at;
    }
}

contract SetIncrementScriptTest is Test {
    CellTestDeploy.Deployment internal d;
    SetIncrement internal script_;
    address internal broadcaster;
    address internal stranger = address(0xDEAD);

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        script_ = new SetIncrementAt(address(d.cell));

        // Set the key FIRST, then DERIVE the admin from whatever `vm.envUint` actually returns, rather
        // than from what this file believes it set. Two guesses were already wrong here (see harness
        // fact 2), and `cell/.env` carries a real PRIVATE_KEY that forge loads into the process, so what
        // the script reads is not necessarily what this test wrote. Reading it back removes the guess:
        // whoever the script broadcasts as, that address owns the cell.
        vm.setEnv("PRIVATE_KEY", vm.toString(uint256(0xA11CE)));
        broadcaster = vm.addr(vm.envUint("PRIVATE_KEY"));

        d.cell.transferAdmin(broadcaster);
        assertEq(d.cell.admin(), broadcaster, "the cell must belong to the address the script broadcasts as");

    }

    /// Drive the script by ARGUMENT. `run()` (the env-reading wrapper the deploy script calls) is not
    /// used here at all — see harness facts 3 and 4: `INCREMENT_WEI` could not be steered mid-test in
    /// either direction, so any case built on it was testing the harness, not the script.
    function _run(uint256 weiValue) internal {
        script_.runWith(weiValue);
    }

    // ---- the thing PC-33 exists to make possible -----------------------------------------------

    function test_sets_the_hold_and_leaves_it_UNLOCKED() public {
        assertEq(d.cell.increment(), 0, "fixture should start at the testnet posture");
        assertFalse(d.cell.incrementLocked());

        _run(1 ether);

        assertEq(d.cell.increment(), 1 ether, "the hold was not set");
        assertFalse(d.cell.incrementLocked(), "the script must NEVER lock - a locked knob kills the probe");
    }

    function test_hold_can_be_moved_back_down() public {
        _run(1 ether);
        assertEq(d.cell.increment(), 1 ether);

        _run(0);
        assertEq(d.cell.increment(), 0, "the hold must be reversible or the probe can only run once");
        assertFalse(d.cell.incrementLocked());
    }

    function test_the_newcomer_hold_actually_scales_with_it() public {
        // The number PC-30 and PC-21 are really about: an UNREGISTERED newcomer needs
        // auditorCount x increment. Proving the script moves THAT, not just a storage slot.
        vm.prank(address(0x1111));
        d.cell.register();
        vm.prank(address(0x2222));
        d.cell.register();
        assertEq(d.cell.auditorCount(), 2, "two auditors registered while entry was free");

        _run(1 ether);

        // A third, penniless newcomer can no longer walk in — and it must fail for the RIGHT reason.
        // A bare `vm.expectRevert()` would pass on any revert, including one caused by the test itself
        // being wrong; that is the assertion-that-cannot-fail shape (M-3).
        vm.prank(address(0x3333));
        vm.expectRevert(AuditCell.InsufficientHold.selector);
        d.cell.register();
    }

    // ---- and the refusals, because a setter that cannot fail is not a setter --------------------

    function test_reverts_on_a_no_op_rather_than_sending_nothing() public {
        // A transaction that changes nothing still reads like success in a deploy log. The deploy
        // wrapper's step 5b reads the chain FIRST and skips, so this revert is never hit on a resume.
        //
        // HARNESS FACT 4, measured 2026-08-15: this test's first version called `_arm(0)` and expected the
        // refusal, and instead the run SUCCEEDED at 1e18 — its own log said `increment after
        // 1000000000000000000`. A `vm.setEnv` issued mid-test did not reach the `vm.envUint` inside the
        // call that followed it. So this version never changes the env between the two calls: it runs
        // once at 1 ether (which sets both the chain value AND the env), then calls `run()` AGAIN with
        // everything untouched. That is also the truer test — a genuine repeat is exactly the resume the
        // refusal exists for, rather than a synthetic zero.
        _run(1 ether);
        assertEq(d.cell.increment(), 1 ether, "precondition: the first run must have taken");

        vm.expectRevert(bytes("increment already at the requested value - nothing to do"));
        script_.runWith(1 ether);

        assertEq(d.cell.increment(), 1 ether, "the refused call must not have moved anything");
    }

    function test_reverts_when_the_instance_has_a_LOCKED_increment() public {
        vm.prank(broadcaster);
        d.cell.lockIncrement();

        vm.expectRevert(
            bytes("increment is LOCKED on this instance - it was deployed under the mainnet profile; redeploy with TIME_PROFILE=testnet")
        );
        script_.runWith(1 ether);
    }

    function test_a_stranger_cannot_move_the_hold() public {
        // Tested against the CELL, not through the script: `vm.startBroadcast` does not move msg.sender
        // in a test (harness fact 2), so this harness cannot exercise key-based authorisation at all.
        // Saying that plainly beats a green test that proves nothing. What IS pinned: the underlying
        // guard the script depends on is real.
        vm.prank(stranger);
        vm.expectRevert(AuditCell.NotAdmin.selector);
        d.cell.setIncrement(1 ether);
        assertEq(d.cell.increment(), 0, "a stranger must not be able to change the entry price");
    }
}

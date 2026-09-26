// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../script/rehearsal/RehearsalTimelock.sol";

/// @title The rehearsal rig's own red-direction proofs — VD-65 condition 3.
///
/// WHY THIS EXISTS BEFORE THE REHEARSAL DOES. An unproven rig injects misattributed failures into the
/// very rehearsal it serves. If step 8 fails during the rehearsal, you must be able to say it was THE
/// SEQUENCE and not the rig — and you can only say that if the rig's semantics were established
/// first. This repo has paid for the alternative: `misattributed-failures` is a filed class, and the
/// a5 probe once reported INSUFFICIENT_FUNDS about ETH when the revert was a token balance.
///
/// Every guard is driven RED, not asserted. A guard nobody has watched fail is a guard nobody has
/// tested — and this rig's whole job is to make a later failure attributable.
contract Target {
    uint256 public value;
    bool public shouldRevert;

    function setValue(uint256 v) external { value = v; }
    function setShouldRevert(bool b) external { shouldRevert = b; }
    function boom() external view { if (shouldRevert) revert("target refused"); }
}

contract RehearsalTimelockTest is Test {
    RehearsalTimelock tl;
    Target target;

    address proposer = address(0xBEEF);
    address stranger = address(0xF00D);
    uint256 constant DELAY = 2 days;

    function setUp() public {
        tl = new RehearsalTimelock(proposer, DELAY);
        target = new Target();
    }

    // ── THE DELAY IS REAL ──────────────────────────────────────────────────────────────────────────
    // The whole premise of a timelock is that the window exists. A rig whose delay can be skipped
    // would let a rehearsal "prove" a control that was never enforced.

    function test_execute_before_eta_reverts() public {
        bytes memory data = abi.encodeCall(Target.setValue, (42));
        vm.prank(proposer);
        bytes32 id = tl.queue(address(target), data);

        vm.expectRevert(
            abi.encodeWithSelector(
                RehearsalTimelock.TooEarly.selector, id, block.timestamp + DELAY, block.timestamp
            )
        );
        tl.execute(address(target), data);
        assertEq(target.value(), 0, "the target must be untouched when the window has not opened");
    }

    function test_execute_one_second_before_eta_still_reverts() public {
        // The boundary, because an off-by-one in a delay is a delay that does not exist on its last
        // second — and the last second is exactly when a watcher is racing.
        bytes memory data = abi.encodeCall(Target.setValue, (42));
        vm.prank(proposer);
        tl.queue(address(target), data);

        vm.warp(block.timestamp + DELAY - 1);
        vm.expectRevert();
        tl.execute(address(target), data);
        assertEq(target.value(), 0, "one second early is still early");
    }

    function test_execute_at_eta_succeeds() public {
        // The green direction, so the rig cannot become one that simply never executes.
        bytes memory data = abi.encodeCall(Target.setValue, (42));
        vm.prank(proposer);
        tl.queue(address(target), data);

        vm.warp(block.timestamp + DELAY);
        tl.execute(address(target), data);
        assertEq(target.value(), 42, "at the ETA the call must actually land on the target");
    }

    // ── THE CANCEL IS REAL — Guardian criterion 3's whole subject ──────────────────────────────────

    function test_cancel_prevents_execute() public {
        bytes memory data = abi.encodeCall(Target.setValue, (42));
        vm.prank(proposer);
        bytes32 id = tl.queue(address(target), data);

        vm.prank(proposer);
        tl.cancel(id);

        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(abi.encodeWithSelector(RehearsalTimelock.NotQueued.selector, id));
        tl.execute(address(target), data);
        assertEq(target.value(), 0, "a cancelled call must never land, even after its ETA passes");
    }

    function test_cancel_of_unqueued_reverts() public {
        bytes32 id = tl.idOf(address(target), abi.encodeCall(Target.setValue, (42)));
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(RehearsalTimelock.NotQueued.selector, id));
        tl.cancel(id);
    }

    // ── AUTHORISATION ─────────────────────────────────────────────────────────────────────────────

    function test_non_proposer_cannot_queue() public {
        bytes memory data = abi.encodeCall(Target.setValue, (42));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RehearsalTimelock.NotProposer.selector, stranger));
        tl.queue(address(target), data);
    }

    function test_non_proposer_cannot_cancel() public {
        bytes memory data = abi.encodeCall(Target.setValue, (42));
        vm.prank(proposer);
        bytes32 id = tl.queue(address(target), data);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RehearsalTimelock.NotProposer.selector, stranger));
        tl.cancel(id);

        // ...and the entry survives the failed attempt, or a rejected cancel would still have
        // cancelled — the shape where a guard refuses loudly and mutates anyway.
        assertGt(tl.etaOf(id), 0, "a refused cancel must leave the queue untouched");
    }

    // ── THE STATE CANNOT DISAGREE WITH ITSELF ─────────────────────────────────────────────────────

    function test_execute_twice_reverts() public {
        bytes memory data = abi.encodeCall(Target.setValue, (42));
        vm.prank(proposer);
        bytes32 id = tl.queue(address(target), data);
        vm.warp(block.timestamp + DELAY);
        tl.execute(address(target), data);

        vm.expectRevert(abi.encodeWithSelector(RehearsalTimelock.NotQueued.selector, id));
        tl.execute(address(target), data);
    }

    function test_queue_twice_reverts() public {
        bytes memory data = abi.encodeCall(Target.setValue, (42));
        vm.startPrank(proposer);
        bytes32 id = tl.queue(address(target), data);
        vm.expectRevert(abi.encodeWithSelector(RehearsalTimelock.AlreadyQueued.selector, id));
        tl.queue(address(target), data);
        vm.stopPrank();
    }

    function test_execute_unqueued_reverts() public {
        bytes memory data = abi.encodeCall(Target.setValue, (7));
        bytes32 id = tl.idOf(address(target), data);
        vm.expectRevert(abi.encodeWithSelector(RehearsalTimelock.NotQueued.selector, id));
        tl.execute(address(target), data);
    }

    // ── A FAILING TARGET MUST NOT LOOK LIKE A SUCCESSFUL EXECUTION ────────────────────────────────
    // This is the misattribution guard. During the rehearsal, a revert inside the cell must surface
    // as a revert, not be swallowed into an "executed" event that makes step 8 look done.

    function test_failing_target_reverts_and_does_not_emit_executed() public {
        target.setShouldRevert(true);
        bytes memory data = abi.encodeCall(Target.boom, ());
        vm.prank(proposer);
        bytes32 id = tl.queue(address(target), data);
        vm.warp(block.timestamp + DELAY);

        vm.expectRevert();
        tl.execute(address(target), data);

        // The whole transaction reverted, so the queue entry is intact and the operator can retry or
        // cancel deliberately. A rig that consumed the entry on a failed call would leave the
        // rehearsal unable to distinguish "not queued" from "already tried and failed".
        assertGt(tl.etaOf(id), 0, "a reverting target must not consume the queue entry");
    }

    // ── THE CONSTRUCTOR REFUSES AN INERT RIG ──────────────────────────────────────────────────────

    function test_zero_proposer_reverts() public {
        vm.expectRevert(RehearsalTimelock.ZeroProposer.selector);
        new RehearsalTimelock(address(0), DELAY);
    }

    // ── AND A ZERO DELAY IS ALLOWED, DELIBERATELY, BUT PROVEN ─────────────────────────────────────
    // The rehearsal may want to queue-and-execute in one sitting rather than wait two days. That is
    // legitimate for a rehearsal and would be indefensible in production, which is exactly why this
    // file says RIG in its header and the production path deploys OZ's.

    function test_zero_delay_executes_immediately() public {
        RehearsalTimelock fast = new RehearsalTimelock(proposer, 0);
        bytes memory data = abi.encodeCall(Target.setValue, (9));
        vm.prank(proposer);
        fast.queue(address(target), data);
        fast.execute(address(target), data);
        assertEq(target.value(), 9, "a zero-delay rig executes at once - a rehearsal convenience");
    }
}

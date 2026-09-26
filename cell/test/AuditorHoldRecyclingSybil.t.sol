// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "./helpers/CellTestDeploy.sol";

/// @notice PC-30 demonstrator — the auditor registration hold is a BALANCE CHECK, not a stake.
///
/// The flaw, surfaced by the operator during rung14's acceptance run and verified by call path:
/// `registerExt()` (`CellLogicLib.sol`:1213) enforces entry as
/// `balanceOf(msg.sender) >= (newPosition - 1) * increment` at :1220 — no `transferFrom`, no escrow,
/// no lock. The pot is only ever SHOWN, never surrendered, so one pot walks from address to address
/// and every one of them registers on it.
///
/// WHAT THESE TESTS ARE. They assert TODAY'S behaviour and are GREEN on today's code, deliberately.
/// The proposal's §7 acceptance probe is the mirror image — it asserts the FIX and must go RED until
/// the fix lands — and a deliberately-red test cannot ride a suite whose pre-deploy gate is
/// zero-failures. So this file proves the flaw is real and measures its size; flipping the assertions
/// is the §7 probe, and that flip belongs in the same change as the fix.
contract AuditorHoldRecyclingSybilTest is Test {
    CellTestDeploy.Deployment internal d;

    uint256 internal constant INCREMENT = 1 ether;
    uint256 internal constant K = 8; // sybils registered off one pot

    bytes32 internal specToolId = keccak256("spec.tool.v1");
    bytes32 internal verdictToolId = keccak256("verdict.tool.v1");

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        // PC-33's finding: no instance the deploy scripts can produce runs increment > 0, which is why
        // the §7 probe was called unbuildable. A TEST can arm the dial directly (same as
        // GiftFreeEntryCell.t.sol:29), so the flaw is measurable offline today.
        d.cell.setIncrement(INCREMENT);
    }

    function _sybil(uint256 i) internal pure returns (address) {
        return address(uint160(0x5B11000 + i));
    }

    /// @dev The whole flaw in one test: ONE pot registers K auditors by being passed down the line.
    function test_one_pot_registers_K_sybils_by_being_passed_down_the_line() public {
        // The pot only ever has to cover the LAST registrant's requirement: (K-1) * increment.
        uint256 pot = (K - 1) * INCREMENT;
        d.token.genesisMint(_sybil(0), pot);

        for (uint256 i = 0; i < K; i++) {
            address me = _sybil(i);
            assertEq(d.token.balanceOf(me), pot, "pot did not arrive intact");

            vm.prank(me);
            d.cell.register();

            // Hand the entire pot to the next address and walk away with nothing.
            if (i + 1 < K) {
                vm.prank(me);
                d.token.transfer(_sybil(i + 1), pot);
                assertEq(d.token.balanceOf(me), 0, "registrant kept capital - it should be gone");
            }
        }

        assertEq(d.cell.auditorCount(), K, "all K sybils registered");

        // K-1 of them now hold ZERO and are still registered auditors in the queue.
        for (uint256 i = 0; i + 1 < K; i++) {
            assertEq(d.token.balanceOf(_sybil(i)), 0, "registered auditor holding nothing");
        }
    }

    /// @dev Prices the flaw: what the position-scaled wall is SUPPOSED to cost versus what it did cost.
    function test_recycling_collapses_the_quadratic_wall_to_linear() public {
        uint256 pot = (K - 1) * INCREMENT;
        d.token.genesisMint(_sybil(0), pot);
        for (uint256 i = 0; i < K; i++) {
            vm.prank(_sybil(i));
            d.cell.register();
            if (i + 1 < K) {
                vm.prank(_sybil(i));
                d.token.transfer(_sybil(i + 1), pot);
            }
        }

        // Honest cost — every auditor holds its own position hold simultaneously: sum(0..K-1).
        uint256 honestCost = (K * (K - 1) / 2) * INCREMENT;
        uint256 actualCost = pot; // = (K-1) * INCREMENT

        assertEq(d.cell.auditorCount(), K);
        assertEq(honestCost, 28 ether, "quadratic wall for K=8");
        assertEq(actualCost, 7 ether, "linear cost actually paid");
        assertLt(actualCost, honestCost, "the wall did not hold");
        // The discount grows with K: it is honestCost/actualCost = K/2.
        assertEq(honestCost / actualCost, K / 2, "discount is K/2 and unbounded in K");
    }

    /// @dev The liveness harm PC-30 names, and the one Option C targets: a sybil that has already
    ///      passed its pot on is still a registered, drawable auditor that its OWN continuous
    ///      requirement says is under water.
    ///
    ///      NOTE, because the first draft of this test was wrong and the harness caught it: position 1
    ///      requires ZERO by design (`_requiredHold` returns `(position-1)*increment`; the N=1
    ///      self-bootstrap is intentional). A passer-on at position 1 is therefore NOT under water and
    ///      proves nothing. The demonstration needs a position >= 2, so a filler takes position 1.
    function test_passed_on_sybil_stays_registered_while_ineligible_by_hold() public {
        address filler = _sybil(99); // takes position 1, requires 0
        address a = _sybil(100);     // position 2, requires 1 * increment
        address b = _sybil(101);     // position 3, requires 2 * increment

        vm.prank(filler);
        d.cell.register();

        uint256 pot = 2 * INCREMENT; // enough for the LAST registrant, which is all that is needed
        d.token.genesisMint(a, pot);

        vm.prank(a);
        d.cell.register();
        assertTrue(d.cell.isEligible(a), "a is eligible while it holds the pot");

        vm.prank(a);
        d.token.transfer(b, pot);

        vm.prank(b);
        d.cell.register(); // requires 2 * increment - satisfied by the SAME pot a just handed over

        assertEq(d.cell.auditorCount(), 3);
        assertEq(d.token.balanceOf(a), 0);

        // THE GAP. `isEligible` reads the CONTINUOUS requirement (`_requiredHold`,
        // `CellLogicLib.sol`:1173) and already knows a is under water. The view exists and is correct.
        // Nothing on the registration or draw path consults it - which is exactly what Option C
        // closes by checking the hold at ASSIGNMENT rather than only at entry.
        assertTrue(d.cell.isEligible(b), "b holds the pot, so b is eligible");
        assertFalse(d.cell.isEligible(a), "a passed the pot on and is NOT eligible - yet still registered");
    }

    // ---------------------------------------------------------------- the draw, measured not read
    //
    // Option C in the proposal is "require the hold at ASSIGNMENT, not only at accept", on the stated
    // ground that a sybil which passed its pot on would otherwise be drawn and burn a decision window.
    // Reading the code says both draw branches ALREADY do this - `AssignmentModule._isCandidateEligible`
    // mirrors requiredHold at :138-140, and CellLogicLib's fallback scan calls `isEligible`. Reading is
    // exactly what this session keeps catching, so the claim is measured here instead.

    address internal protocolAddr = address(0xBEEF);

    function _armDrawFixture() internal returns (address honest, address sybA, address sybB) {
        d.token.genesisMint(protocolAddr, 200_000 ether);
        // minter is already attached by CellTestDeploy.deploy - re-attaching reverts "Minter already set"

        honest = _sybil(200);
        sybA = _sybil(201);
        sybB = _sybil(202);
        address sink = _sybil(203); // holds the pot at the end and never registers

        vm.prank(honest);
        d.cell.register(); // position 1, requires 0 - stays eligible throughout

        uint256 pot = 2 * INCREMENT;
        d.token.genesisMint(sybA, pot);

        vm.prank(sybA);
        d.cell.register(); // position 2, requires 1 * increment
        vm.prank(sybA);
        d.token.transfer(sybB, pot);

        vm.prank(sybB);
        d.cell.register(); // position 3, requires 2 * increment - on the SAME pot
        vm.prank(sybB);
        d.token.transfer(sink, pot);

        // Both sybils are now registered, in the queue, and under water by their own requirement.
        assertEq(d.cell.auditorCount(), 3, "three registered off one pot plus a free first slot");
        assertFalse(d.cell.isEligible(sybA), "sybA under water");
        assertFalse(d.cell.isEligible(sybB), "sybB under water");
        assertTrue(d.cell.isEligible(honest), "honest still eligible");
    }

    function _submitOrdinary() internal returns (uint256 auditId) {
        AssignTargetPC30 target = new AssignTargetPC30();
        vm.startPrank(protocolAddr);
        d.token.approve(address(d.cell), 20_000 ether);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        auditId = d.cell.submitAudit(
            address(target), address(target).codehash, keccak256("spec"), specToolId,
            keccak256("errors.v1"), 20_000 ether, declared, 0, 0
        );
        vm.stopPrank();
    }

    /// @dev THE MEASUREMENT. If the draw already refuses an under-water auditor, Option C's stated
    ///      benefit is already in the bytecode and the liveness harm needs no hull change.
    function test_draw_never_assigns_a_sybil_that_passed_its_pot_on() public {
        (address honest, address sybA, address sybB) = _armDrawFixture();

        uint256 auditId = _submitOrdinary();
        address chosen = d.cell.auditAuditorOf(auditId);

        assertTrue(chosen != address(0), "an auditor was assigned at all");
        assertTrue(chosen != sybA, "under-water sybil A was drawn - Option C would be needed");
        assertTrue(chosen != sybB, "under-water sybil B was drawn - Option C would be needed");
        assertEq(chosen, honest, "the only eligible auditor is the one drawn");
    }
}

contract AssignTargetPC30 {
    uint256 public constant salt = 30;
}

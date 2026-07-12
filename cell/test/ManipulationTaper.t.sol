// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/IssuanceModule.sol";

// Oracle for G-23 (M-5, 2026-07-08, DEC-22 docket, option 2: taper + falling extension to a floor).
// Proposal: body/proposals/fix-manipulation-taper-proposal.txt.
//
// The flaw: the manipulation damper was a STEP — undamped (x1.0) at ratio 1.2999, x0.8 at 1.3001. An
// attacker paces activity to sit just under the cliff and never gets damped. Fix: a continuous taper,
// full at parity, linear to manipulationMintScaleBps at the threshold, same slope past it, floored.
//
// Honest cost (disclosed): growth-phase honest mint in (parity, threshold] is now gently damped too, and
// the far field falls below the old flat x0.8 down to the floor — strictly <= the old cliff everywhere
// above parity, never MORE permissive. Sim anchors are re-baselined by the owner (precedent: the A-1 fix).
contract ManipulationTaper is Test {
    using stdStorage for StdStorage;

    CellToken internal token;
    CellEscrow internal escrow;
    IssuanceModule internal issuance;

    function setUp() external {
        token = new CellToken();
        escrow = new CellEscrow(address(token));
        issuance = new IssuanceModule(address(this));
        issuance.wire(address(0xBEEF), address(token), address(escrow));
        escrow.setIssuanceModule(address(issuance));
        // defaults: threshold 13000, scale 8000, floor 5000
    }

    // ---- t1 continuity + endpoints (no cliff) ----
    function test_taper_is_continuous_no_cliff() external view {
        assertEq(issuance.manipulationScaleBps(10_000), 10_000, "full weight at parity");
        assertEq(issuance.manipulationScaleBps(9_000), 10_000, "full weight below parity");
        assertEq(issuance.manipulationScaleBps(13_000), 8_000, "== old cliff scale AT threshold");

        // Straddle the OLD cliff: the step from just-below to just-above is now ~nothing (was 2000 bps).
        uint256 justBelow = issuance.manipulationScaleBps(12_999);
        uint256 justAbove = issuance.manipulationScaleBps(13_001);
        assertGe(justBelow, justAbove, "monotone non-increasing across the old cliff");
        assertLt(justBelow - justAbove, 5, "the 20% cliff dodge is dead (sub-5-bps step)");
        assertLt(justBelow, 10_000, "just below threshold is ALREADY damped (the dodge is gone)");
    }

    // ---- t2 strictly <= the old cliff everywhere above parity (never more permissive) ----
    function test_never_more_permissive_than_old_cliff() external view {
        for (uint256 r = 10_001; r <= 20_000; r += 250) {
            uint256 oldCliff = r > 13_000 ? 8_000 : 10_000; // old behavior at default params
            assertLe(issuance.manipulationScaleBps(r), oldCliff, "taper never exceeds the old cliff");
        }
    }

    // ---- t3 falling extension + floor (option 2) ----
    function test_falls_past_threshold_and_floors() external view {
        // Slope: (10000-8000)/(13000-10000) = 2000/3000 per 10000 ratio. At 17500: drop = 2000*7500/3000 = 5000
        // -> scale 5000 == floor. Beyond stays floored.
        assertEq(issuance.manipulationScaleBps(15_000), 6_667, "keeps falling past the threshold");
        assertEq(issuance.manipulationScaleBps(17_500), 5_000, "reaches the floor");
        assertEq(issuance.manipulationScaleBps(20_000), 5_000, "clamped at the floor beyond");
        assertGt(8_000, issuance.manipulationScaleBps(15_000), "strictly below the old flat x0.8 in the far field");
    }

    // ---- t4 floor knob guarded + honored ----
    function test_floor_setter_guarded_and_applied() external {
        vm.expectRevert(bytes("Floor above scale"));
        issuance.setManipulationMintFloorBps(9_000); // > manipulationMintScaleBps (8000)

        issuance.setManipulationMintFloorBps(7_000);
        assertEq(issuance.manipulationScaleBps(20_000), 7_000, "raised floor honored in the far field");
    }

    // ---- t5 threshold must sit above parity (taper slope well-defined) ----
    function test_setter_rejects_subparity_threshold() external {
        vm.expectRevert(bytes("Invalid manipulation bps"));
        issuance.setAdaptiveIssuanceParams(9_000, 8_000, 2_500, 5, 25, true, 5_000);

        vm.expectRevert(bytes("Invalid manipulation bps"));
        issuance.setAdaptiveIssuanceParams(10_000, 8_000, 2_500, 5, 25, true, 5_000);

        // valid above-parity threshold accepted
        issuance.setAdaptiveIssuanceParams(15_000, 8_000, 2_500, 5, 25, true, 5_000);
        assertEq(issuance.manipulationThresholdBps(), 15_000);
    }
}

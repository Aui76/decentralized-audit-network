// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/IssuanceModule.sol";

// Oracle for G-27 §B — IssuanceModule anti-Sybil param-lock (2026-07-08, DEC-22 docket, operator option 1).
// Proposal: body/proposals/fix-issuance-param-lock-proposal.txt.
//
// CAPABILITY test: the one-way per-param lock exists in bytecode and, once armed, freezes the hardening
// knobs permanently. It ships UNARMED at this deployment by design (calibration testnet) — t1 asserts the
// unarmed default so a regression that silently arms it is caught. Arming is a per-deploy operational call.
contract IssuanceParamLock is Test {
    IssuanceModule internal issuance;
    CellToken internal token;
    CellEscrow internal escrow;

    function setUp() external {
        token = new CellToken();
        escrow = new CellEscrow(address(token));
        issuance = new IssuanceModule(address(this));
        issuance.wire(address(0xBEEF), address(token), address(escrow));
        escrow.setIssuanceModule(address(issuance));
    }

    // ---- t1 ships UNARMED (the calibration-testnet default) ----
    function test_ships_unarmed_all_knobs_mutable() external {
        assertEq(issuance.issuanceParamLockMask(), 0, "no param locked at deploy");
        assertFalse(issuance.issuanceParamLocked(issuance.LOCK_CREDIBILITY()));
        // every guarded knob is freely settable while unarmed (calibration)
        issuance.setCredibilityCountThreshold(4);
        issuance.setA1MintGate(3000, 3000);
        issuance.setGreenLightCumulativeCapBps(300);
        issuance.setManipulationMintFloorBps(4000);
        issuance.setMintLpCapBps(600);
        issuance.setAdaptiveIssuanceParams(14000, 7000, 3000, 5, 25, true, 5000);
        assertEq(issuance.credibilityCountThreshold(), 4);
        assertEq(issuance.mintLpCapBps(), 600);
    }

    // ---- t2 arming freezes exactly that knob, one-way ----
    function test_lock_freezes_credibility_threshold_one_way() external {
        issuance.setCredibilityCountThreshold(3);
        issuance.lockIssuanceParam(issuance.LOCK_CREDIBILITY());
        assertTrue(issuance.issuanceParamLocked(issuance.LOCK_CREDIBILITY()));

        vm.expectRevert(bytes("Issuance param locked"));
        issuance.setCredibilityCountThreshold(2);

        // idempotent re-lock, still no way back
        issuance.lockIssuanceParam(issuance.LOCK_CREDIBILITY());
        vm.expectRevert(bytes("Issuance param locked"));
        issuance.setCredibilityCountThreshold(1);
    }

    // ---- t3 locks are independent (one armed, others still free) ----
    function test_locks_are_per_param_independent() external {
        issuance.lockIssuanceParam(issuance.LOCK_A1_GATE());
        vm.expectRevert(bytes("Issuance param locked"));
        issuance.setA1MintGate(2000, 2000);

        // other knobs unaffected
        issuance.setGreenLightCumulativeCapBps(250);
        issuance.setCredibilityCountThreshold(5);
        assertEq(issuance.greenLightCumulativeCapBps(), 250);
        assertEq(issuance.credibilityCountThreshold(), 5);
    }

    // ---- t4 the taper lock covers BOTH taper setters ----
    function test_manip_lock_covers_both_taper_setters() external {
        issuance.lockIssuanceParam(issuance.LOCK_MANIP_TAPER());
        vm.expectRevert(bytes("Issuance param locked"));
        issuance.setManipulationMintFloorBps(4000);
        vm.expectRevert(bytes("Issuance param locked"));
        issuance.setAdaptiveIssuanceParams(14000, 7000, 3000, 5, 25, true, 5000);
    }

    // ---- t5 lp-cap lock (G-22 governor) + bad id guard + admin-only ----
    function test_lp_cap_lock_and_guards() external {
        issuance.lockIssuanceParam(issuance.LOCK_LP_CAP());
        vm.expectRevert(bytes("Issuance param locked"));
        issuance.setMintLpCapBps(700);

        vm.expectRevert(bytes("Bad param id"));
        issuance.lockIssuanceParam(9);

        uint8 credId = issuance.LOCK_CREDIBILITY(); // hoisted: a getter in arg position consumes expectRevert/prank
        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("Not admin"));
        issuance.lockIssuanceParam(credId);
    }
}

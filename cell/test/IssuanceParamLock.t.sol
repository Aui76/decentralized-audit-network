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

        // DERIVED, not a literal (2026-09-05). This probe hardcoded `9`, and VD-92 made 9 a REAL lock id
        // (LOCK_STRUCTURAL_CAP) - so the "first invalid id" became a valid one and the probe stopped
        // probing anything. Deriving it from the highest id means the next lock added cannot silently
        // hollow this assertion out the same way. Hoisted per this file's own note: a getter in argument
        // position consumes the expectRevert.
        uint8 beyondMax = issuance.LOCK_STRUCTURAL_CAP() + 1;
        vm.expectRevert(bytes("Bad param id"));
        issuance.lockIssuanceParam(beyondMax);

        uint8 credId = issuance.LOCK_CREDIBILITY(); // hoisted: a getter in arg position consumes expectRevert/prank
        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("Not admin"));
        issuance.lockIssuanceParam(credId);
    }

    // ==== Phase B1 (admin-door-residue-verdicts, VD-26) — doors 1-3 lock + bound ====

    // ---- t6 unarmed default extends to doors 1-3: mask 0, every setter still works ----
    function test_doors_1_3_ship_unarmed_and_settable() external {
        assertEq(issuance.issuanceParamLockMask(), 0, "no param locked at deploy");
        assertFalse(issuance.issuanceParamLocked(issuance.LOCK_TREASURY_SHARE()));
        assertFalse(issuance.issuanceParamLocked(issuance.LOCK_EMA_TO_MINT()));
        assertFalse(issuance.issuanceParamLocked(issuance.LOCK_UPGRADE_ADOPT_MINT()));

        issuance.setTreasuryShareBps(9000);
        issuance.setEmaToMintBps(3000);
        issuance.setUpgradeAdoptMintBps(8000);

        assertEq(issuance.treasuryShareBps(), 9000);
        assertEq(issuance.emaToMintBps(), 3000);
        assertEq(issuance.upgradeAdoptMintBps(), 8000);
    }

    // ---- t7 door 1 setTreasuryShareBps: bound (F1 — the sharpest door, HIGHEST PRIORITY) ----
    function test_door1_treasury_share_bound() external {
        issuance.setTreasuryShareBps(10_000); // boundary: allowed
        vm.expectRevert(bytes("Invalid treasuryShareBps"));
        issuance.setTreasuryShareBps(10_001);
    }

    // ---- t8 door 1 setTreasuryShareBps: lock ----
    function test_door1_treasury_share_lock() external {
        issuance.lockIssuanceParam(issuance.LOCK_TREASURY_SHARE());
        assertTrue(issuance.issuanceParamLocked(issuance.LOCK_TREASURY_SHARE()));
        vm.expectRevert(bytes("Issuance param locked"));
        issuance.setTreasuryShareBps(5000);
    }

    // ---- t9 door 2 setEmaToMintBps: bound (A2 overruled "bound optional" — bound like the rest) ----
    function test_door2_ema_to_mint_bound() external {
        issuance.setEmaToMintBps(10_000); // boundary: allowed
        vm.expectRevert(bytes("Invalid emaToMintBps"));
        issuance.setEmaToMintBps(10_001);
    }

    // ---- t10 door 2 setEmaToMintBps: lock ----
    function test_door2_ema_to_mint_lock() external {
        issuance.lockIssuanceParam(issuance.LOCK_EMA_TO_MINT());
        assertTrue(issuance.issuanceParamLocked(issuance.LOCK_EMA_TO_MINT()));
        vm.expectRevert(bytes("Issuance param locked"));
        issuance.setEmaToMintBps(1000);
    }

    // ---- t11 door 3 setUpgradeAdoptMintBps: bound (G-19's uncovered sibling) ----
    function test_door3_upgrade_adopt_mint_bound() external {
        issuance.setUpgradeAdoptMintBps(10_000); // boundary: allowed
        vm.expectRevert(bytes("Invalid upgradeAdoptMintBps"));
        issuance.setUpgradeAdoptMintBps(10_001);
    }

    // ---- t12 door 3 setUpgradeAdoptMintBps: lock ----
    function test_door3_upgrade_adopt_mint_lock() external {
        issuance.lockIssuanceParam(issuance.LOCK_UPGRADE_ADOPT_MINT());
        assertTrue(issuance.issuanceParamLocked(issuance.LOCK_UPGRADE_ADOPT_MINT()));
        vm.expectRevert(bytes("Issuance param locked"));
        issuance.setUpgradeAdoptMintBps(500);
    }

    // ---- t13 doors 1-3 fold into the existing bad-id / independence guards ----
    function test_doors_1_3_bad_id_still_rejected() external {
        // DERIVED, not a literal (2026-09-05). This probe hardcoded `9`, and VD-92 made 9 a REAL lock id
        // (LOCK_STRUCTURAL_CAP) - so the "first invalid id" became a valid one and the probe stopped
        // probing anything. Deriving it from the highest id means the next lock added cannot silently
        // hollow this assertion out the same way. Hoisted per this file's own note: a getter in argument
        // position consumes the expectRevert.
        uint8 beyondMax = issuance.LOCK_STRUCTURAL_CAP() + 1;
        vm.expectRevert(bytes("Bad param id"));
        issuance.lockIssuanceParam(beyondMax);
    }
}

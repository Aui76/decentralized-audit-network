// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/IssuanceModule.sol";
import "../contracts/StructuralUpgradeModule.sol";

/// @notice bug_003 (DEC-44 paid review, ruled by VD-143(2)) — `lockWiring()` asserts a SUBSET of what it
///         freezes, in both modules, so a wiring slot left at `address(0)` is frozen there permanently.
///
/// `lockWiring` is G-h: one-shot, one-way, and armed on a cell nobody can redeploy. The dangerous field is
/// `structuralModule`: `IssuanceModule.mintUpgradeAdopt` (:719) carries `onlyCellOrStructural` and
/// `StructuralUpgradeModule` (:676) calls it, so a `structuralModule` frozen empty BRICKS EVERY STRUCTURAL
/// ADOPTION at its mint — a dead lane for the life of the cell, discovered at first use rather than at the
/// lock. `treasuryEscrow` and `issuanceModule` are the same shape one step less fatal.
///
/// RED HALF FIRST: every `_reverts` case below passes `lockWiring()` on the unfixed contracts, because the
/// precondition it needs is the one nobody wrote. The `_succeeds` cases are the control — a guard that
/// refuses a correct deployment would be worse than the gap.
contract LockWiringPreconditionTest is Test {
    address constant CELL = address(0xCE11);
    address constant TOKEN = address(0x70CE);
    address constant ESCROW = address(0xE5C0);
    address constant STRUCTURAL = address(0x57BC);
    address constant ISSUANCE = address(0x1550);

    // ---------------------------------------------------------------- IssuanceModule

    function test_issuance_lockWiring_reverts_when_treasuryEscrow_unset() external {
        IssuanceModule m = new IssuanceModule(address(this));
        m.wire(CELL, TOKEN, address(0));
        m.setStructuralModule(STRUCTURAL);
        vm.expectRevert(bytes("Unset"));
        m.lockWiring();
    }

    /// The one that bricks a lane rather than a payout. `wire()` cannot set it — `setStructuralModule` is a
    /// SEPARATE call, which is exactly how a deploy sequence loses it and why the lock must ask.
    function test_issuance_lockWiring_reverts_when_structuralModule_unset() external {
        IssuanceModule m = new IssuanceModule(address(this));
        m.wire(CELL, TOKEN, ESCROW);
        vm.expectRevert(bytes("Unset"));
        m.lockWiring();
    }

    function test_issuance_lockWiring_reverts_when_cell_unset() external {
        IssuanceModule m = new IssuanceModule(address(this));
        m.wire(address(0), TOKEN, ESCROW);
        m.setStructuralModule(STRUCTURAL);
        vm.expectRevert(bytes("Unset"));
        m.lockWiring();
    }

    function test_issuance_lockWiring_reverts_when_token_unset() external {
        IssuanceModule m = new IssuanceModule(address(this));
        m.wire(CELL, address(0), ESCROW);
        m.setStructuralModule(STRUCTURAL);
        vm.expectRevert(bytes("Unset"));
        m.lockWiring();
    }

    /// CONTROL: all four set, the lock takes. Without this the tests above are satisfied by a `lockWiring`
    /// that reverts unconditionally, which is not a fix.
    function test_issuance_lockWiring_succeeds_when_all_set() external {
        IssuanceModule m = new IssuanceModule(address(this));
        m.wire(CELL, TOKEN, ESCROW);
        m.setStructuralModule(STRUCTURAL);
        m.lockWiring();
        assertTrue(m.wiringLocked());
        assertEq(m.treasuryEscrow(), ESCROW);
        assertEq(m.structuralModule(), STRUCTURAL);
    }

    // ---------------------------------------------------------------- StructuralUpgradeModule

    function test_structural_lockWiring_reverts_when_issuanceModule_unset() external {
        StructuralUpgradeModule m = new StructuralUpgradeModule(address(this));
        m.wire(CELL, address(0));
        vm.expectRevert(StructuralUpgradeModule.HostUnset.selector);
        m.lockWiring();
    }

    function test_structural_lockWiring_reverts_when_cell_unset() external {
        StructuralUpgradeModule m = new StructuralUpgradeModule(address(this));
        m.wire(address(0), ISSUANCE);
        vm.expectRevert(StructuralUpgradeModule.HostUnset.selector);
        m.lockWiring();
    }

    function test_structural_lockWiring_succeeds_when_all_set() external {
        StructuralUpgradeModule m = new StructuralUpgradeModule(address(this));
        m.wire(CELL, ISSUANCE);
        m.lockWiring();
        assertTrue(m.wiringLocked());
        assertEq(m.issuanceModule(), ISSUANCE);
    }
}

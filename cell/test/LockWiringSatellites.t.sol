// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "./helpers/CellTestDeploy.sol";
import "../script/LockWiring.s.sol";

contract LockWiringSatellitesHarness is LockWiring {
    function gateAndLock(address cell, Satellites memory s) external {
        _verifySatellites(cell, s);
        _lockSatellites(s);
    }
}

/// @notice bug_004 of the 2026-09-15 second-family review, widened by a chain read: after §2b, SIX satellites kept an
///         open `wire()` on the canonical cell (ClaimDispute, SpecGap, IntegrityReview, FmeaRegistry, SpecArbiter,
///         StructuralUpgrade - `wiringLocked()` false on all six, read 2026-09-15), because LockWiring armed only the
///         issuance module and the cell's dispute-module param. LockWiring now gates every pointer those locks freeze
///         against the record and arms all six.
contract LockWiringSatellitesTest is Test {
    CellTestDeploy.Deployment d;
    LockWiringSatellitesHarness h;

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        h = new LockWiringSatellitesHarness();
        d.fmeaRegistry.wireClaimModule(address(d.claimModule));
    }

    function _sats() internal view returns (LockWiring.Satellites memory s) {
        s = LockWiring.Satellites({
            claimDispute: address(d.claimModule),
            specGap: address(d.specGapModule),
            integrityReview: address(d.integrityReviewModule),
            fmeaRegistry: address(d.fmeaRegistry),
            specArbiter: address(d.specArbiterModule),
            structuralUpgrade: address(d.structuralUpgradeModule),
            issuance: address(d.issuance)
        });
    }

    function _handOver() internal {
        d.claimModule.transferAdmin(address(h));
        d.specGapModule.transferAdmin(address(h));
        d.integrityReviewModule.transferAdmin(address(h));
        d.fmeaRegistry.transferAdmin(address(h));
        d.specArbiterModule.transferAdmin(address(h));
        d.structuralUpgradeModule.transferAdmin(address(h));
    }

    function _allLocked() internal view returns (bool) {
        return d.claimModule.wiringLocked() && d.specGapModule.wiringLocked() && d.integrityReviewModule.wiringLocked()
            && d.fmeaRegistry.wiringLocked() && d.specArbiterModule.wiringLocked() && d.structuralUpgradeModule.wiringLocked();
    }

    /// THE CASE: RED before the fix - the gate passed and nothing was locked.
    function test_a_correct_wiring_locks_all_six_satellites() public {
        _handOver();
        h.gateAndLock(address(d.cell), _sats());
        assertTrue(_allLocked(), "all six satellite wiring locks armed");
        vm.expectRevert();
        vm.prank(address(h));
        d.claimModule.wire(address(0xBEEF)); // and wire() is now refused
    }

    function test_rerun_is_a_no_op() public {
        _handOver();
        h.gateAndLock(address(d.cell), _sats());
        h.gateAndLock(address(d.cell), _sats());
        assertTrue(_allLocked());
    }

    /// A lock is permanent, so a mis-wire must be refused BEFORE any lock - including a peer the lock itself never checks.
    function test_a_miswired_peer_REFUSES_and_locks_nothing() public {
        d.integrityReviewModule.wire(address(d.cell), address(0xBAD)); // specArbiterModule wrong; cell right
        _handOver();
        vm.expectRevert();
        h.gateAndLock(address(d.cell), _sats());
        assertFalse(d.claimModule.wiringLocked(), "nothing locked on refusal");
        assertFalse(d.integrityReviewModule.wiringLocked(), "and the mis-wired one least of all");
    }

    function test_a_satellite_pointing_at_another_cell_REFUSES() public {
        d.specGapModule.wire(address(0xCE11));
        _handOver();
        vm.expectRevert();
        h.gateAndLock(address(d.cell), _sats());
    }
}

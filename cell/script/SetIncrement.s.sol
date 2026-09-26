// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "./InstanceAware.s.sol";
import "../contracts/AuditCell.sol";

/// @dev Post-genesis: set the position-scaled registration hold WITHOUT locking it (PC-33, 2026-08-15).
///
/// WHY THIS SCRIPT EXISTS. `increment` was reachable from exactly one place outside the tests -
/// `DeployCell._applyMainnetProfile`, which calls `setIncrement(1 ether)` and `lockIncrement()` in the
/// SAME transaction, and is itself reachable only through the `TIME_PROFILE` branch that also chooses the
/// entropy provider and the time windows. So a testnet instance had `increment = 0` with no setter, and a
/// mainnet-profile instance had it locked at 1e18 before anything could measure it. **PC-30's §7
/// acceptance probe requires an instance where the hold is non-zero AND still movable, and no producible
/// instance could be one.** PC-21's trigger ("measure the newcomer path at the live 1e18") was unbuildable
/// for the same reason. Both rows read as "not done yet"; the accurate reading was "not producible".
///
/// WHY IT RUNS AFTER GENESIS. `GenesisBootstrapRegister`:18 hard-requires `cell.increment() == 0`, and the
/// deploy wrapper's step-4 read-back asserts the same. Setting the hold at deploy time would build an
/// instance that cannot bootstrap - a trap rather than a fix. Both guards are deliberately left standing.
///
/// WHY IT NEVER LOCKS. An acceptance probe must be able to put the value back, and a probe that can only
/// be run once is a probe you will not run. `lockIncrement()` is NOT called here and must not be added:
/// locking is the mainnet posture and belongs to `DeployCell`, not to a testnet instrument.
///
/// Env: PRIVATE_KEY (deployer/admin), INCREMENT_WEI. Optional: AUDIT_CELL, DEPLOY_INSTANCE_LABEL.
contract SetIncrement is InstanceAware {
    /// Entry point for `forge script`: read the amount from the environment, then do the work.
    function run() external {
        runWith(vm.envUint("INCREMENT_WEI"));
    }

    /// The actual work, with the amount as an ARGUMENT rather than an environment read.
    ///
    /// Split out 2026-08-15 for testability, and it was not a preference — it was forced. A test that
    /// changed `INCREMENT_WEI` between two calls could not make `vm.envUint` return the new value: one
    /// case armed 0 and the run set 1e18, another armed nothing and the run read 0. Whatever the cause,
    /// a script whose behaviour can only be driven through process environment is a script whose
    /// behaviour cannot be pinned by a test — and this one exists precisely to be trusted by a probe.
    /// `run()` stays the env-reading wrapper the deploy wrapper calls; `runWith` is what is testable.
    function runWith(uint256 incr) public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        AuditCell cell = AuditCell(_cellAddress());

        // Refuse loudly rather than send a no-op transaction that reads like success in a log.
        require(!cell.incrementLocked(), "increment is LOCKED on this instance - it was deployed under the mainnet profile; redeploy with TIME_PROFILE=testnet");
        require(incr != cell.increment(), "increment already at the requested value - nothing to do");

        uint256 before = cell.increment();
        uint256 auditors = cell.auditorCount();

        vm.startBroadcast(pk);
        cell.setIncrement(incr);
        vm.stopBroadcast();

        // Read back through the same interface a consumer would use. A setter whose effect nobody reads
        // is the assertion-that-restates-its-own-input shape this repo has paid for twice (M-1, D8.4).
        require(cell.increment() == incr, "setIncrement did not take");
        require(!cell.incrementLocked(), "increment became LOCKED during this call - unexpected, stop and inspect");

        console2.log("=== setIncrement done (NOT locked) ===");
        console2.log("increment before", before);
        console2.log("increment after ", cell.increment());
        console2.log("incrementLocked ", cell.incrementLocked());
        // What it now costs an UNREGISTERED newcomer to register: auditorCount x increment
        // (CellLogicLib:125-131). This is the number PC-30 and PC-21 are actually about.
        console2.log("auditorCount", auditors);
        console2.log("newcomer requiredHold", auditors * incr);
    }

    /// Virtual so a fixture hands in its own cell by override instead of writing the process-wide AUDIT_CELL,
    /// which every test in the run shares (VD-232(7), VD-145's class).
    function _cellAddress() internal view virtual returns (address) {
        if (vm.envExists("AUDIT_CELL")) {
            // R31 exempt (PC-78): this script reads NOTHING instance-specific but the cell, so an override cannot mix
            // two instances - so an operator may point it at a local cell beside a tracked deployments/31337.json that
            // names another. EnvCellAgreement.t.sol pins the exemption; G6 briefly broke it.
            return vm.envAddress("AUDIT_CELL");
        }
        return vm.parseJsonAddress(vm.readFile(_deploymentRecordPath()), ".AuditCell");
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "./EnvCell.sol";
import "./InstanceAware.s.sol";
import "../contracts/AuditCell.sol";
import "./GenesisAuditorKey.sol";

/// @dev Genesis step 1 (auditor B): register as auditor #1 (free at increment=0).
/// Env: AUDITOR_PRIVATE_KEY (REQUIRED - no fallback to PRIVATE_KEY, and never the same address, PC-86).
/// Optional: AUDIT_CELL, DEPLOY_INSTANCE_LABEL (else deployments/{chainId}[-{label}].json).
/// REFUSES BEFORE BROADCAST (2026-09-15, PC-85): a cell that already has ANY registered auditor - position 1 is
/// taken, and registering now would land this auditor at position 2 on chain. This narrows the deploy-to-register
/// race to the blocks between this simulation and its inclusion; it cannot close it (that is hull bytes).
contract GenesisBootstrapRegister is InstanceAware {
    function run() external {
        uint256 pk = _auditorKey();
        address auditor = vm.addr(pk);
        AuditCell cell = AuditCell(_cellAddress());

        _checkRegisterReady(cell);
        _checkNamedAuditor(cell, auditor);

        vm.startBroadcast(pk);
        cell.register();
        vm.stopBroadcast();

        (uint256 successful, uint256 failed, uint256 found, uint256 position,, bool inQueue) =
            cell.auditors(auditor);
        console2.log("=== Genesis register done ===");
        console2.log("auditor", auditor);
        console2.log("position", position);
        console2.log("inQueue", inQueue);
        console2.log("successful", successful);
        console2.log("failed", failed);
        console2.log("found", found);
        require(position == 1, "auditor #1 expected");
        console2.log("Next: GenesisBootstrapProtocol.s.sol (deployer key)");
    }

    /// @dev PC-86: required, and never the deployer's key - see `GenesisAuditorKey`.
    function _auditorKey() internal view returns (uint256) {
        return GenesisAuditorKey.fromEnv();
    }

    /// @dev The pre-broadcast gate, split out so a test can drive it with no key.
    function _checkRegisterReady(AuditCell cell) internal view {
        require(cell.genesisPending(), "genesis already spent");
        require(cell.increment() == 0, "expected testnet increment=0");
        // PC-85: position 1 is free to ANYONE at any increment (`CellLogicLib` hold = auditorCount * increment), so check
        // it is still free BEFORE broadcasting rather than discovering position 2 on chain afterwards.
        require(
            cell.auditorCount() == 0,
            "position 1 is already taken - registering now lands this auditor at position 2 (PC-85)"
        );
    }

    /// @dev G6 (PC-85): the cell refuses any first registrant but the genesis auditor its deploy named; say so before the
    ///      broadcast rather than let the chain revert it.
    function _checkNamedAuditor(AuditCell cell, address auditor) internal view {
        address named = cell.genesisAuditor();
        require(named == address(0) || named == auditor, "this cell named a different genesis auditor (PC-85)");
    }

    function _cellAddress() internal view returns (address) {
        if (vm.envExists("AUDIT_CELL")) {
            return EnvCell.agreeing(vm.envAddress("AUDIT_CELL"), _deploymentRecordPath()); // PC-107
        }
        return vm.parseJsonAddress(vm.readFile(_deploymentRecordPath()), ".AuditCell");
    }
}

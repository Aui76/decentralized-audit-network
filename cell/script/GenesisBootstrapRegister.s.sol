// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../contracts/AuditCell.sol";

/// @dev Genesis step 1 (auditor B): register as auditor #1 (free at increment=0).
/// Env: AUDITOR_PRIVATE_KEY. Optional: AUDIT_CELL (else deployments/{chainId}.json).
contract GenesisBootstrapRegister is Script {
    function run() external {
        uint256 pk = _auditorKey();
        address auditor = vm.addr(pk);
        AuditCell cell = AuditCell(_cellAddress());

        require(cell.genesisPending(), "genesis already spent");
        require(cell.increment() == 0, "expected testnet increment=0");

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

    function _auditorKey() internal view returns (uint256) {
        if (vm.envExists("AUDITOR_PRIVATE_KEY")) return vm.envUint("AUDITOR_PRIVATE_KEY");
        return vm.envUint("PRIVATE_KEY");
    }

    function _cellAddress() internal view returns (address) {
        if (vm.envExists("AUDIT_CELL")) {
            return vm.envAddress("AUDIT_CELL");
        }
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        return vm.parseJsonAddress(vm.readFile(path), ".AuditCell");
    }
}

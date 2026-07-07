// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../contracts/AuditCell.sol";

/// @dev Genesis step 3 (auditor B): acceptAudit + provePass.
/// Env: AUDITOR_PRIVATE_KEY. Optional: AUDIT_CELL, AUDIT_ID (else deployments/genesis-{chainId}.json).
contract GenesisBootstrapAuditor is Script {
    bytes32 internal constant RESULT_ROOT = keccak256("genesis.bootstrap.pass.v1");

    function run() external {
        uint256 pk = _auditorKey();
        address auditor = vm.addr(pk);
        AuditCell cell = AuditCell(_cellAddress());
        uint256 id = _auditId();
        bytes32 verdictToolId = _verdictToolId();

        require(cell.auditAuditorOf(id) == auditor, "not assigned auditor");

        vm.startBroadcast(pk);
        cell.acceptAudit(id, _specErrorsRoot());
        cell.provePass(id, verdictToolId, RESULT_ROOT);
        vm.stopBroadcast();

        console2.log("=== Genesis auditor step done ===");
        console2.log("auditId", id);
        console2.log("state", uint256(cell.auditStateOf(id)));
        console2.log("Wait minAuditWindow (~10m testnet), then GenesisBootstrapConfirm.s.sol");
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

    function _genesisJsonPath() internal view returns (string memory) {
        if (vm.envExists("GENESIS_ARTIFACT")) {
            return vm.envString("GENESIS_ARTIFACT");
        }
        return string.concat("deployments/genesis-", vm.toString(block.chainid), ".json");
    }

    function _auditId() internal view returns (uint256) {
        if (vm.envExists("AUDIT_ID")) {
            return vm.envUint("AUDIT_ID");
        }
        return vm.parseJsonUint(vm.readFile(_genesisJsonPath()), ".auditId");
    }

    function _specErrorsRoot() internal view returns (bytes32) {
        if (vm.envExists("AUDIT_ID")) {
            return keccak256("");
        }
        return vm.parseJsonBytes32(vm.readFile(_genesisJsonPath()), ".specErrorsRoot");
    }

    function _verdictToolId() internal view returns (bytes32) {
        if (vm.envExists("AUDIT_ID")) {
            return keccak256("genesis.verdict.tool");
        }
        return vm.parseJsonBytes32(vm.readFile(_genesisJsonPath()), ".verdictToolId");
    }
}

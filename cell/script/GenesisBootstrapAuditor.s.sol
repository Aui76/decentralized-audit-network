// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "./EnvCell.sol";
import "./InstanceAware.s.sol";
import "../contracts/AuditCell.sol";
import "./GenesisAuditorKey.sol";

/// @dev Genesis step 3 (auditor B): acceptAudit + provePass.
/// Env: AUDITOR_PRIVATE_KEY (REQUIRED - no fallback to PRIVATE_KEY, and never the same address, PC-86). Optional: AUDIT_CELL, AUDIT_ID, DEPLOY_INSTANCE_LABEL
/// (else deployments/genesis-{chainId}[-{label}].json).
/// REFUSES (2026-09-15, VD-181): no open genesis audit, an AUDIT_ID that is not `genesisAuditId()`, and an auditor that
/// is not the one assigned.
contract GenesisBootstrapAuditor is InstanceAware {
    bytes32 internal constant RESULT_ROOT = keccak256("genesis.bootstrap.pass.v1");

    function run() external {
        uint256 pk = _auditorKey();
        address auditor = vm.addr(pk);
        AuditCell cell = AuditCell(_cellAddress());
        uint256 id = _auditId();
        bytes32 verdictToolId = _verdictToolId();

        _checkGenesisBinding(cell, id, auditor);

        vm.startBroadcast(pk);
        cell.acceptAudit(id, _specErrorsRoot());
        cell.provePass(id, verdictToolId, RESULT_ROOT);
        vm.stopBroadcast();

        console2.log("=== Genesis auditor step done ===");
        console2.log("auditId", id);
        console2.log("state", uint256(cell.auditStateOf(id)));
        console2.log("Wait minAuditWindow (~10m testnet), then GenesisBootstrapConfirm.s.sol");
    }

    /// @dev The gate, split out so a test can drive it with no key.
    ///      2026-09-15 (VD-181's record): the assigned-auditor check alone accepted-and-passed ANY audit this auditor
    ///      was drawn for as though it were genesis. The id must be the cell's OPEN genesis audit.
    function _checkGenesisBinding(AuditCell cell, uint256 id, address auditor) internal view {
        require(cell.genesisAuditOpen(), "no genesis audit is open on this cell");
        require(id == cell.genesisAuditId(), "AUDIT_ID is not the cell's open genesis audit");
        require(cell.auditAuditorOf(id) == auditor, "not assigned auditor");
    }

    /// @dev PC-86: required, and never the deployer's key - see `GenesisAuditorKey`.
    function _auditorKey() internal view returns (uint256) {
        return GenesisAuditorKey.fromEnv();
    }

    function _cellAddress() internal view returns (address) {
        if (vm.envExists("AUDIT_CELL")) {
            return EnvCell.agreeing(vm.envAddress("AUDIT_CELL"), _deploymentRecordPath()); // PC-107
        }
        return vm.parseJsonAddress(vm.readFile(_deploymentRecordPath()), ".AuditCell");
    }

    function _genesisJsonPath() internal view returns (string memory) {
        if (vm.envExists("GENESIS_ARTIFACT")) {
            return vm.envString("GENESIS_ARTIFACT");
        }
        return _genesisRecordPath();
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

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../contracts/AuditCell.sol";
import "../contracts/GenesisBootstrapTarget.sol";

/// @dev Genesis step 2 (protocol A): deploy target, submitGenesisAudit (declared-unfunded B_g), accept assigned auditor.
/// Env: PRIVATE_KEY. Optional: AUDIT_CELL, GENESIS_SALT (default 1).
contract GenesisBootstrapProtocol is Script {
    bytes32 internal constant SPEC_TOOL_ID = keccak256("genesis.spec.tool");
    bytes32 internal constant VERDICT_TOOL_ID = keccak256("genesis.verdict.tool");
    bytes32 internal constant SPEC_HASH = keccak256("genesis.bootstrap.spec.v1");
    bytes32 internal constant SPEC_ERRORS = keccak256("");

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address protocol = vm.addr(pk);
        AuditCell cell = AuditCell(_cellAddress());

        require(cell.genesisPending(), "genesis already spent");
        require(!cell.genesisAuditOpen(), "genesis audit already open");

        uint256 salt = vm.envOr("GENESIS_SALT", uint256(1));

        vm.startBroadcast(pk);

        GenesisBootstrapTarget target = new GenesisBootstrapTarget(salt);
        bytes32 codehash = address(target).codehash;

        bytes32[] memory declared = new bytes32[](1);
        declared[0] = VERDICT_TOOL_ID;

        uint256 id = cell.submitGenesisAudit(
            address(target),
            codehash,
            SPEC_HASH,
            SPEC_TOOL_ID,
            SPEC_ERRORS,
            vm.envOr("GENESIS_BOUNTY", uint256(5000 ether)),
            declared,
            0,
            0
        );

        cell.protocolAcceptAuditor(id);

        vm.stopBroadcast();

        address assigned = cell.auditAuditorOf(id);
        require(cell.genesisAuditOpen(), "genesisAuditOpen");
        require(cell.genesisAuditId() == id, "genesisAuditId");

        string memory obj = "genesis";
        string memory json = vm.serializeUint(obj, "chainId", block.chainid);
        json = vm.serializeAddress(obj, "auditCell", address(cell));
        json = vm.serializeAddress(obj, "protocol", protocol);
        json = vm.serializeAddress(obj, "assignedAuditor", assigned);
        json = vm.serializeAddress(obj, "target", address(target));
        json = vm.serializeBytes32(obj, "expectedCodehash", codehash);
        json = vm.serializeUint(obj, "auditId", id);
        json = vm.serializeBytes32(obj, "specHash", SPEC_HASH);
        json = vm.serializeBytes32(obj, "specErrorsRoot", SPEC_ERRORS);
        json = vm.serializeBytes32(obj, "specToolId", SPEC_TOOL_ID);
        json = vm.serializeBytes32(obj, "verdictToolId", VERDICT_TOOL_ID);
        json = vm.serializeUint(obj, "minAuditWindowSec", cell.minAuditWindow());

        string memory path = string.concat("deployments/genesis-", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);

        console2.log("=== Genesis protocol step done ===");
        console2.log("target", address(target));
        console2.logBytes32(codehash);
        console2.log("auditId", id);
        console2.log("assignedAuditor", assigned);
        console2.log("minAuditWindowSec", cell.minAuditWindow());
        console2.log("written", path);
        console2.log("Next: GenesisBootstrapAuditor.s.sol (auditor key)");
    }

    function _cellAddress() internal view returns (address) {
        if (vm.envExists("AUDIT_CELL")) {
            return vm.envAddress("AUDIT_CELL");
        }
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        return vm.parseJsonAddress(vm.readFile(path), ".AuditCell");
    }
}

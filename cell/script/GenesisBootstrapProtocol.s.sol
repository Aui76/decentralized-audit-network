// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./EnvReads.s.sol";
import "./EnvCell.sol";
import "./InstanceAware.s.sol";
import "../contracts/AuditCell.sol";
import "../contracts/GenesisBootstrapTarget.sol";

/// @dev Genesis step 2 (protocol A): deploy target, submitGenesisAudit (declared-unfunded B_g), accept assigned auditor.
/// Env: PRIVATE_KEY. Optional: AUDIT_CELL, GENESIS_SALT (default 1), DEPLOY_INSTANCE_LABEL
/// (routes both the deployment-record read and the genesis-record write to the labeled instance files).
contract GenesisBootstrapProtocol is InstanceAware {
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

        uint256 salt = _optionalUint("GENESIS_SALT", 1);

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
            _optionalUint("GENESIS_BOUNTY", 5000 ether),
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

        // bug_408, fixed 2026-09-05: this script wrote its record UNCONDITIONALLY -- no dry-run split,
        // no simulation marker, no overwrite guard -- while every neighbouring writer (DeployCell,
        // DeployMembrane) carries all three. The genesis record is the worst place in the tree to be
        // missing them: genesis happens ONCE per cell (`cell.genesisPending()` is checked at the top and
        // is false forever after), so the record of the real genesis is irreplaceable, and a dry-run
        // rehearsal would silently overwrite it with predicted addresses for a run that never landed.
        //
        // DEFENSE 1 -- the path splits. A dry-run writes `.dryrun.json`, exactly as the membrane does.
        // DEFENSE 2 -- the marker travels INSIDE the file, because a path is lost the moment the file
        //              is pasted into a findings entry or copied to another machine.
        if (!_isBroadcast()) {
            json = vm.serializeBool(obj, "simulation", true);
            json = vm.serializeString(
                obj,
                "simulationNote",
                "forge script dry-run only - this genesis audit was NEVER submitted; the target address is a CREATE prediction and the auditId is simulated. The real record, if one exists, is deployments/genesis-{chainId}[-{label}].json"
            );
        }

        string memory path = _genesisRecordPath();
        if (!_isBroadcast()) {
            path = string.concat(_stripJson(path), ".dryrun.json");
        }

        // DEFENSE 3 -- the overwrite guard. Same shape as the membrane's: refuse to replace a record
        // that names a DIFFERENT audit. Equal auditId means a re-run of the same genesis and is
        // harmless; a different one means this is about to erase evidence of the genesis that
        // actually happened. GENESIS_OVERWRITE accepts "1" or "true" -- `envOr(bool)` parses ONLY
        // "true", which is the bug_005 family this repo has already paid for once.
        string memory overwriteRaw = vm.envOr("GENESIS_OVERWRITE", string(""));
        bool overwriteForced = keccak256(bytes(overwriteRaw)) == keccak256(bytes("1"))
            || keccak256(bytes(overwriteRaw)) == keccak256(bytes("true"));
        if (vm.exists(path) && !overwriteForced) {
            string memory existing = vm.readFile(path);
            uint256 existingId = vm.parseJsonUint(existing, ".auditId");
            require(
                existingId == id,
                "GenesisBootstrapProtocol: refusing to overwrite an existing genesis record for a DIFFERENT auditId -- genesis happens once and this record is the evidence. Use a new DEPLOY_INSTANCE_LABEL, or set GENESIS_OVERWRITE=1 if you mean it"
            );
            // PC-76 (4), 2026-09-13: the auditId alone cannot tell two cells apart - EVERY cell's genesis is
            // audit #0 - so at G-f this guard let the canonical cell's genesis silently replace the predecessor
            // 0xB8BFC2dd's record (git kept it). Same audit id is only a re-run if it is the same CELL. A record
            // without an auditCell key cannot prove that, and unknown is not "same": it refuses too.
            require(
                vm.keyExistsJson(existing, ".auditCell") && vm.parseJsonAddress(existing, ".auditCell") == address(cell),
                "GenesisBootstrapProtocol: refusing to overwrite the genesis record of a DIFFERENT (or unnamed) cell -- every cell's genesis is auditId 0, so the id cannot tell them apart. Archive the old record, use a new DEPLOY_INSTANCE_LABEL, or set GENESIS_OVERWRITE=1 if you mean it"
            );
        }
        vm.writeJson(json, path);

        console2.log("=== Genesis protocol step done ===");
        console2.log("target", address(target));
        console2.logBytes32(codehash);
        console2.log("auditId", id);
        console2.log("assignedAuditor", assigned);
        console2.log("minAuditWindowSec", cell.minAuditWindow());
        console2.log("written", path);
        if (!_isBroadcast()) {
            console2.log("!! DRY RUN -- record written to the .dryrun.json path and marked simulation.");
        }
        console2.log("Next: GenesisBootstrapAuditor.s.sol (auditor key)");
    }

    function _cellAddress() internal view returns (address) {
        if (vm.envExists("AUDIT_CELL")) {
            return EnvCell.agreeing(vm.envAddress("AUDIT_CELL"), _deploymentRecordPath()); // PC-107
        }
        return vm.parseJsonAddress(vm.readFile(_deploymentRecordPath()), ".AuditCell");
    }

    /// @dev True only when this execution is actually landing on chain. Same pair DeployMembrane
    ///      uses; kept as a local helper rather than pushed into InstanceAware, which is deliberately
    ///      path-only and is inherited by read-only scripts that must not grow a broadcast notion.
    function _isBroadcast() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
            || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }

    /// @dev Drop a trailing ".json" so the dry-run suffix can be appended. `_genesisRecordPath()` is
    ///      InstanceAware's and always ends in ".json"; asserting that here rather than assuming it,
    ///      because a silent mis-split would write the dry-run over the real record - the exact
    ///      outcome this whole guard exists to prevent.
    function _stripJson(string memory pathIn) internal pure returns (string memory) {
        bytes memory b = bytes(pathIn);
        require(b.length > 5, "genesis record path too short to be <name>.json");
        require(
            b[b.length - 5] == "." && b[b.length - 4] == "j" && b[b.length - 3] == "s"
                && b[b.length - 2] == "o" && b[b.length - 1] == "n",
            "genesis record path does not end in .json - refusing to guess where the suffix goes"
        );
        bytes memory out = new bytes(b.length - 5);
        for (uint256 i = 0; i < b.length - 5; i++) {
            out[i] = b[i];
        }
        return string(out);
    }

}

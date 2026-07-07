// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellStorage.sol";
import "../contracts/CellToken.sol";

/// @dev Genesis step 4: confirmAudit after minAuditWindow (mints first tokens).
/// Env: PRIVATE_KEY (any funded wallet). Optional: AUDIT_CELL, CELL_TOKEN, AUDIT_ID.
contract GenesisBootstrapConfirm is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        AuditCell cell = AuditCell(_cellAddress());
        CellToken token = CellToken(_tokenAddress());
        uint256 id = _auditId();

        uint256 supplyBefore = token.totalSupply();
        require(cell.genesisPending(), "genesis already spent?");

        require(
            uint256(cell.auditStateOf(id)) == uint256(CellTypeDefs.AuditState.AwaitingWindow),
            "not AwaitingWindow - run auditor step first"
        );

        vm.startBroadcast(pk);
        cell.confirmAudit(id);
        vm.stopBroadcast();

        uint256 supplyAfter = token.totalSupply();
        address auditor = cell.auditAuditorOf(id);

        console2.log("=== Genesis confirm done ===");
        console2.log("auditId", id);
        console2.log("state", uint256(cell.auditStateOf(id)));
        console2.log("totalSupply before", supplyBefore);
        console2.log("totalSupply after", supplyAfter);
        console2.log("genesisPending", cell.genesisPending());
        console2.log("auditor balance", token.balanceOf(auditor));

        require(supplyBefore == 0, "expected zero supply before genesis confirm");
        require(supplyAfter > 0, "expected mint after confirm");
        require(!cell.genesisPending(), "genesisPending must be false");
        console2.log("Next: LockMinter.s.sol (deployer key)");
    }

    function _cellAddress() internal view returns (address) {
        if (vm.envExists("AUDIT_CELL")) {
            return vm.envAddress("AUDIT_CELL");
        }
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        return vm.parseJsonAddress(vm.readFile(path), ".AuditCell");
    }

    function _tokenAddress() internal view returns (address) {
        if (vm.envExists("CELL_TOKEN")) {
            return vm.envAddress("CELL_TOKEN");
        }
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        return vm.parseJsonAddress(vm.readFile(path), ".CellToken");
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
}

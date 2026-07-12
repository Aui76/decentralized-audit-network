// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../../contracts/AuditCell.sol";
import "../../contracts/tools/TransferCreditsV1.sol";
import "../../contracts/tools/AuditResultV1.sol";

/// @dev One-time: register transfer-credits verdict tool on live cell.
/// Prereq: set TOOL_ARTIFACT_HASH from zero-slot probe (see ComputeTransferCreditsTool.s.sol).
contract RegisterTransferCreditsTool is Script {
    function run() external {
        bytes32 toolId = TransferCreditsV1.toolId();
        console2.log("toolArtifactHash (L-02 declared, zero-slot normative)");
        console2.logBytes32(TransferCreditsV1.toolArtifactHash());
        console2.logBytes32(toolId);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address cellAddr = vm.envAddress("AUDIT_CELL");

        vm.startBroadcast(pk);
        AuditCell(cellAddr).registerTool(toolId, false);
        vm.stopBroadcast();

        console2.log("registered transfer-credits on", cellAddr);
    }
}

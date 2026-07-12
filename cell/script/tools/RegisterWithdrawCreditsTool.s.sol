// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../../contracts/AuditCell.sol";
import "../../contracts/tools/WithdrawCreditsV1.sol";

/// @dev Register Organ 1 verdict tool (withdraw-credits v1.1.0, content-bound toolId) on live cell. Requires AUDIT_CELL in env.
contract RegisterWithdrawCreditsTool is Script {
    function run() external {
        bytes32 toolId = WithdrawCreditsV1.toolId();
        console2.log("toolArtifactHash (runtime bytecode)");
        console2.logBytes32(WithdrawCreditsV1.toolArtifactHash());
        console2.log("toolId (registerTool)");
        console2.logBytes32(toolId);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address cellAddr = vm.envAddress("AUDIT_CELL");

        vm.startBroadcast(pk);
        AuditCell(cellAddr).registerTool(toolId, false);
        vm.stopBroadcast();

        console2.log("cell", cellAddr);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../contracts/CellToken.sol";

/// @dev Post-genesis: lock token minter (only after genesis confirm minted).
/// Env: PRIVATE_KEY (deployer/admin). Optional: CELL_TOKEN.
contract LockMinter is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        CellToken token = CellToken(_tokenAddress());

        require(!token.minterLocked(), "already locked");
        require(token.totalSupply() > 0, "genesis mint not proven yet");

        vm.startBroadcast(pk);
        token.lockMinter();
        vm.stopBroadcast();

        console2.log("=== lockMinter done ===");
        console2.log("minterLocked", token.minterLocked());
        console2.log("totalSupply", token.totalSupply());
    }

    function _tokenAddress() internal view returns (address) {
        if (vm.envExists("CELL_TOKEN")) {
            return vm.envAddress("CELL_TOKEN");
        }
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        return vm.parseJsonAddress(vm.readFile(path), ".CellToken");
    }
}

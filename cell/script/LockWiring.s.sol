// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../contracts/IssuanceModule.sol";

/// @dev Post-wiring cutover step (G-27, row 7): lock the IssuanceModule wiring. This freezes wire() /
///      setStructuralModule AND arms the founder-share lower-only lock (setFounderShareBps may only DECREASE
///      after this). Run AFTER the §2 wiring read-backs pass, so wiring stays fixable until confirmed green.
///      Env: PRIVATE_KEY (deployer/admin). Optional: ISSUANCE_MODULE.
contract LockWiring is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        IssuanceModule issuance = IssuanceModule(_issuanceAddress());

        require(!issuance.wiringLocked(), "already locked");
        require(issuance.cell() != address(0) && address(issuance.token()) != address(0), "wiring incomplete");

        vm.startBroadcast(pk);
        issuance.lockWiring();
        vm.stopBroadcast();

        console2.log("=== lockWiring done ===");
        console2.log("wiringLocked", issuance.wiringLocked());
        console2.log("founderShareBps (now lower-only)", issuance.founderShareBps());
    }

    function _issuanceAddress() internal view returns (address) {
        if (vm.envExists("ISSUANCE_MODULE")) {
            return vm.envAddress("ISSUANCE_MODULE");
        }
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        return vm.parseJsonAddress(vm.readFile(path), ".IssuanceModule");
    }
}

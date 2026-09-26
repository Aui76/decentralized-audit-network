// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./EnvCell.sol";
import "forge-std/Script.sol";
import "./InstanceAware.s.sol";
import "../contracts/CellToken.sol";

/// @dev Post-genesis: lock token minter (only after genesis confirm minted).
/// Env: PRIVATE_KEY (deployer/admin). Optional: CELL_TOKEN, DEPLOY_INSTANCE_LABEL.
/// REFUSES (2026-09-15, VD-181): an already-locked minter, a `token.minter()` that is not the recorded IssuanceModule,
/// and a cell whose `genesisPending()` is still true; reads the lock and the minter back after broadcasting.
contract LockMinter is InstanceAware {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        CellToken token = CellToken(_tokenAddress());
        address expectedMinter = _recordedIssuance();

        _checkMintLockReady(token, expectedMinter, _cellGenesisPending());

        vm.startBroadcast(pk);
        token.lockMinter();
        vm.stopBroadcast();

        require(token.minterLocked(), "read-back: minterLocked() is still false");
        require(token.minter() == expectedMinter, "read-back: the locked minter is not the recorded IssuanceModule");

        console2.log("=== lockMinter done ===");
        console2.log("minterLocked", token.minterLocked());
        console2.log("minter (== recorded IssuanceModule)", token.minter());
        console2.log("totalSupply", token.totalSupply());
    }

    /// @dev The gate, split out so a test can drive it with no key or record.
    ///      2026-09-15 (VD-181's record): the lock is permanent, so the thing it freezes is compared to the record FIRST
    ///      - a minter re-pointed between DeployCell and this step was locked in with inflation authority - and genesis
    ///      is proven by the cell's own flag, not by `totalSupply > 0`, which a GENESIS_MINT premint makes true.
    function _checkMintLockReady(CellToken token, address expectedMinter, bool genesisPending) internal view {
        require(!token.minterLocked(), "already locked");
        require(expectedMinter != address(0), "no IssuanceModule in the deployment record - refusing to lock blind");
        require(token.minter() == expectedMinter,
                "token.minter() is not the recorded IssuanceModule - locking would freeze the wrong minter forever");
        require(!genesisPending, "genesis not confirmed yet (cell.genesisPending() is true)");
    }

    function _recordedIssuance() internal view returns (address) {
        return vm.parseJsonAddress(vm.readFile(_deploymentRecordPath()), ".IssuanceModule");
    }

    function _cellGenesisPending() internal view returns (bool) {
        address cell = vm.parseJsonAddress(vm.readFile(_deploymentRecordPath()), ".AuditCell");
        (bool success, bytes memory data) = cell.staticcall(abi.encodeWithSignature("genesisPending()"));
        require(success && data.length == 32, "cannot read cell.genesisPending() - refusing to lock blind");
        return abi.decode(data, (bool));
    }

    function _tokenAddress() internal view returns (address) {
        if (vm.envExists("CELL_TOKEN")) {
            return EnvCell.agreeingAt(vm.envAddress("CELL_TOKEN"), _deploymentRecordPath(), ".CellToken", "CELL_TOKEN");
        }
        return vm.parseJsonAddress(vm.readFile(_deploymentRecordPath()), ".CellToken");
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Script.sol";

/*
 * Post-deploy wiring read-back (CUTOVER-RUNBOOK.md Phase 4.1, Appendix B).
 *
 * Read-only. No key, no broadcast. Run after DeployCell with:
 *   forge script script/VerifyWiring.s.sol:VerifyWiring --rpc-url base_sepolia
 *
 * SCOPE — IMPORTANT. The cell ABI is lean: only a subset of wires is observable.
 *   Asserted here (getters exist):
 *     cell.treasuryEscrow == escrow      (G-01 mutual bind)
 *     cell.issuanceModule == issuance
 *     cell.claimVerifier  == 0           (declare-only)
 *     token.minter        == issuance
 *     cell.admin          == deployer
 *   NOT observable (no getter, no event) — verify FUNCTIONALLY via the Phase 5 exercise:
 *     dispute modules 0-4, escrow.integrityReviewModule, issuance.structuralModule,
 *     claimModule.fmeaRegistry / fmeaRegistry.claimModule.
 *   token.minterLocked is reported (expected false until the post-smoke lockMinter()).
 *
 * If `setDisputeModule` gains a DisputeModuleSet event (recommended pre-cutover), extend this
 * to read those wires from the deploy receipt logs instead of relying on the exercise alone.
 */

interface IVerifyCell {
    function admin() external view returns (address);
    function treasuryEscrow() external view returns (address);
    function issuanceModule() external view returns (address);
    function claimVerifier() external view returns (address);
    function claimVerifierLocked() external view returns (bool);
}

interface IVerifyToken {
    function minter() external view returns (address);
    function minterLocked() external view returns (bool);
}

contract VerifyWiring is Script {
    function run() external view {
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        address deployer = vm.parseJsonAddress(json, ".deployer");
        address cellAddr = vm.parseJsonAddress(json, ".AuditCell");
        address escrow = vm.parseJsonAddress(json, ".CellEscrow");
        address issuance = vm.parseJsonAddress(json, ".IssuanceModule");
        address tokenAddr = vm.parseJsonAddress(json, ".CellToken");

        IVerifyCell cell = IVerifyCell(cellAddr);
        IVerifyToken token = IVerifyToken(tokenAddr);

        uint256 fails = 0;
        fails += _eq("cell.treasuryEscrow == escrow", cell.treasuryEscrow(), escrow);
        fails += _eq("cell.issuanceModule == issuance", cell.issuanceModule(), issuance);
        fails += _eq("cell.claimVerifier == 0 (declare-only)", cell.claimVerifier(), address(0));
        fails += _eq("cell.admin == deployer", cell.admin(), deployer);
        fails += _eq("token.minter == issuance", token.minter(), issuance);

        console2.log("--- reported (not asserted) ---");
        console2.log("token.minterLocked (false until post-smoke lockMinter)", token.minterLocked());
        console2.log("cell.claimVerifierLocked", cell.claimVerifierLocked());

        console2.log("--- NOT auto-verifiable; confirm via Phase 5 exercise ---");
        console2.log("dispute modules 0-4, escrow.integrity, issuance.structural, claim<->fmea");

        if (fails > 0) {
            revert(string.concat("VerifyWiring: ", vm.toString(fails), " assertion(s) FAILED"));
        }
        console2.log("VerifyWiring: all observable assertions PASSED");
    }

    function _eq(string memory label, address got, address want) internal pure returns (uint256) {
        if (got == want) {
            console2.log(string.concat("[ok] ", label));
            return 0;
        }
        console2.log(string.concat("[FAIL] ", label));
        console2.log("   got ", got);
        console2.log("   want", want);
        return 1;
    }
}

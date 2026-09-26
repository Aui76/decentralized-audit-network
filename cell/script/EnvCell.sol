// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {Vm} from "forge-std/Vm.sol";

/**
 * EnvCell — an `AUDIT_CELL` override may not contradict the deployment record it sits beside (PC-78, 2026-09-15).
 *
 * Fifty-odd scripts resolve their cell the same way: `AUDIT_CELL` if set, else the record's `.AuditCell` - and
 * most of them then take a token or a module from that SAME record. An override naming any other cell gives one
 * instance's cell and another instance's token or modules (bug_406's mix), and nothing refused it anywhere but
 * `PhaseFSetup`, the one script where the mix ended in a permanent lock.
 *
 * THE RULE: when the record the script resolves EXISTS, the override must name the cell that record names. The
 * path is the caller's, so a label-aware script passes its labelled record and a rung run with the label and
 * `AUDIT_CELL` both exported (`deploy-dedicated-instance.ps1`) still agrees with itself. When no record exists
 * there is nothing to contradict, and the override is returned as before.
 *
 * WHO CALLS IT: every `AUDIT_CELL` read under `cell/script/` (PC-107, 2026-09-18; enforced by structure-check
 * R31). Until then only scripts that take ANOTHER component from the same record called it; PC-107 widened it
 * because a stale `AUDIT_CELL` in a shell points a cell-only broadcast at the wrong cell just as silently. The
 * one exception is DECLARED at its read with `R31 exempt (<reason>)`: `SetIncrement.s.sol`, whose only record
 * read is `.AuditCell`, so an override cannot mix instances, and which `EnvCellAgreement.t.sol` pins as the
 * exemption.
 *
 * A LIBRARY and not a base, deliberately: the callers inherit `Script`, `EnvReads` or `InstanceAware`, and a
 * guard that had to change fifty inheritance lines would have been a refactor wearing a fix's clothes.
 */
library EnvCell {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev `envCell` if the record at `recordPath` is absent or names the same cell; otherwise REVERTS.
    function agreeing(address envCell, string memory recordPath) internal view returns (address) {
        return agreeingAt(envCell, recordPath, ".AuditCell", "AUDIT_CELL");
    }

    /// @dev The same rule for every other address override that falls back to the record - `CELL_TOKEN` against
    ///      `.CellToken`, `ISSUANCE_MODULE` against `.IssuanceModule`, and so on. A token or module override that
    ///      disagrees with the record is the mix from the other side: a record-sourced cell beside another
    ///      instance's token or module.
    function agreeingAt(address envAddr, string memory recordPath, string memory jsonKey, string memory envName)
        internal
        view
        returns (address)
    {
        if (!VM.exists(recordPath)) return envAddr;
        return requireSameAt(envAddr, VM.parseJsonAddress(VM.readFile(recordPath), jsonKey), recordPath, jsonKey, envName);
    }

    function requireSame(address envCell, address recordCell, string memory recordPath)
        internal
        pure
        returns (address)
    {
        return requireSameAt(envCell, recordCell, recordPath, ".AuditCell", "AUDIT_CELL");
    }

    function requireSameAt(
        address envAddr,
        address recordAddr,
        string memory recordPath,
        string memory jsonKey,
        string memory envName
    ) internal pure returns (address) {
        require(
            envAddr == recordAddr,
            string.concat(
                envName, " names an address the deployment record ", recordPath, " does not hold at ", jsonKey,
                ", so this script would mix it with addresses of a different instance read from that record. Unset ",
                envName, ", or run against the record that names it (DEPLOY_INSTANCE_LABEL where the script supports one)."
            )
        );
        return envAddr;
    }
}

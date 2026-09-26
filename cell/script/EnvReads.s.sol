// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Script.sol";

/**
 * EnvReads — the one place this repo reads an env var that is not a string.
 *
 * ─── WHY THIS EXISTS AS ITS OWN BASE ───────────────────────────────────────────────────────────
 * `vm.envOr` returns its DEFAULT when the variable is SET BUT UNPARSEABLE. Absence and garbage are
 * the same answer, silently. This repo has paid for that twice and nearly a third time:
 *
 *   - `vm.envOr(..., uint256(22979))` shipped `84532-rung1.json` with a size for a 24,522-byte
 *     contract, because `forge build --sizes` printed "24,522" and the comma made the parse fail.
 *   - `vm.envOr(..., false)` parses only "true"/"false", so it silently dropped the `=1` that a
 *     guard's own revert message instructed the operator to set.
 *   - `bug_002` (DEC-44's paid review, 2026-09-08): `SPEC_CHALLENGE_FEE` in the cell's own deploy
 *     script, with both guards below it structurally blind — a read-back compares the deployed value
 *     to the variable it was read from, which is the default compared with itself.
 *
 * The cure was written down in `DeployMembrane.s.sol`'s header in July, declared mandatory, and
 * implemented as private helpers ON A CONTRACT NINE OTHER SCRIPTS INHERIT FROM — where it stayed
 * reachable by exactly one of them. `GenesisBootstrapProtocol`, two files away on the canonical
 * deploy path, read `GENESIS_BOUNTY` with the raw call that header condemns (PC-67). A rule written
 * down and then scoped to the file that wrote it is not a rule.
 *
 * So the helpers live here, on a base that carries NOTHING ELSE. That is the whole design decision:
 * `InstanceAware` would have been the obvious home and it is the wrong one, because it also builds
 * deployment-record paths and its own header says those must stay in agreement with `DeployCell`'s —
 * so inheriting it to get an env helper drags a path-builder along, and `DeployCell` could not take
 * it. A base with one job can be inherited by anything.
 *
 * ─── THE RULE ──────────────────────────────────────────────────────────────────────────────────
 * ABSENCE IS A DECISION; UNPARSEABLE IS AN ERROR. Read the string first; an empty string is absence
 * and takes the default; anything else is parsed with the LOUD variant, which reverts on garbage.
 *
 * `vm.envUint` DOES understand Solidity's unit suffixes — `10 ether` is 10e18, `10 gwei` is 1e10 —
 * measured 2026-09-11, so a `.env` may write them safely. Only genuine garbage reverts.
 */
abstract contract EnvReads is Script {
    /// @dev Absent -> the stated default. Present-but-garbage -> loud revert.
    function _optionalUint(string memory key, uint256 dflt) internal view returns (uint256) {
        if (bytes(vm.envOr(key, string(""))).length == 0) return dflt;
        return vm.envUint(key);
    }

    /// @dev Absent is an ERROR here; garbage is an error everywhere. Kept beside `_optionalUint`
    ///      rather than in a caller: a base that offers one of the pair invites the caller to
    ///      hand-roll the other, which is how this class spread in the first place.
    function _requiredUint(string memory key) internal view returns (uint256) {
        require(bytes(vm.envOr(key, string(""))).length > 0, string.concat(key, " is required (unset)"));
        return vm.envUint(key);
    }

    /// @dev Same rule for addresses, and it is not hypothetical: a mistyped address env var silently
    ///      becomes whatever constant the call site passed as its default, and an address default is
    ///      usually a REAL account someone funded once.
    function _optionalAddress(string memory key, address dflt) internal view returns (address) {
        if (bytes(vm.envOr(key, string(""))).length == 0) return dflt;
        return vm.envAddress(key);
    }
}

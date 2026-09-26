// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import {InstanceAware} from "../script/InstanceAware.s.sol";

/*
 * PC-67 — bug_002's defect, fixed in the file the review named and alive on the shared base.
 *
 * `GenesisBootstrapProtocol.s.sol` reads `GENESIS_BOUNTY` and runs on the canonical deploy path
 * immediately after `DeployCell` — it wrote `genesis-84532-rung20.json` this week. `vm.envOr`
 * returns its DEFAULT when a variable is set but unparseable, so a malformed value there silently
 * deploys the 5,000 anchor the entire economic model is calibrated on, with every guard below it as
 * blind as the ones D15.1 measured: a read-back compares the deployed value to the variable it was
 * read from, which is the default compared with itself.
 *
 * The helper lives on `InstanceAware` because ten scripts inherit it. `DeployCell` and
 * `DeployMembrane` keep their own copies; collapsing all three needs `DeployCell`'s inheritance to
 * change, and that file's sibling header says the two path-builders must stay in agreement — a
 * separate move, and not one for the sitting before a §0 run.
 *
 * ONE KEY PER TEST, for the reason `DeployCellEnvReads.t.sol` measured: Foundry resolves an env key
 * ONCE per process, so a key read while unset stays pinned to ABSENT for the whole run and every
 * later `vm.setEnv` on it is invisible.
 */
contract InstanceAwareProbe is InstanceAware {
    function optionalUint(string memory key, uint256 dflt) external view returns (uint256) {
        return _optionalUint(key, dflt);
    }
}

contract InstanceAwareEnvReadsTest is Test {
    InstanceAwareProbe probe;

    function setUp() public {
        probe = new InstanceAwareProbe();
    }

    // ─── absence is a decision ───────────────────────────────────────────────

    function test_absent_takes_the_default() public view {
        assertEq(probe.optionalUint("PC67_NEVER_SET", 4242), 4242,
                 "an ABSENT variable must still take the default");
    }

    function test_empty_counts_as_absent() public {
        vm.setEnv("PC67_EMPTY", "");
        assertEq(probe.optionalUint("PC67_EMPTY", 5000 ether), 5000 ether,
                 "an empty value is absence, not garbage");
    }

    function test_well_formed_value_beats_the_default() public {
        vm.setEnv("PC67_PLAIN", "4096");
        assertEq(probe.optionalUint("PC67_PLAIN", 4242), 4096,
                 "a well-formed value must beat the default");
    }

    function test_unit_suffix_is_parsed_at_its_own_scale() public {
        // Measured in bug_002's tests: envUint understands Solidity's unit suffixes, so a .env may
        // safely write `GENESIS_BOUNTY=5000 ether` and mean 5000e18 rather than 5000 wei.
        vm.setEnv("PC67_UNITS", "5000 ether");
        assertEq(probe.optionalUint("PC67_UNITS", 1 ether), 5000 ether,
                 "5000 ether is 5000e18 - not truncated to 5000, not defaulted");
    }

    // ─── unparseable is an error ─────────────────────────────────────────────

    function test_thousands_comma_REVERTS() public {
        vm.setEnv("PC67_COMMA", "5,000");
        vm.expectRevert();
        probe.optionalUint("PC67_COMMA", 5000 ether);
    }

    function test_quoted_REVERTS() public {
        vm.setEnv("PC67_QUOTED", "\"5000\"");
        vm.expectRevert();
        probe.optionalUint("PC67_QUOTED", 5000 ether);
    }

    function test_decimal_REVERTS() public {
        vm.setEnv("PC67_DECIMAL", "5000.5");
        vm.expectRevert();
        probe.optionalUint("PC67_DECIMAL", 5000 ether);
    }

    function test_prose_REVERTS() public {
        vm.setEnv("PC67_PROSE", "default");
        vm.expectRevert();
        probe.optionalUint("PC67_PROSE", 5000 ether);
    }

    // ─── the parameter this row exists for, by its own name ──────────────────

    function test_GENESIS_BOUNTY_malformed_REVERTS_rather_than_deploying_the_anchor() public {
        vm.setEnv("GENESIS_BOUNTY", "5,000 ether");
        vm.expectRevert();
        probe.optionalUint("GENESIS_BOUNTY", 5000 ether);
    }

    function test_GENESIS_SALT_malformed_REVERTS() public {
        vm.setEnv("GENESIS_SALT", "one");
        vm.expectRevert();
        probe.optionalUint("GENESIS_SALT", 1);
    }
}

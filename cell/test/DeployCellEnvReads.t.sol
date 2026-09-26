// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import {DeployCell} from "../script/DeployCell.s.sol";

/*
 * bug_002 — the 22979 family in the cell's own deploy script (DEC-44's paid review, 2026-09-08;
 * proposal `body/proposals/deploycell-envor-silent-default-proposal.txt`).
 *
 * `vm.envOr` returns its DEFAULT when the variable is SET BUT UNPARSEABLE. This repo has already
 * paid for that once — `84532-rung1.json` shipped `auditCellRuntimeBytes: 22979` for a 24,522-byte
 * contract, because `forge build --sizes` printed "24,522" and the comma made the parse fail.
 *
 * THE ACCEPTANCE IS BOTH DIRECTIONS, and the proposal says the red one is the point: a
 * set-but-unparseable value must REVERT, and an unset one must still take the default. The
 * current behaviour passes every existing test, which is exactly why this file was written before
 * the fix rather than after it.
 *
 * WHY THE TESTS TARGET A HELPER RATHER THAN `run()`. The three numeric reads were inline in
 * `run()`, which cannot be exercised without a full deploy. Extracting them into one
 * `_optionalUint` is behaviour-preserving by itself — the extraction landed carrying the defect,
 * these tests went RED against it, and only then did the body change. The helper is also the fix's
 * real shape: the defect is the PATTERN, so it gets ONE home rather than three patched call sites.
 *
 * ─── ONE KEY PER TEST, AND THE REASON IS MEASURED ──────────────────────────────────────────────
 * Every test below reads a key NOTHING else reads, and sets it before the first read of that key.
 * The first writing of this file shared one key across all of them and cleared it in `setUp()`,
 * and two tests then failed on a PERFECTLY WELL-FORMED value: `"12345"` read back as the default
 * `4242`. Foundry resolves an env key ONCE per process and reuses that resolution — so `setUp()`
 * reading the shared key while it was empty pinned it to ABSENT for the whole run, and every later
 * `vm.setEnv` on it was invisible. That is why the sibling test expecting the DEFAULT still passed:
 * a pinned-absent key returns whatever default each call supplies.
 *
 * It is a harness artifact, not a second production defect — `run()` reads each key once, in one
 * process, with the environment already set. But it is the second silent-default mechanism this
 * file has met in an afternoon, and an unexplained green here would be worth nothing.
 * (A `view` probe was suspected first and MEASURED NOT to be the cause: making the wrapper
 * non-view changed no result.)
 */
contract DeployCellEnvProbe is DeployCell {
    function optionalUint(string memory key, uint256 dflt) external view returns (uint256) {
        return _optionalUint(key, dflt);
    }
}

contract DeployCellEnvReadsTest is Test {
    DeployCellEnvProbe probe;

    function setUp() public {
        probe = new DeployCellEnvProbe();
        // NOTHING is read or cleared here on purpose — see the header. Touching a key in setUp
        // pins its resolution for the whole process.
    }

    // ─── GREEN DIRECTION: absence is a decision ──────────────────────────────

    function test_absent_takes_the_default() public view {
        assertEq(
            probe.optionalUint("BUG002_NEVER_SET_ANYWHERE", 4242),
            4242,
            "an ABSENT variable must still take the default"
        );
    }

    function test_empty_string_counts_as_absent() public {
        vm.setEnv("BUG002_EMPTY", "");
        assertEq(probe.optionalUint("BUG002_EMPTY", 7 ether), 7 ether,
                 "an empty value is absence, not garbage");
    }

    function test_set_and_parseable_takes_the_value_not_the_default() public {
        vm.setEnv("BUG002_PLAIN", "12345");
        assertEq(probe.optionalUint("BUG002_PLAIN", 4242), 12345,
                 "a well-formed value must beat the default");
    }

    function test_set_and_parseable_wei_scale_value() public {
        vm.setEnv("BUG002_WEI", "10000000000000000000");
        assertEq(probe.optionalUint("BUG002_WEI", 1 ether), 10 ether,
                 "wei-scale values must survive the read");
    }

    // ─── RED DIRECTION: unparseable is an error ──────────────────────────────
    // Every one of these returned the DEFAULT before the fix — silently, with each guard
    // downstream still green, because a read-back compares the deployed value to the variable it
    // was read from, and so compares the default to itself.

    function test_thousands_comma_REVERTS_rather_than_defaulting() public {
        vm.setEnv("BUG002_COMMA", "24,522");           // the literal 22979 bug's input
        vm.expectRevert();
        probe.optionalUint("BUG002_COMMA", 4242);
    }

    // NOT a revert case, and this one was written as a revert first and MEASURED wrong.
    // `vm.envUint` understands Solidity's unit suffixes: "10 ether" -> 10e18, "10 gwei" -> 1e10,
    // "10 wei" -> 10, "10ether" -> 10e18, and only genuine prose ("10 potato") reverts. So an
    // operator who writes `SPEC_CHALLENGE_FEE=10 ether` in a .env gets exactly what they meant.
    // Pinned as a GREEN because the assumption that it was garbage is the easy one to make twice,
    // and because it is the difference between a fee of 10 wei and a fee of 10 ether.
    function test_unit_suffix_is_PARSED_not_defaulted_and_not_truncated() public {
        vm.setEnv("BUG002_UNIT", "10 ether");
        assertEq(probe.optionalUint("BUG002_UNIT", 4242), 10 ether,
                 "a unit suffix is understood by envUint - not truncated to 10, not defaulted");
    }

    function test_gwei_suffix_is_parsed_at_its_own_scale() public {
        vm.setEnv("BUG002_GWEI", "10 gwei");
        assertEq(probe.optionalUint("BUG002_GWEI", 4242), 10 gwei, "10 gwei is 1e10, not 10");
    }

    function test_quoted_value_REVERTS_rather_than_defaulting() public {
        vm.setEnv("BUG002_QUOTED", "\"100\"");         // quotes survive some .env loaders
        vm.expectRevert();
        probe.optionalUint("BUG002_QUOTED", 4242);
    }

    function test_decimal_REVERTS_rather_than_defaulting() public {
        vm.setEnv("BUG002_DECIMAL", "1.5");
        vm.expectRevert();
        probe.optionalUint("BUG002_DECIMAL", 4242);
    }

    function test_prose_REVERTS_rather_than_defaulting() public {
        vm.setEnv("BUG002_PROSE", "default");
        vm.expectRevert();
        probe.optionalUint("BUG002_PROSE", 4242);
    }

    function test_negative_REVERTS_rather_than_defaulting() public {
        vm.setEnv("BUG002_NEGATIVE", "-1");
        vm.expectRevert();
        probe.optionalUint("BUG002_NEGATIVE", 4242);
    }

    // ─── THE NAMED CALL SITE, tied to the finding by its own key ─────────────
    // The helper is shared, so the tests above already cover GENESIS_MINT and CLAIM_FILING_STAKE.
    // This pair uses the key the review actually named, so a reader grepping `SPEC_CHALLENGE_FEE`
    // lands on a test and not only on the script. They read DIFFERENT keys for the reason in the
    // header — the real key is read by the malformed case, and the default case uses a name that
    // is never set, which is what "unset" means on a deploy host anyway.

    function test_SPEC_CHALLENGE_FEE_malformed_REVERTS() public {
        vm.setEnv("SPEC_CHALLENGE_FEE", "10,000");
        vm.expectRevert();
        probe.optionalUint("SPEC_CHALLENGE_FEE", 10 ether);
    }

    function test_spec_challenge_fee_unset_still_takes_its_default() public view {
        assertEq(
            probe.optionalUint("SPEC_CHALLENGE_FEE_UNSET_PROBE", 10 ether),
            10 ether,
            "the fix must not make an unset fee fail the deploy - VD-107's default still stands"
        );
    }
}

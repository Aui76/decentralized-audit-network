// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import {DeployCell} from "../script/DeployCell.s.sol";

/*
 * PC-55 — the §0 dry-run overwrites a TRACKED deployment record and the runbook's printed command
 * degraded that record's provenance to "unknown".
 *
 * `cell/deployments/84532-preflight.dryrun.json` was untracked by design when the label defense was
 * written; `78592d7` (2026-09-03) tracked it, and the sentence saying otherwise retired itself.
 * `_writeDeployment`'s overwrite guard is conditioned on `ScriptBroadcast || ScriptResume`, so it
 * NEVER evaluates on the dry-run leg — `vm.writeJson` simply runs. MEASURED 2026-09-08: the first §0
 * leg took R10 from `60 pinned / 5 declared-unknown` to `59 / 6`, writing "unknown" over
 * `78c7282d…`. It was restored in the same sitting because somebody was watching R10, not because
 * anything caught it.
 *
 * THE GUARD IS DELIBERATELY NARROW, and these tests are mostly about what it must NOT block. A dry
 * run has every right to rewrite its own record — that is the file's whole job — so a blanket
 * overwrite guard would be the wrong fix and would break the §0 leg it is meant to protect. The one
 * thing refused is replacing a head the repo already recorded with the string "unknown": a silent
 * deletion of provenance by the gate whose subject is provenance.
 *
 * Written before the fix. The seam landed as a no-op first so these could go red against real code.
 */
contract DeployCellProvenanceProbe is DeployCell {
    function requireProvenanceNotDowngraded(string memory path, string memory gitHead) external view {
        _requireProvenanceNotDowngraded(path, gitHead);
    }
}

contract DeployCellProvenanceGuardTest is Test {
    DeployCellProvenanceProbe probe;

    string constant REAL_HEAD = "78c7282d1f0a4c5b6e7d8a9b0c1d2e3f40516273";

    function setUp() public {
        probe = new DeployCellProvenanceProbe();
        // The public export carries no cell/deployments/ (the records live in the private tree), and a
        // fresh clone of it failed all seven tests on writeFile (2026-09-26). The folder is the test's
        // own precondition, so the test makes it; a no-op where it exists.
        vm.createDir("deployments", true);
    }

    // `fs_permissions` grants read-write on ./deployments only, so the fixtures live there under a
    // name nothing else uses, and every test removes its own before and after.
    function _path(string memory tag) internal pure returns (string memory) {
        return string.concat("deployments/pc55-probe-", tag, ".json");
    }

    function _writeRecord(string memory tag, string memory head) internal returns (string memory p) {
        p = _path(tag);
        if (vm.exists(p)) vm.removeFile(p);
        vm.writeFile(p, string.concat('{"chainId":31337,"sourceGitHead":"', head, '"}'));
    }

    function _writeRecordWithoutHead(string memory tag) internal returns (string memory p) {
        p = _path(tag);
        if (vm.exists(p)) vm.removeFile(p);
        vm.writeFile(p, '{"chainId":31337}');
    }

    // ─── THE REFUSAL: provenance may not be silently deleted ─────────────────

    function test_unknown_over_a_recorded_head_REVERTS() public {
        string memory p = _writeRecord("downgrade", REAL_HEAD);
        vm.expectRevert();
        probe.requireProvenanceNotDowngraded(p, "unknown");
        vm.removeFile(p);
    }

    // ─── WHAT IT MUST NOT BLOCK, which is most of the behaviour ──────────────

    function test_a_real_head_over_a_recorded_head_is_allowed() public {
        string memory p = _writeRecord("advance", REAL_HEAD);
        probe.requireProvenanceNotDowngraded(p, "1266538651");   // the ordinary case: §0 re-runs
        vm.removeFile(p);
    }

    function test_a_real_head_over_unknown_is_allowed_it_is_a_repair() public {
        string memory p = _writeRecord("repair", "unknown");
        probe.requireProvenanceNotDowngraded(p, REAL_HEAD);
        vm.removeFile(p);
    }

    function test_unknown_over_unknown_is_allowed_nothing_is_lost() public {
        string memory p = _writeRecord("noop", "unknown");
        probe.requireProvenanceNotDowngraded(p, "unknown");
        vm.removeFile(p);
    }

    function test_unknown_onto_a_record_with_no_head_field_is_allowed() public {
        string memory p = _writeRecordWithoutHead("nofield");
        probe.requireProvenanceNotDowngraded(p, "unknown");
        vm.removeFile(p);
    }

    function test_unknown_onto_a_file_that_does_not_exist_is_allowed() public view {
        // A FIRST deploy has nothing to lose. The guard is about deletion, not about requiring a stamp.
        probe.requireProvenanceNotDowngraded("deployments/pc55-probe-absent.json", "unknown");
    }

    function test_unknown_over_an_empty_head_string_is_allowed() public {
        string memory p = _writeRecord("emptyhead", "");
        probe.requireProvenanceNotDowngraded(p, "unknown");
        vm.removeFile(p);
    }

    // ─── The measured incident, replayed ─────────────────────────────────────

    function test_the_2026_09_08_incident_is_refused_by_name() public {
        // R10 went 60 pinned / 5 declared-unknown to 59 / 6 on exactly this write.
        string memory p = _writeRecord("incident", "78c7282d");
        vm.expectRevert();
        probe.requireProvenanceNotDowngraded(p, "unknown");
        vm.removeFile(p);
    }
}

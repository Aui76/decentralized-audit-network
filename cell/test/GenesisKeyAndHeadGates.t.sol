// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "./helpers/CellTestDeploy.sol";
import "../script/GenesisAuditorKey.sol";
import "../script/GenesisBootstrapRegister.s.sol";
import {DeployCell} from "../script/DeployCell.s.sol";

contract AuditorKeyProbe {
    function resolve(bool hasAuditorKey, uint256 auditorKey, bool hasDeployerKey, uint256 deployerKey)
        external
        pure
        returns (uint256)
    {
        return GenesisAuditorKey.resolve(hasAuditorKey, auditorKey, hasDeployerKey, deployerKey);
    }
}

contract RegisterGate is GenesisBootstrapRegister {
    function check(AuditCell cell) external view {
        _checkRegisterReady(cell);
    }
}

contract HeadProbe is DeployCell {
    function check(string memory gitHead, bool broadcasting, uint256 chainId) external pure {
        _requireRealHeadOnBroadcast(gitHead, broadcasting, chainId);
    }
}

/// @notice The three script-only findings left open after the 2026-09-15 reviews, fixed the same night on the
///         operator's word ("fix those three tonight"):
///         PC-86 - both genesis auditor scripts fell back to the DEPLOYER's key when AUDITOR_PRIVATE_KEY was absent;
///         PC-85 - GenesisBootstrapRegister broadcast `register()` and only then noticed position 1 was already taken;
///         PC-55 - a FIRST broadcast of DeployCell recorded `sourceGitHead = "unknown"` on a real chain.
///         Written against no-op seams first; every REFUSES case was red there.
contract GenesisKeyAndHeadGatesTest is Test {
    AuditorKeyProbe keys;
    RegisterGate reg;
    HeadProbe head;
    CellTestDeploy.Deployment d;

    uint256 constant AUDITOR_PK = 0xA11CE;
    uint256 constant DEPLOYER_PK = 0xDE9107;
    string constant REAL_HEAD = "78c7282d1f0a4c5b6e7d8a9b0c1d2e3f40516273";

    function setUp() public {
        keys = new AuditorKeyProbe();
        reg = new RegisterGate();
        head = new HeadProbe();
        d = CellTestDeploy.deploy(address(this));
    }

    // ---- PC-86: the auditor key ----

    function test_auditor_key_is_used_when_set() public {
        assertEq(keys.resolve(true, AUDITOR_PK, true, DEPLOYER_PK), AUDITOR_PK);
        assertEq(keys.resolve(true, AUDITOR_PK, false, 0), AUDITOR_PK, "no deployer key in the env is fine");
    }

    function test_auditor_key_REFUSES_to_fall_back_to_the_deployer_key() public {
        vm.expectRevert(bytes("AUDITOR_PRIVATE_KEY is required - it no longer falls back to PRIVATE_KEY (PC-86)"));
        keys.resolve(false, 0, true, DEPLOYER_PK);
    }

    function test_auditor_key_REFUSES_when_it_is_the_deployer() public {
        vm.expectRevert(bytes("AUDITOR_PRIVATE_KEY names the deployer - the genesis protocol cannot audit itself (PC-86)"));
        keys.resolve(true, DEPLOYER_PK, true, DEPLOYER_PK);
    }

    // ---- PC-85: position 1 before broadcast ----

    function test_register_passes_on_a_fresh_genesis_cell() public view {
        assertEq(d.cell.auditorCount(), 0, "precondition: nobody registered");
        reg.check(d.cell);
    }

    function test_register_REFUSES_when_position_1_is_already_taken() public {
        vm.prank(address(0x5712A)); // a stranger takes the free position 1
        d.cell.register();
        assertEq(d.cell.auditorCount(), 1);
        vm.expectRevert(bytes("position 1 is already taken - registering now lands this auditor at position 2 (PC-85)"));
        reg.check(d.cell);
    }

    // ---- PC-55: a real head on a real broadcast ----

    function test_head_real_head_broadcast_passes() public view {
        head.check(REAL_HEAD, true, 84532);
    }

    function test_head_unknown_is_fine_off_broadcast_and_on_the_local_chain() public view {
        head.check("unknown", false, 84532); // the dry-run leg stays free (PC-55's reason)
        head.check("unknown", true, 31337); // the sim's anvil
    }

    function test_head_REFUSES_unknown_on_a_real_broadcast() public {
        vm.expectRevert(bytes(
            "DeployCell: a broadcast to a real chain needs SOURCE_GIT_HEAD (PC-55) - source script/export-stamp.sh first"
        ));
        head.check("unknown", true, 84532);
    }

    function test_head_REFUSES_an_empty_head_on_a_real_broadcast() public {
        vm.expectRevert(bytes(
            "DeployCell: a broadcast to a real chain needs SOURCE_GIT_HEAD (PC-55) - source script/export-stamp.sh first"
        ));
        head.check("", true, 8453);
    }
}

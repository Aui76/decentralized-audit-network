// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "./helpers/CellTestDeploy.sol";
import "../script/LockMinter.s.sol";
import "../script/GenesisBootstrapAuditor.s.sol";

contract LockMinterGate is LockMinter {
    function check(CellToken token, address expectedMinter, bool genesisPending) external view {
        _checkMintLockReady(token, expectedMinter, genesisPending);
    }
}

contract GenesisAuditorGate is GenesisBootstrapAuditor {
    function check(AuditCell cell, uint256 id, address auditor) external view {
        _checkGenesisBinding(cell, id, auditor);
    }
}

contract GateTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice Two script gates from the 2026-09-15 second-family review of the remaining scope (VD-181), applied with the
///         stamp scripts on the operator's word.
///         (1) LockMinter checked only `!minterLocked` and `totalSupply > 0` - never that the minter it locks forever is the
///             recorded IssuanceModule, so a minter re-pointed between DeployCell and this step was locked in with
///             inflation authority; and `totalSupply > 0` is true after a GENESIS_MINT premint that proves no genesis.
///         (2) GenesisBootstrapAuditor bound only `auditAuditorOf(id) == auditor`, so it would accept-and-pass ANY audit
///             that auditor was assigned as though it were genesis.
contract GenesisLockScriptGatesTest is Test {
    CellTestDeploy.Deployment d;
    LockMinterGate lm;
    GenesisAuditorGate ga;

    address genesisProtocol = address(0xA11CE);
    address genesisAuditor = address(0xB0B);
    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        // G6 (PC-89): the genesis slot belongs to the admin or a genesis protocol the admin names; this fixture's
        // protocol is a separate address, so the admin names it. Encoded, so the file also compiles on pre-G6 bytes.
        (bool named,) = address(d.cell).call(
            abi.encodeWithSignature("setGenesisBootstrap(address,address)", genesisProtocol, address(0))
        );
        named;
        lm = new LockMinterGate();
        ga = new GenesisAuditorGate();
    }

    // ---- LockMinter ----

    function test_lockminter_passes_when_minter_is_the_recorded_issuance_and_genesis_is_done() public {
        d.token.genesisMint(address(0xFEED), 1 ether);
        CellTestDeploy.attachMinter(d); // minter = issuance
        lm.check(d.token, address(d.issuance), false);
    }

    /// RED before the fix: a minter that is NOT the recorded issuance module passed.
    function test_lockminter_REFUSES_a_minter_that_is_not_the_recorded_issuance() public {
        d.token.genesisMint(address(0xFEED), 1 ether);
        d.token.setMinter(address(0xBAD));
        vm.expectRevert();
        lm.check(d.token, address(d.issuance), false);
    }

    /// RED before the fix: a premint makes totalSupply > 0 while genesis is still pending.
    function test_lockminter_REFUSES_while_genesis_is_pending_even_after_a_premint() public {
        d.token.genesisMint(address(0xFEED), 1 ether);
        CellTestDeploy.attachMinter(d);
        vm.expectRevert();
        lm.check(d.token, address(d.issuance), true);
    }

    // ---- GenesisBootstrapAuditor ----

    function _submitOrdinary() internal returns (uint256 id) {
        GateTarget t = new GateTarget(7);
        d.token.genesisMint(genesisProtocol, 1_000 ether);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        vm.prank(genesisAuditor);
        d.cell.register();
        vm.prank(genesisProtocol);
        d.token.approve(address(d.cell), 40 ether);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(genesisProtocol);
        id = d.cell.submitAudit(address(t), address(t).codehash, keccak256("spec.v1"), specToolId, keccak256(""), 40 ether, declared, 0, 0);
    }

    /// RED before the fix: an ORDINARY audit assigned to the genesis auditor passed the "genesis" gate.
    function test_genesis_auditor_REFUSES_an_ordinary_audit_while_no_genesis_audit_is_open() public {
        uint256 id = _submitOrdinary();
        assertEq(d.cell.auditAuditorOf(id), genesisAuditor, "precondition: assigned to the genesis auditor");
        assertFalse(d.cell.genesisAuditOpen(), "precondition: no genesis audit is open");
        vm.expectRevert();
        ga.check(d.cell, id, genesisAuditor);
    }

    function test_genesis_auditor_passes_the_open_genesis_audit() public {
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        vm.prank(genesisAuditor);
        d.cell.register();
        GateTarget t = new GateTarget(9);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(genesisProtocol);
        uint256 id = d.cell.submitGenesisAudit(address(t), address(t).codehash, keccak256("spec.v1"), specToolId, keccak256(""), 5000 ether, declared, 0, 0);
        assertTrue(d.cell.genesisAuditOpen());
        assertEq(d.cell.genesisAuditId(), id);
        assertEq(d.cell.auditAuditorOf(id), genesisAuditor, "the genesis auditor is assigned");
        ga.check(d.cell, id, genesisAuditor);
    }
}

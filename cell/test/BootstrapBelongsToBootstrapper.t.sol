// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./helpers/SpecValidationCellSetup.sol";

contract BootTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice The hull window's G6 (walkthrough section 3, invariant I6: BOOTSTRAP SLOTS BELONG TO THE BOOTSTRAPPER - a one-shot
///         slot opened at deploy is claimable only by the address the deploy named).
///
///         PC-89: `submitGenesisAudit` had no caller check, so a stranger holding nothing took the one-shot genesis slot. Now
///         CLOSED BY DEFAULT: only the admin, or a genesis protocol the admin names, may submit it - no setter call is needed
///         for the gate to hold from the deploy block on.
///         PC-85 (hull half): genesis auditor position 1 cost nothing to anyone, so a stranger could register first and be
///         drawn for the genesis audit. Now the admin may NAME the genesis auditor, and while genesis is pending the first
///         registration must be that address. Opt-in, because every test and the canonical ladder register their first
///         auditor freely; `DeployCell` names it in the deploy's own broadcast - in the transaction AFTER the cell's
///         creation, so the seat closes at the naming transaction, not the deploy block (VD-233(1)); naming after
///         anyone registered reverts, so a lost race is loud. Only the PC-89 half holds from the deploy block.
///
///         New entry points and errors are reached through encoded signatures, so this file compiles, and goes RED, on the
///         pre-G6 bytes.
contract BootstrapBelongsToBootstrapperTest is SpecValidationCellSetup {
    CellTestDeploy.Deployment d;
    CellToken token;
    AuditCell cell;

    address namedProtocol = address(0xBEEF);
    address namedAuditor = address(0xA11CE);
    address stranger = address(0x5712A);

    bytes32 specToolId = keccak256("spec-tool");
    bytes32 verdictToolId = keccak256("audit-tool");
    bytes32 specHash = keccak256("spec-hash");

    function setUp() external {
        d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        CellTestDeploy.attachMinter(d);
    }

    function _declared() internal view returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = verdictToolId;
    }

    function _name(address protocol_, address auditor_) internal returns (bool ok) {
        (ok,) = address(cell).call(abi.encodeWithSignature("setGenesisBootstrap(address,address)", protocol_, auditor_));
    }

    function _submitGenesisAs(address who, uint256 salt) internal returns (bool ok) {
        BootTarget t = new BootTarget(salt);
        vm.prank(who);
        (ok,) = address(cell).call(
            abi.encodeCall(
                cell.submitGenesisAudit,
                (address(t), address(t).codehash, specHash, specToolId, EMPTY_SPEC_ERRORS, 5000 ether, _declared(), 0, 0)
            )
        );
    }

    // ------------------------------------------------------------------ PC-89: closed by default

    /// With NOTHING named, the slot is already closed to a stranger - the gate does not wait for a setter call, so there is
    /// no window between the deploy and a setter for anyone to race.
    function test_G6_the_genesis_slot_is_closed_to_a_stranger_from_the_deploy_block() public {
        assertFalse(_submitGenesisAs(stranger, 1), "a stranger may not take the one-shot slot");
        assertFalse(cell.genesisAuditOpen(), "the slot is still open for its owner");
        assertTrue(_submitGenesisAs(address(this), 2), "the admin - the deployer - may");
        assertTrue(cell.genesisAuditOpen());
    }

    function test_G6_a_named_genesis_protocol_may_take_the_slot_and_nobody_else() public {
        assertTrue(_name(namedProtocol, address(0)), "the admin names the genesis protocol");
        assertFalse(_submitGenesisAs(stranger, 1), "a stranger still may not");
        assertTrue(_submitGenesisAs(namedProtocol, 2), "the named protocol may");
        assertEq(cell.auditProtocolOf(cell.genesisAuditId()), namedProtocol);
    }

    function test_G6_only_the_admin_names_the_bootstrap_and_only_while_genesis_is_untaken() public {
        vm.prank(stranger);
        (bool ok,) = address(cell).call(
            abi.encodeWithSignature("setGenesisBootstrap(address,address)", stranger, stranger)
        );
        assertFalse(ok, "a stranger cannot name itself");
        assertTrue(_submitGenesisAs(address(this), 1));
        assertFalse(_name(namedProtocol, address(0)), "no renaming once the genesis audit is open");
    }

    // ------------------------------------------------------------------ PC-85: position 1 belongs to the named auditor

    function test_G6_position_one_belongs_to_the_named_genesis_auditor() public {
        assertTrue(_name(address(0), namedAuditor), "the admin names the genesis auditor before anyone registers");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("NotGenesisAuditor()"));
        cell.register(); // the free first seat is not free to a squatter

        vm.prank(namedAuditor);
        cell.register();
        (,,, uint256 position,,) = cell.auditors(namedAuditor);
        assertEq(position, 1, "the named auditor is auditor #1");

        vm.prank(stranger);
        cell.register(); // position 1 is taken by its owner; everyone else joins as before
        (,,, uint256 p2,,) = cell.auditors(stranger);
        assertEq(p2, 2);
    }

    function test_G6_the_genesis_auditor_cannot_be_named_after_someone_registered() public {
        vm.prank(stranger);
        cell.register();
        assertFalse(_name(address(0), namedAuditor), "naming now cannot evict the auditor already at position 1");
    }
}

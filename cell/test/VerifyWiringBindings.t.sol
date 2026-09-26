// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "./helpers/CellTestDeploy.sol";
import "../script/VerifyWiring.s.sol";

contract VerifyWiringHarness is VerifyWiring {
    function moduleBindingFails(Wiring memory w) external view returns (uint256) {
        return _moduleBindingFails(w);
    }
}

/// @notice bug_017 of the 2026-09-15 second-family review of the fresh scope (VD-180; record
///         OnAir/records/REVIEW-2026-09-15-cursor-cli-gpt56sol-fresh-scope.md): VerifyWiring compared the module-to-module
///         wires but none of the HOST bindings - `issuance.cell`, `issuance.token`, each satellite's `cell`, the escrow's
///         `network` / `issuanceModule` / `structuralUpgradeModule` - while every `lockWiring` accepts a non-zero wrong
///         address. So a satellite pointed at the wrong cell printed "SAFE TO PROCEED TO lockWiring()" and then froze.
///         Each mis-wire below must be COUNTED by the read-back before any lock is armed.
contract VerifyWiringBindingsTest is Test {
    CellTestDeploy.Deployment d;
    VerifyWiringHarness vw;
    address wrong = address(0xBAD);

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        vw = new VerifyWiringHarness();
    }

    function _w() internal view returns (VerifyWiring.Wiring memory) {
        return VerifyWiring.Wiring({
            cell: address(d.cell),
            token: address(d.token),
            escrow: address(d.escrow),
            issuance: address(d.issuance),
            claimModule: address(d.claimModule),
            fmeaRegistry: address(d.fmeaRegistry),
            integrityReview: address(d.integrityReviewModule),
            specArbiter: address(d.specArbiterModule),
            structuralUpgrade: address(d.structuralUpgradeModule),
            specGap: address(d.specGapModule),
            assignment: address(d.assignmentModule)
        });
    }

    function test_a_correct_deployment_reads_back_clean() public {
        assertEq(vw.moduleBindingFails(_w()), 0);
    }

    function test_issuance_pointed_at_another_cell_is_counted() public {
        d.issuance.wire(wrong, address(d.token), address(d.escrow));
        assertEq(vw.moduleBindingFails(_w()), 1, "issuance.cell");
    }

    function test_issuance_minting_another_token_is_counted() public {
        d.issuance.wire(address(d.cell), wrong, address(d.escrow));
        assertEq(vw.moduleBindingFails(_w()), 1, "issuance.token");
    }

    function test_each_satellite_pointed_at_another_cell_is_counted() public {
        d.claimModule.wire(wrong);
        d.specGapModule.wire(wrong);
        d.specArbiterModule.wire(wrong);
        d.integrityReviewModule.wire(wrong, address(d.specArbiterModule));
        d.structuralUpgradeModule.wire(wrong, address(d.issuance));
        assertEq(vw.moduleBindingFails(_w()), 5, "claimDispute, specGap, specArbiter, integrityReview, structural .cell");
    }

    /// The escrow's `network` / `issuanceModule` / `structuralUpgradeModule` are set-once and the cell's `token` is
    /// constructor-bound, so those are driven the other way: the SAME deployment read against a record that names a
    /// component of a SECOND, otherwise-correct deployment. Every binding that crosses the two must be counted.
    function test_a_record_naming_another_cell_fails_every_host_binding() public {
        CellTestDeploy.Deployment memory d2 = CellTestDeploy.deploy(address(this));
        VerifyWiring.Wiring memory w = _w();
        w.cell = address(d2.cell);
        // issuance, structuralUpgrade, claimModule, specGap, specArbiter, integrityReview, assignment .cell;
        // escrow.network; cell.token; cell.assignmentModule
        assertEq(vw.moduleBindingFails(w), 10);
    }

    function test_a_record_naming_another_token_fails_every_token_binding() public {
        CellTestDeploy.Deployment memory d2 = CellTestDeploy.deploy(address(this));
        VerifyWiring.Wiring memory w = _w();
        w.token = address(d2.token);
        assertEq(vw.moduleBindingFails(w), 3, "issuance.token, escrow.token, cell.token");
    }

    function test_a_record_naming_another_issuance_fails_its_host_and_escrow_bindings() public {
        CellTestDeploy.Deployment memory d2 = CellTestDeploy.deploy(address(this));
        VerifyWiring.Wiring memory w = _w();
        w.issuance = address(d2.issuance);
        // already asserted: issuance.treasuryEscrow, issuance.structuralModule, structuralUpgrade.issuanceModule;
        // bug_017: issuance.cell, issuance.token, escrow.issuanceModule
        assertEq(vw.moduleBindingFails(w), 6);
    }

    function test_a_record_naming_another_structural_module_fails_its_escrow_binding() public {
        CellTestDeploy.Deployment memory d2 = CellTestDeploy.deploy(address(this));
        VerifyWiring.Wiring memory w = _w();
        w.structuralUpgrade = address(d2.structuralUpgradeModule);
        // already asserted: issuance.structuralModule, structuralUpgrade.issuanceModule;
        // bug_017: structuralUpgrade.cell, escrow.structuralUpgradeModule
        assertEq(vw.moduleBindingFails(w), 4);
    }
}

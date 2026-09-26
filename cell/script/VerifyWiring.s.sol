// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "./InstanceAware.s.sol";

/*
 * Post-deploy wiring read-back (CUTOVER-RUNBOOK.md Phase 4.1, Appendix B).
 *
 * Read-only. No key, no broadcast. Run after DeployCell with:
 *   forge script script/VerifyWiring.s.sol:VerifyWiring --rpc-url base_sepolia
 *
 * SCOPE. Corrected 2026-09-05 (bug_405). This header used to declare SIX wires "NOT observable
 * (no getter, no event)" and defer them to the Phase 5 exercise. Every one of them is declared
 * `address public` in its module, so the compiler generates a getter for each — they were
 * observable the whole time, and the deferral was a claim about the ABI that the ABI contradicts.
 *
 *   Asserted here — cell + token:
 *     cell.treasuryEscrow == escrow      (G-01 mutual bind)
 *     cell.issuanceModule == issuance
 *     cell.claimVerifier  == 0           (declare-only)
 *     token.minter        == issuance
 *     cell.admin          == deployer
 *   Asserted here — the six that were wrongly deferred (`address public`, getter generated):
 *     issuance.treasuryEscrow        == escrow
 *     issuance.structuralModule      == structuralUpgrade
 *     claimModule.fmeaRegistry       == fmeaRegistry
 *     fmeaRegistry.claimModule       == claimModule      (mutual bind)
 *     escrow.integrityReviewModule   == integrityReview
 *     integrityReview.specArbiterModule == specArbiter
 *     structuralUpgrade.issuanceModule  == issuance
 *   Asserted here — the HOST direction, added 2026-09-15 (bug_017, VD-180's record; none were read before, and
 *   every lockWiring accepts a non-zero wrong address):
 *     issuance.cell / .token, structuralUpgrade / claimModule / specGap / specArbiter / integrityReview /
 *     assignment .cell, escrow.network / .token / .issuanceModule / .structuralUpgradeModule,
 *     cell.token, cell.assignmentModule
 *   Pinned by test/VerifyWiringBindings.t.sol against a deliberately mis-wired deployment.
 *
 *   STILL not readable by getter: the cell's dispute modules 0-4 (`L.claimDisputeModule` and
 *   siblings live in CellStorage.Layout and AuditCell exposes no accessor for them). But
 *   `setDisputeModule` DOES emit `DisputeModuleSet(which, m)` (AuditCell.sol :695) — so this
 *   header's own standing recommendation, "if setDisputeModule gains a DisputeModuleSet event,
 *   extend this to read those wires from the deploy receipt logs", has ALREADY been satisfied and
 *   nobody noticed. Reading them from receipt logs is a forge-script limitation, not an ABI one,
 *   and is filed rather than done here.
 *
 *   token.minterLocked is reported (expected false until the post-smoke lockMinter()).
 *
 * WHY THIS MATTERS AT THIS EXACT STEP (bug_405). `lockWiring()` PERMANENTLY freezes `wire()` and
 * `setStructuralModule`, and its precondition used to be weaker than what it freezes. **TWO of the four
 * were CLOSED in the contracts by bug_003 (DEC-44 paid review, VD-143(2)) on 2026-09-10** — the lock now
 * asserts everything it freezes in both:
 *     IssuanceModule          lockWiring checks cell+token+treasuryEscrow+structuralModule  -> 0 unchecked
 *     StructuralUpgradeModule lockWiring checks cell+issuanceModule                         -> 0 unchecked
 *     ClaimDisputeModule      checks cell;  wireFmeaRegistry sets fmeaRegistry              -> 1 unchecked
 *     IntegrityReviewModule   checks cell;  wire() also sets specArbiterModule              -> 1 unchecked
 * So for the remaining TWO a partial §1 reaches §2b with a zero in that slot, `lockWiring()` succeeds,
 * and the slot is frozen at zero forever. The read-back is the only thing standing between that and a
 * permanent deployment — which is why it must not skip the fields the lock does not check. **It still
 * reads all four modules' fields on purpose:** a read-back that narrowed itself to today's gaps would
 * have to be re-widened by whoever next changes a `lockWiring`, and nothing would remind them.
 */

interface IVerifyCell {
    function admin() external view returns (address);
    function token() external view returns (address);
    function assignmentModule() external view returns (address);
    function treasuryEscrow() external view returns (address);
    function issuanceModule() external view returns (address);
    function claimVerifier() external view returns (address);
    function claimVerifierLocked() external view returns (bool);
}

interface IVerifyToken {
    function minter() external view returns (address);
    function minterLocked() external view returns (bool);
}

/* The six wires this script used to call unobservable. Each is `address public` in its module. */
interface IVerifyIssuance {
    function cell() external view returns (address);
    function token() external view returns (address);
    function treasuryEscrow() external view returns (address);
    function structuralModule() external view returns (address);
}

interface IVerifyClaimModule {
    function fmeaRegistry() external view returns (address);
}

interface IVerifyFmea {
    function claimModule() external view returns (address);
}

interface IVerifyEscrow {
    function network() external view returns (address);
    function token() external view returns (address);
    function issuanceModule() external view returns (address);
    function structuralUpgradeModule() external view returns (address);
    function integrityReviewModule() external view returns (address);
}

interface IVerifyIntegrity {
    function specArbiterModule() external view returns (address);
}

interface IVerifyStructural {
    function issuanceModule() external view returns (address);
}

/* bug_017 (2026-09-15, VD-180's record): every satellite's HOST pointer. `address public cell` in each. */
interface IVerifyHosted {
    function cell() external view returns (address);
}

contract VerifyWiring is InstanceAware {
    function run() external view {
        // DEPLOY_INSTANCE_LABEL-aware: a labeled rung verifies ITS record, never the live one.
        string memory path = _deploymentRecordPath();
        console2.log(string.concat("VerifyWiring: reading ", path));
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
        // ADMIN, corrected 2026-09-05 while proving the bug_405 fix against the live cell.
        // This read `cell.admin() == deployer` and FAILED on 84532 - not a wiring defect, a STALE
        // GATE. The live-cell admin was deliberately ROTATED off the exposed deployer key on
        // 2026-08-03 (DEPLOYMENT-LOG.md:309); `deployer` in the record is the address that SENT the
        // deploy and is no longer the admin. So the assertion encoded "admin is whoever deployed",
        // which a deliberate rotation makes false forever, and this read-back would have refused on
        // the live cell every time it was run since.
        //
        // The record has no `.admin` key to compare against - which is the real gap, and it is a
        // TRUTH-JSON gap rather than a script one, so it is reported here and filed, not patched
        // from inside a read-back script. Assert what this gate can honestly assert (admin is set,
        // and matches the record when the record says), and SAY the rest.
        if (vm.keyExistsJson(json, ".admin")) {
            fails += _eq("cell.admin == record.admin", cell.admin(), vm.parseJsonAddress(json, ".admin"));
        } else {
            fails += _neq0("cell.admin is set (non-zero)", cell.admin());
            if (cell.admin() != deployer) {
                console2.log("[note] cell.admin != record.deployer - EXPECTED after the 2026-08-03 rotation.");
                console2.log("   admin now ", cell.admin());
                console2.log("   deployer  ", deployer);
                console2.log("   the record carries no .admin key, so this gate cannot assert the pair.");
                console2.log("   Record it via `update network folder` (truth JSON), not from here.");
            }
        }
        fails += _eq("token.minter == issuance", token.minter(), issuance);

        // --- the six that were wrongly deferred (bug_405). Read from the SAME record, so a
        // --- mis-wired module fails here rather than at the Phase 5 exercise, which runs after
        // --- lockWiring() has already made the mistake permanent.
        Wiring memory w = Wiring({
            cell: cellAddr,
            token: tokenAddr,
            escrow: escrow,
            issuance: issuance,
            claimModule: vm.parseJsonAddress(json, ".ClaimDisputeModule"),
            fmeaRegistry: vm.parseJsonAddress(json, ".FmeaRegistry"),
            integrityReview: vm.parseJsonAddress(json, ".IntegrityReviewModule"),
            specArbiter: vm.parseJsonAddress(json, ".SpecArbiterModule"),
            structuralUpgrade: vm.parseJsonAddress(json, ".StructuralUpgradeModule"),
            specGap: vm.parseJsonAddress(json, ".SpecGapModule"),
            assignment: vm.parseJsonAddress(json, ".AssignmentModule")
        });
        fails += _moduleBindingFails(w);

        console2.log("--- reported (not asserted) ---");
        console2.log("token.minterLocked (false until post-smoke lockMinter)", token.minterLocked());
        console2.log("cell.claimVerifierLocked", cell.claimVerifierLocked());

        console2.log("--- STILL not readable by getter; confirm via Phase 5 exercise ---");
        console2.log("cell dispute modules 0-4 (no accessor; DisputeModuleSet event exists - see header)");

        if (fails > 0) {
            revert(string.concat("VerifyWiring: ", vm.toString(fails), " assertion(s) FAILED"));
        }
        console2.log("VerifyWiring: all observable assertions PASSED");
        console2.log("SAFE TO PROCEED TO lockWiring() - every field lockWiring does NOT check was");
        console2.log("read back non-zero and correct above (bug_405).");
    }

    /// @notice Every module wire this read-back asserts, from addresses passed in - the seam the test drives against a
    ///         deliberately mis-wired deployment (`test/VerifyWiringBindings.t.sol`). Returns the number of failures.
    struct Wiring {
        address cell;
        address token;
        address escrow;
        address issuance;
        address claimModule;
        address fmeaRegistry;
        address integrityReview;
        address specArbiter;
        address structuralUpgrade;
        address specGap;
        address assignment;
    }

    function _moduleBindingFails(Wiring memory w) internal view returns (uint256 fails) {
        console2.log("--- module wires (bug_405: these ARE observable) ---");
        fails += _eq("issuance.treasuryEscrow == escrow",
                     IVerifyIssuance(w.issuance).treasuryEscrow(), w.escrow);
        fails += _eq("issuance.structuralModule == structuralUpgrade",
                     IVerifyIssuance(w.issuance).structuralModule(), w.structuralUpgrade);
        fails += _eq("claimModule.fmeaRegistry == fmeaRegistry",
                     IVerifyClaimModule(w.claimModule).fmeaRegistry(), w.fmeaRegistry);
        fails += _eq("fmeaRegistry.claimModule == claimModule (mutual bind)",
                     IVerifyFmea(w.fmeaRegistry).claimModule(), w.claimModule);
        fails += _eq("escrow.integrityReviewModule == integrityReview",
                     IVerifyEscrow(w.escrow).integrityReviewModule(), w.integrityReview);
        fails += _eq("integrityReview.specArbiterModule == specArbiter",
                     IVerifyIntegrity(w.integrityReview).specArbiterModule(), w.specArbiter);
        fails += _eq("structuralUpgrade.issuanceModule == issuance",
                     IVerifyStructural(w.structuralUpgrade).issuanceModule(), w.issuance);

        // bug_017 (2026-09-15, the second-family review of the fresh scope, VD-180). The pairs above are all
        // module-to-module; NONE read the host direction, and every `lockWiring` accepts a non-zero WRONG address. So a
        // module wired to another cell (a stale rung's, a mis-pasted address) printed SAFE TO PROCEED and then froze.
        console2.log("--- host and token bindings (bug_017) ---");
        fails += _eq("issuance.cell == cell", IVerifyIssuance(w.issuance).cell(), w.cell);
        fails += _eq("issuance.token == token", IVerifyIssuance(w.issuance).token(), w.token);
        fails += _eq("structuralUpgrade.cell == cell", IVerifyHosted(w.structuralUpgrade).cell(), w.cell);
        fails += _eq("claimModule.cell == cell", IVerifyHosted(w.claimModule).cell(), w.cell);
        fails += _eq("specGap.cell == cell", IVerifyHosted(w.specGap).cell(), w.cell);
        fails += _eq("specArbiter.cell == cell", IVerifyHosted(w.specArbiter).cell(), w.cell);
        fails += _eq("integrityReview.cell == cell", IVerifyHosted(w.integrityReview).cell(), w.cell);
        fails += _eq("assignment.cell == cell", IVerifyHosted(w.assignment).cell(), w.cell);
        fails += _eq("escrow.network == cell (G-01 mutual bind, escrow side)", IVerifyEscrow(w.escrow).network(), w.cell);
        fails += _eq("escrow.token == token", IVerifyEscrow(w.escrow).token(), w.token);
        fails += _eq("escrow.issuanceModule == issuance", IVerifyEscrow(w.escrow).issuanceModule(), w.issuance);
        fails += _eq("escrow.structuralUpgradeModule == structuralUpgrade",
                     IVerifyEscrow(w.escrow).structuralUpgradeModule(), w.structuralUpgrade);
        fails += _eq("cell.token == token", IVerifyCell(w.cell).token(), w.token);
        fails += _eq("cell.assignmentModule == assignment", IVerifyCell(w.cell).assignmentModule(), w.assignment);
    }

    function _neq0(string memory label, address got) internal pure returns (uint256) {
        if (got != address(0)) {
            console2.log(string.concat("[ok] ", label));
            return 0;
        }
        console2.log(string.concat("[FAIL] ", label, " - it is the zero address"));
        return 1;
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

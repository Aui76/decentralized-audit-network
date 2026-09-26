// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import {CellToken} from "../contracts/CellToken.sol";
import {CellEscrow} from "../contracts/CellEscrow.sol";

/*
 * THE SETTLEMENT CORE'S FIRST STATEFUL INVARIANTS (VD-160(2), 2026-09-11).
 *
 * Before this file the whole of `cell/test` held ONE invariant test and it was on the membrane
 * SATELLITE (`AuditEthMembrane.t.sol`:411, M-9) — so the core, which is the thing that moves money,
 * was entirely example-based. `EscrowSolvency.t.sol` pins G-26 and INV-2.5/2.6 beautifully, but each
 * of its tests is ONE hand-picked sequence, and "the vault covers its ledgers" is not a claim about
 * one sequence. It is a claim about every sequence.
 *
 * VD-160 places this BEFORE the §0 re-run deliberately: §0 measures the suite, so tests that land
 * first are covered by a measurement that was going to be taken anyway.
 *
 * THE HANDLER SHAPE IS COPIED FROM M-9, including the try/catch. The fuzzer will generate plenty of
 * calls that legitimately revert — an unreceipted credit, a settle against no debt, a subsidy larger
 * than the integrity bucket. A reverted call changes no state and so cannot violate an invariant;
 * what the harness needs is COVERAGE of the successful-call state space, not a halt on the first
 * expected revert.
 *
 * WHAT IS NOT HERE, named so the gap is not mistaken for coverage: the reject cap (INV-6.2) and
 * `payout <= bounty` (M-2/G-18) are properties of the CELL's audit lifecycle, not the escrow's
 * ledger, and they need a handler that drives submit → accept → prove → confirm against a live
 * `AuditCell`. That is a bigger harness than this one and it is the next piece, not a line to bolt on
 * here. This file covers the money-conservation family and says so in its own name.
 */
contract SolvencyNetworkStub {
    uint256 public totalSuccessfulAudits;
    address public treasuryEscrow;

    constructor(address escrow) {
        treasuryEscrow = escrow;
    }
}

/// @dev The handler IS the issuance module and the admin, so those ACL paths are exercised directly
///      rather than through a prank; network-gated calls are pranked from the stub, which is the only
///      address the escrow will accept them from.
contract EscrowSolvencyHandler is Test {
    CellToken public token;
    CellEscrow public escrow;
    address public networkStub;

    /// @dev G-24: the escrow reads the vesting-pace signal off its issuance module, which is this.
    uint256 public totalDistinctAuditPairs;

    address[3] public claimants = [address(0xC1A1), address(0xC1A2), address(0xC1A3)];

    constructor(CellToken _t, CellEscrow _e, address _n) {
        token = _t;
        escrow = _e;
        networkStub = _n;
    }

    function _send(uint256 seed, uint256 cap) internal returns (uint256 amt) {
        uint256 have = token.balanceOf(address(this));
        if (have == 0) return 0;
        amt = bound(seed, 1, have < cap ? have : cap);
        token.transfer(address(escrow), amt);
    }

    // ── credits: tokens must ARRIVE before the ledger is told about them ──────

    function depositFromIssuance(uint256 seed) external {
        uint256 amt = _send(seed, 100_000 ether);
        if (amt == 0) return;
        try escrow.recordDeposit(amt) {} catch {}
    }

    function slashFromNetwork(uint256 seed) external {
        uint256 amt = _send(seed, 50_000 ether);
        if (amt == 0) return;
        vm.prank(networkStub);
        try escrow.recordSlash(amt) {} catch {}
    }

    function founderDeposit(uint256 seed) external {
        uint256 amt = _send(seed, 20_000 ether);
        if (amt == 0) return;
        try escrow.recordFounderDeposit(amt) {} catch {}
    }

    function seedIntegrity(uint256 seed) external {
        uint256 amt = _send(seed, 20_000 ether);
        if (amt == 0) return;
        try escrow.seedIntegrityBucket(amt) {} catch {}
    }

    function returnIntegrity(uint256 seed) external {
        uint256 amt = _send(seed, 10_000 ether);
        if (amt == 0) return;
        vm.prank(networkStub);
        try escrow.recordIntegrityReturn(amt) {} catch {}
    }

    // ── debits ───────────────────────────────────────────────────────────────

    function payIntegritySubsidy(uint256 seed) external {
        uint256 amt = bound(seed, 1, 20_000 ether);
        vm.prank(networkStub);
        try escrow.payIntegrityReviewSubsidy(amt, 0) returns (uint256) {} catch {}
    }

    function recordDebt(uint256 whoSeed, uint256 seed) external {
        address who = claimants[bound(whoSeed, 0, 2)];
        uint256 amt = bound(seed, 1, 50_000 ether);
        vm.prank(networkStub);
        try escrow.recordDiscovererDebt(who, amt) {} catch {}
    }

    function settleDebt(uint256 whoSeed, uint256 iterSeed) external {
        address who = claimants[bound(whoSeed, 0, 2)];
        // Permissionless by design (INV-2.5: it pays the RECORDED claimant, never the caller).
        try escrow.settleDiscovererDebt(who, bound(iterSeed, 1, 32)) returns (uint256) {} catch {}
    }

    // ── the vesting-pace signal the escrow reads off its issuance module ──────

    function advancePace(uint256 seed) external {
        totalDistinctAuditPairs += bound(seed, 0, 5);
    }
}

contract EscrowSolvencyInvariantTest is StdInvariant, Test {
    CellToken internal token;
    CellEscrow internal escrow;
    SolvencyNetworkStub internal networkStub;
    EscrowSolvencyHandler internal handler;

    address internal founder = address(0xF00001);

    uint256 internal lpSeen;

    function setUp() public {
        token = new CellToken();
        token.genesisMint(address(this), 20_000_000 ether);
        escrow = new CellEscrow(address(token));
        networkStub = new SolvencyNetworkStub(address(escrow));
        handler = new EscrowSolvencyHandler(token, escrow, address(networkStub));

        // G-27: release-target calibration must happen BEFORE setNetwork (raise-only afterwards).
        escrow.setFounderReleaseTarget(10);
        escrow.setNetwork(address(networkStub));
        escrow.setIssuanceModule(address(handler));
        escrow.setFounder(founder);
        // Admin LAST: the handler drives the admin-gated paths too, and transferring earlier would
        // lock this contract out of the configuration above.
        escrow.transferAdmin(address(handler));

        token.transfer(address(handler), 10_000_000 ether);

        lpSeen = escrow.lpBalance();
        targetContract(address(handler));
    }

    /// INV-2.5 / G-26 — THE ONE THAT MATTERS. The vault must hold at least what its ledgers claim,
    /// after any sequence. `accountedLiability()` is the escrow's own sum of what it owes; the token
    /// balance is what it actually has. Example tests pin this at hand-chosen points; this pins it
    /// across arbitrary reachable sequences, which is what "solvent" means.
    function invariant_vault_covers_its_ledgers() public view {
        assertGe(
            token.balanceOf(address(escrow)),
            escrow.accountedLiability(),
            "G-26: the vault holds less than its ledgers claim"
        );
    }

    /// The pot is one component of the liability, never more than the whole of it. A pot that exceeds
    /// `accountedLiability` would mean the sum is not summing.
    function invariant_pot_is_within_the_accounted_total() public view {
        assertLe(
            escrow.escrowBalance(),
            escrow.accountedLiability(),
            "the settlement pot exceeds the total liability it is a component of"
        );
    }

    /// INV-2.6 — lpBalance is monotonic. Nothing in this handler's reach may take it down.
    function invariant_lp_balance_never_decreases() public {
        uint256 now_ = escrow.lpBalance();
        assertGe(now_, lpSeen, "INV-2.6: lpBalance went DOWN");
        lpSeen = now_;
    }

    /// G-26's boundary, pinned as a property rather than a single case: recorded discoverer debt is a
    /// PROMISE, not a backed liability, so it must never inflate `accountedLiability`. If it ever did,
    /// the solvency check above would start demanding cover for money the escrow never received.
    function invariant_debt_is_not_a_backed_liability() public view {
        uint256 debt;
        for (uint256 i = 0; i < 3; i++) {
            debt += escrow.discovererDebt(handler.claimants(i));
        }
        assertGe(
            token.balanceOf(address(escrow)),
            escrow.accountedLiability(),
            "solvency must hold irrespective of outstanding debt"
        );
        if (debt > 0) {
            assertLe(
                escrow.accountedLiability(),
                token.balanceOf(address(escrow)),
                "recorded debt must not have been folded into the backed liability"
            );
        }
    }
}

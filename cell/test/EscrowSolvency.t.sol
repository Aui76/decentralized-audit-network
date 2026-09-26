// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";

import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";

/// @dev Minimal network bind for solvency unit tests (same shape as FounderNetworkStub).
contract SolvencyNetworkStub {
    uint256 public totalSuccessfulAudits;
    address public treasuryEscrow;

    constructor(address escrow) {
        treasuryEscrow = escrow;
    }

    function setTotalSuccessfulAudits(uint256 n) external {
        totalSuccessfulAudits = n;
    }
}

/// @notice G-26 oracle — the escrow proves its own solvency at every credit.
///         Invariant: token.balanceOf(escrow) >= lpBalance + escrowBalance + integrityEscrowBalance
///                                               + (founderBalance - founderClaimed).
///         Proposal: body/proposals/escrow-solvency-invariant-proposal.txt (manifest row 6).
contract EscrowSolvencyTest is Test {
    CellToken internal token;
    CellEscrow internal escrow;
    SolvencyNetworkStub internal networkStub;

    /// @dev G-24: this test contract IS the issuance module; the escrow reads the vesting-pace signal from it.
    uint256 public totalDistinctAuditPairs;

    address internal founder = address(0xF00001);
    address internal payee = address(0xBEEF01);

    function setUp() external {
        token = new CellToken();
        token.genesisMint(address(this), 20_000_000 ether);
        escrow = new CellEscrow(address(token));
        networkStub = new SolvencyNetworkStub(address(escrow));
        // G-27: release-target calibration must happen BEFORE setNetwork (raise-only afterwards).
        escrow.setFounderReleaseTarget(10);
        escrow.setNetwork(address(networkStub));
        // issuance-ACL paths are exercised directly: this test is the issuance module.
        escrow.setIssuanceModule(address(this));
        escrow.setFounder(founder);
    }

    function _assertSolventTightOrSlack() internal view {
        assertGe(
            token.balanceOf(address(escrow)),
            escrow.accountedLiability(),
            "G-26: vault holds less than the ledgers claim"
        );
    }

    /// t1 — a slash recorded with NO prior token transfer must revert at the credit, not at pay time.
    function test_unreceipted_slash_credit_reverts() external {
        assertEq(token.balanceOf(address(escrow)), 0);
        vm.prank(address(networkStub));
        vm.expectRevert("Tokens not received");
        escrow.recordSlash(100 ether);
    }

    /// t2 — the old per-amount check let existing bucket money "back" a new credit. This is the register's
    ///      "(no regression yet)" cell getting its regression: vault 100 fully owed, recordDeposit(50) with no
    ///      new tokens passed the old `balanceOf >= amount` check and silently went insolvent (150 owed vs 100
    ///      held). It must now revert.
    function test_weak_deposit_double_count_reverts() external {
        token.transfer(address(escrow), 100 ether);
        vm.prank(address(networkStub));
        escrow.recordDeposit(100 ether); // honest: 100 in, 100 recorded
        assertEq(escrow.accountedLiability(), 100 ether);

        vm.prank(address(networkStub));
        vm.expectRevert("Tokens not received");
        escrow.recordDeposit(50 ether); // dishonest: no new tokens
    }

    /// t3 — the admin seed path (the only credit with no on-chain caller moving tokens first) now requires the
    ///      vault to actually be funded: fund-then-seed works, seed-alone reverts.
    function test_seed_integrity_requires_funding() external {
        vm.expectRevert("Tokens not received");
        escrow.seedIntegrityBucket(1_000 ether);

        token.transfer(address(escrow), 1_000 ether);
        escrow.seedIntegrityBucket(1_000 ether);
        assertEq(escrow.integrityEscrowBalance(), 1_000 ether);
        // tight: every vault token is accounted, no slack
        assertEq(token.balanceOf(address(escrow)), escrow.accountedLiability());
    }

    /// t4 — the invariant holds through a full honest lifecycle: deposit, slash, integrity return, founder
    ///      mint + claim, floor/discoverer pays, timelock migrate, LP withdraw.
    function test_solvency_holds_through_full_lifecycle() external {
        // credit: general deposit (LP/general/integrity split)
        token.transfer(address(escrow), 10_000 ether);
        vm.prank(address(networkStub));
        escrow.recordDeposit(10_000 ether);
        _assertSolventTightOrSlack();

        // credit: slash (transfer-then-record, as AuditCell does)
        token.transfer(address(escrow), 500 ether);
        vm.prank(address(networkStub));
        escrow.recordSlash(500 ether);
        _assertSolventTightOrSlack();

        // credit: integrity return (transfer-then-record, as IntegrityReviewModule does)
        token.transfer(address(escrow), 200 ether);
        vm.prank(address(networkStub));
        escrow.recordIntegrityReturn(200 ether);
        _assertSolventTightOrSlack();

        // credit: founder tranche (mint lands on the escrow first in IssuanceModule; simulated by transfer)
        token.transfer(address(escrow), 1_000 ether);
        escrow.recordFounderDeposit(1_000 ether);
        _assertSolventTightOrSlack();

        // debit: founder claims in full once the activity gate opens (G-24: gate is distinct pairs now)
        totalDistinctAuditPairs = 10;
        vm.prank(founder);
        uint256 claimed = escrow.claimFounder();
        assertEq(claimed, 1_000 ether);
        _assertSolventTightOrSlack();

        // debit: floor supplement (this test is the issuance module)
        uint256 floorPaid = escrow.payFloorSupplement(payee, 300 ether, 10);
        assertGt(floorPaid, 0);
        _assertSolventTightOrSlack();

        // debit: discoverer pay (network ACL)
        vm.prank(address(networkStub));
        uint256 discPaid = escrow.payDiscoverer(payee, 200 ether, 10);
        assertGt(discPaid, 0);
        _assertSolventTightOrSlack();

        // (migrate() step removed 2026-08-09 — the function is gone; general escrow no longer moves to LP at
        //  all, so there is no internal move left to prove liability-neutral. The solvency invariant was
        //  already asserted after every debit above, which is the whole claim.)
        // (LP-withdraw debit step removed 2026-08-09 — DEC-38 deleted `withdrawForLP`. LP is no longer a
        //  debit path at all: `lpBalance` only ever grows, so it cannot be a source of insolvency. The
        //  remaining debits above are the whole set.)
        uint256 lp = escrow.lpBalance();
        assertGt(lp, 0, "LP still funded by the mint split");
        _assertSolventTightOrSlack();
    }

    // ---- Debt ledger (2026-08-09, discoverer-debt-ledger-proposal) ----

    /// Record is network-gated; debt sits OUTSIDE accountedLiability by design (a promise against
    /// future deposits, not a claim on tokens held) — so recording moves NO invariant number.
    function test_debt_record_is_gated_and_outside_liability() external {
        vm.expectRevert("Not network");
        escrow.recordDiscovererDebt(payee, 10 ether);

        uint256 liabilityBefore = escrow.accountedLiability();
        vm.prank(address(networkStub));
        escrow.recordDiscovererDebt(payee, 10 ether);
        assertEq(escrow.discovererDebt(payee), 10 ether, "debt recorded");
        assertEq(escrow.totalDiscovererDebt(), 10 ether, "total tracks");
        assertEq(escrow.accountedLiability(), liabilityBefore, "debt is NOT a backed liability (G-26 untouched)");
        _assertSolventTightOrSlack();
    }

    /// Settle pays what the pot holds, keeps the remainder OWED, and holds G-26 throughout.
    /// Escrow funded via the real deposit path: recordDeposit(100) -> general bucket 22.908
    /// (24.9% of 100, minus the 8% integrity ring-fence).
    function test_debt_settles_partial_then_fully_on_refill() external {
        token.transfer(address(escrow), 100 ether);
        vm.prank(address(networkStub));
        escrow.recordDeposit(100 ether);
        uint256 pot = escrow.escrowBalance();
        assertEq(pot, 22.908 ether, "general bucket = 24.9% minus integrity share");

        vm.prank(address(networkStub));
        escrow.recordDiscovererDebt(payee, 30 ether); // owed more than the pot holds

        uint256 paid = escrow.settleDiscovererDebt(payee, 10); // permissionless pull
        assertEq(paid, pot, "paid everything the pot held");
        assertEq(escrow.discovererDebt(payee), 30 ether - pot, "remainder stays owed");
        assertEq(escrow.escrowBalance(), 0, "pot drained by the settle");
        assertEq(token.balanceOf(payee), pot, "claimant actually received tokens");
        _assertSolventTightOrSlack();

        // Refill; the remainder becomes payable.
        token.transfer(address(escrow), 100 ether);
        vm.prank(address(networkStub));
        escrow.recordDeposit(100 ether);
        uint256 paid2 = escrow.settleDiscovererDebt(payee, 10);
        assertEq(paid2, 30 ether - pot, "the owed remainder, exactly");
        assertEq(escrow.discovererDebt(payee), 0, "made whole");
        assertEq(escrow.totalDiscovererDebt(), 0, "ledger clear");
        _assertSolventTightOrSlack();
    }

    /// Settling a claimant with no debt is a no-op, not a revert (and pays nothing).
    function test_debt_settle_zero_is_noop() external {
        uint256 paid = escrow.settleDiscovererDebt(payee, 10);
        assertEq(paid, 0);
        assertEq(token.balanceOf(payee), 0);
    }

    // ---- PC-27: pin INV-2.5 (no extraction) + INV-2.6 (lpBalance monotonic) ----

    /// INV-2.5 NO-EXTRACTION: settleDiscovererDebt is PERMISSIONLESS but pays the RECORDED claimant, never
    /// msg.sender. A third party triggering the settle moves tokens to the creditor and gets nothing —
    /// permissionless-ness grants no lever. (Property test, not a regression: there is no code path that pays
    /// the caller, which is exactly what this asserts.)
    function test_debt_settle_pays_recorded_claimant_not_caller() external {
        address attacker = address(0xBAD);
        token.transfer(address(escrow), 100 ether);
        vm.prank(address(networkStub));
        escrow.recordDeposit(100 ether);
        assertGt(escrow.escrowBalance(), 5 ether, "pot funded above the debt");

        vm.prank(address(networkStub));
        escrow.recordDiscovererDebt(payee, 5 ether);

        uint256 attackerBefore = token.balanceOf(attacker);
        uint256 payeeBefore = token.balanceOf(payee);

        vm.prank(attacker); // permissionless caller, NOT the creditor
        uint256 paid = escrow.settleDiscovererDebt(payee, 10);

        assertEq(paid, 5 ether, "debt paid in full from the pot");
        assertEq(token.balanceOf(payee) - payeeBefore, 5 ether, "the RECORDED claimant received the tokens");
        assertEq(token.balanceOf(attacker), attackerBefore, "the CALLER received nothing - no extraction");
        assertEq(escrow.discovererDebt(payee), 0, "debt cleared");
        assertEq(escrow.totalDiscovererDebt(), 0, "total tracks");
        _assertSolventTightOrSlack();
    }

    /// INV-2.6 MONOTONIC lpBalance: the sole write is recordDeposit's `+= toLP` (:199); withdrawForLP and
    /// migrate are removed, so no debit path exists. Assert lpBalance never drops below its post-first-deposit
    /// level across every payout path (floor, discoverer) AND a debt record+settle, then rises again on a
    /// second deposit.
    function test_lpBalance_monotonic_across_lifecycle() external {
        uint256 lp0 = escrow.lpBalance();

        token.transfer(address(escrow), 100 ether);
        vm.prank(address(networkStub));
        escrow.recordDeposit(100 ether);
        uint256 lp1 = escrow.lpBalance();
        assertGt(lp1, lp0, "deposit raises LP");

        // floor supplement (this test IS the issuance module) draws general escrow, not LP
        escrow.payFloorSupplement(payee, 3 ether, 10);
        assertGe(escrow.lpBalance(), lp1, "floor pay does not lower LP");

        // discoverer pay (network ACL) draws general escrow, not LP
        vm.prank(address(networkStub));
        escrow.payDiscoverer(payee, 2 ether, 10);
        assertGe(escrow.lpBalance(), lp1, "discoverer pay does not lower LP");

        // debt record + permissionless settle draw general escrow, not LP
        vm.prank(address(networkStub));
        escrow.recordDiscovererDebt(payee, 2 ether);
        escrow.settleDiscovererDebt(payee, 10);
        assertGe(escrow.lpBalance(), lp1, "debt settle does not lower LP");

        // a further deposit only ever raises it
        token.transfer(address(escrow), 50 ether);
        vm.prank(address(networkStub));
        escrow.recordDeposit(50 ether);
        assertGe(escrow.lpBalance(), lp1, "second deposit does not lower LP");
    }
}

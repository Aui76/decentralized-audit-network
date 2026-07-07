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

        // internal move: timelocked general->LP migration cannot create liability
        vm.warp(block.timestamp + 181 days);
        escrow.migrate(10);
        _assertSolventTightOrSlack();

        // debit: LP withdraw (lpManager is this test, set in the constructor)
        uint256 lp = escrow.lpBalance();
        assertGt(lp, 0);
        escrow.withdrawForLP(lp);
        _assertSolventTightOrSlack();
    }
}

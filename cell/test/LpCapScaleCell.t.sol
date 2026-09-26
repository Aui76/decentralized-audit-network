// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";

import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/IssuanceModule.sol";

/// @dev Minimal network bind for CellEscrow LP-cap oracle (treasuryEscrow mutual bind).
contract CellEscrowNetworkStub {
    address public treasuryEscrow;

    constructor(address escrow) {
        treasuryEscrow = escrow;
    }
}

/// @notice F-42 / R5: LP-cap at 15% of trailing supply — deposit + migrate behavior.
contract LpCapScaleCellTest is Test {
    CellToken internal token;
    CellEscrow internal escrow;
    IssuanceModule internal issuance;
    CellEscrowNetworkStub internal networkStub;

    address internal admin = address(this);

    uint256 internal supplySeed;
    uint256 internal lpCap;

    function setUp() external {
        token = new CellToken();
        escrow = new CellEscrow(address(token));
        issuance = new IssuanceModule(admin);
        networkStub = new CellEscrowNetworkStub(address(escrow));

        issuance.wire(address(networkStub), address(token), address(escrow));
        escrow.setNetwork(address(networkStub));
        escrow.setIssuanceModule(address(issuance));

        supplySeed = 1_000_000 ether;
        token.genesisMint(address(this), supplySeed);
        lpCap = escrow.lpCapView();
        assertEq(lpCap, (supplySeed * escrow.LP_CAP_BPS()) / 10_000);
    }

    function test_recordDeposit_immediate_lp_split_respects_trailing_supply_cap() external {
        uint256 deposit = 200_000 ether;
        _recordDeposit(deposit);

        uint256 lpBps = escrow.LP_BPS();
        uint256 lpFromSplit = (deposit * lpBps) / 10_000;
        assertEq(escrow.lpBalance(), lpCap, "immediate LP credit stops at 15% supply cap");
        assertGt(lpFromSplit, lpCap, "75.1% split can exceed 15% supply cap per deposit");
        assertGt(escrow.escrowBalance(), 0, "overflow from capped split stays in escrow");
    }

    function test_lp_cap_scales_with_total_supply() external {
        token.genesisMint(address(this), 500_000 ether);
        uint256 newCap = escrow.lpCapView();
        assertGt(newCap, lpCap);
        assertEq(newCap, (token.totalSupply() * escrow.LP_CAP_BPS()) / 10_000);
    }

    // ---- Three migrate tests RETIRED 2026-08-09 (migrate-removal-proposal), subject deleted ----
    //
    // `test_migrate_never_exceeds_lp_cap_after_many_deposits`, `test_migrate_partial_when_headroom_small`
    // and `test_migrate_never_increases_lp_past_cap` all exercised `escrow.migrate(...)`, which DEC-38's
    // follow-on removed. Retired rather than deleted silently (same discipline as the LpUncapLatch and
    // EscrowSolvency edits): the two tests above — the immediate 75.1% deposit split against the 15% cap,
    // and the cap scaling with supply — are UNTOUCHED and remain the live coverage of `recordDeposit` and
    // `lpCapView`. What is no longer covered is the aged escrow→LP catch-up, because it no longer exists;
    // `lpBalance` is now monotonic (only `recordDeposit` credits it, capped at 15%).
    //
    // REOPEN TRIGGER: if any future change reintroduces a path that moves escrow into LP after the fact,
    // these three come back — the cap-respect-under-migration property becomes reachable again the moment
    // such a path exists.

    function _recordDeposit(uint256 amount) internal {
        token.transfer(address(escrow), amount);
        vm.prank(address(networkStub));
        escrow.recordDeposit(amount);
    }
}

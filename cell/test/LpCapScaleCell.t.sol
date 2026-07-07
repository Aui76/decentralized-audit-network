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

    function test_migrate_never_exceeds_lp_cap_after_many_deposits() external {
        uint256 depositEach = 25_000 ether;
        uint256 rounds = 40;

        for (uint256 i = 0; i < rounds; i++) {
            _recordDeposit(depositEach);
            assertLe(escrow.lpBalance(), escrow.lpCapView(), "cap tracks supply");
        }

        vm.warp(block.timestamp + escrow.TIMELOCK() + 1);

        uint256 migrated;
        while (escrow.pendingDepositCount() > 0 && escrow.lpBalance() < escrow.lpCapView()) {
            migrated += escrow.migrate(50);
            assertLe(escrow.lpBalance(), escrow.lpCapView(), "migrate respects cap");
            if (migrated == 0) break;
        }

        assertLe(escrow.lpBalance(), escrow.lpCapView(), "final LP <= cap");
        assertGt(escrow.escrowBalance(), 0, "escrow retains overflow when LP capped");
    }

    function test_migrate_partial_when_headroom_small() external {
        uint256 deposit = (lpCap * 10_000) / 8000 - 10_000 ether;
        _recordDeposit(deposit);

        uint256 lpImmediate = escrow.lpBalance();
        assertLt(lpImmediate, lpCap, "room before migrate");
        assertGt(escrow.escrowBalance(), 0, "escrow queued");

        vm.warp(block.timestamp + escrow.TIMELOCK() + 1);
        uint256 migrated = escrow.migrate(100);

        assertGt(migrated, 0, "partial migrate");
        assertEq(escrow.lpBalance(), lpCap, "LP fills remaining headroom");
        assertGt(escrow.escrowBalance(), 0, "residual escrow when cap binds");
    }

    function test_migrate_never_increases_lp_past_cap() external {
        uint256 perBlockTreasury = 3_000 ether;
        for (uint256 b = 0; b < 120; b++) {
            _recordDeposit(perBlockTreasury);
        }

        vm.warp(block.timestamp + escrow.TIMELOCK() + 1);
        for (uint256 i = 0; i < 20; i++) {
            uint256 lpBefore = escrow.lpBalance();
            escrow.migrate(100);
            assertLe(escrow.lpBalance(), escrow.lpCapView(), "never above cap after migrate");
            if (escrow.lpBalance() == lpBefore) break;
        }
    }

    function _recordDeposit(uint256 amount) internal {
        token.transfer(address(escrow), amount);
        vm.prank(address(networkStub));
        escrow.recordDeposit(amount);
    }
}

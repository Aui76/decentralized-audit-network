// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";

import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/IssuanceModule.sol";
import "./helpers/IssuanceCellStub.sol";

/// @dev FOUNDER_CAP_ABS = 15M AUDIT — accrue, freeze, dilution (PR 1).
contract FounderCapAbsTest is Test {
    using stdStorage for StdStorage;

    CellToken internal token;
    CellEscrow internal escrow;
    IssuanceModule internal issuance;
    IssuanceCellStub internal cellStub;

    function setUp() external {
        token = new CellToken();
        token.genesisMint(address(this), 20_000_000 ether);
        escrow = new CellEscrow(address(token));
        issuance = new IssuanceModule(address(this));
        cellStub = new IssuanceCellStub(issuance);
        issuance.wire(address(cellStub), address(token), address(escrow));
        escrow.setIssuanceModule(address(issuance));
        token.setMinter(address(issuance));
    }

    function test_founder_cap_absolute_15m() external view {
        assertEq(escrow.FOUNDER_CAP_ABS(), 15_000_000 ether);
        assertEq(escrow.founderCapRemaining(), 15_000_000 ether);
    }

    function test_founder_accrues_then_freezes_at_cap() external {
        uint256 cap = escrow.FOUNDER_CAP_ABS();
        token.transfer(address(escrow), cap + 1000 ether);

        vm.startPrank(address(issuance));
        escrow.recordFounderDeposit(cap);
        assertEq(escrow.founderTotalMinted(), cap);
        assertEq(escrow.founderCapRemaining(), 0);

        escrow.recordFounderDeposit(1000 ether);
        vm.stopPrank();

        assertEq(escrow.founderTotalMinted(), cap);
        assertEq(escrow.founderBalance(), cap);
    }

    function test_settlePositiveBlock_respects_founder_cap() external {
        _setEma(1_000_000_000 ether, 1_000_000_000 ether);

        (uint256 auditorMinted,,) =
            cellStub.settlePositiveBlock(1, address(0xA), address(0xB), 1_000_000 ether);

        // A-1 (G-17): the founder slice derives from the GATED auditor mint, not the ungated reward. Here 0xA is
        // unproven (weight x0.25) AND the per-block bounty cap binds hard (25% of 1,000,000 = 250,000, far under
        // the 62.5M weighted reward) → mint 250,000, founder slice 305bps of that = 7,625.
        uint256 expectedFounder = (auditorMinted * issuance.founderShareBps()) / 10_000;
        assertLe(escrow.founderTotalMinted(), escrow.FOUNDER_CAP_ABS());
        assertEq(escrow.founderTotalMinted(), expectedFounder);
    }

    function test_founder_fraction_dilutes_as_supply_grows_past_1b() external {
        CellToken big = new CellToken();
        big.genesisMint(address(this), 2_000_000_000 ether);
        CellEscrow bigEscrow = new CellEscrow(address(big));
        IssuanceModule bigIssuance = new IssuanceModule(address(this));
        IssuanceCellStub stub = new IssuanceCellStub(bigIssuance);
        bigIssuance.wire(address(stub), address(big), address(bigEscrow));
        bigEscrow.setIssuanceModule(address(bigIssuance));
        big.setMinter(address(bigIssuance));

        uint256 cap = bigEscrow.FOUNDER_CAP_ABS();
        big.transfer(address(bigEscrow), cap);
        vm.prank(address(bigIssuance));
        bigEscrow.recordFounderDeposit(cap);

        assertEq(bigEscrow.founderTotalMinted(), cap);
        uint256 supply = big.totalSupply();
        assertGt(supply, 1_000_000_000 ether);
        assertLt((cap * 10_000) / supply, 150, "founder share below 1.5% once supply exceeds 1B");
    }

    function _setEma(uint256 slow, uint256 fast) internal {
        stdstore.target(address(issuance)).sig("emaSlow()").checked_write(slow);
        stdstore.target(address(issuance)).sig("emaFast()").checked_write(fast);
        stdstore.target(address(issuance)).sig("lastEmaFast()").checked_write(fast);
    }
}

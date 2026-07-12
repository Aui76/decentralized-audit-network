// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";

import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/IssuanceModule.sol";
import "./helpers/IssuanceCellStub.sol";

/// @dev Uncapped IssuanceModule v1 — activity curve + LP-cap invariants (PR 1).
contract MintCurveInvariantsTest is Test {
    using stdStorage for StdStorage;

    CellToken internal token;
    CellEscrow internal escrow;
    IssuanceModule internal issuance;
    IssuanceCellStub internal cellStub;

    address internal auditor = address(0xA);
    address internal protocol = address(0xB);

    function setUp() external {
        token = new CellToken();
        escrow = new CellEscrow(address(token));
        issuance = new IssuanceModule(address(this));
        cellStub = new IssuanceCellStub(issuance);
        issuance.wire(address(cellStub), address(token), address(escrow));
        escrow.setIssuanceModule(address(issuance));
        token.setMinter(address(issuance));
    }

    function test_totalSupply_zero_before_any_settle() external view {
        assertEq(token.totalSupply(), 0);
    }

    function test_deep_lp_reward_is_twenty_five_percent_of_emaSlow() external {
        _setEma(5000 ether, 5000 ether);
        assertEq(issuance.nextPositiveBlockReward(), (5000 ether * 2500) / 10_000);
    }

    function test_lp_cap_binds_when_lp_shallow() external {
        _setEma(5000 ether, 5000 ether);
        uint256 lp = 1000 ether;
        stdstore.target(address(escrow)).sig("lpBalance()").checked_write(lp);
        uint256 activityMint = (5000 ether * 2500) / 10_000;
        uint256 lpCapMint = (500 * lp) / 10_000;
        assertLt(lpCapMint, activityMint);
        assertEq(issuance.nextPositiveBlockReward(), lpCapMint);
    }

    function test_lp_cap_releases_as_lp_grows() external {
        _setEma(5000 ether, 5000 ether);
        uint256 activityMint = (5000 ether * 2500) / 10_000;
        uint256 lpNeeded = (activityMint * 10_000) / 500;
        stdstore.target(address(escrow)).sig("lpBalance()").checked_write(lpNeeded);
        assertEq(issuance.nextPositiveBlockReward(), activityMint);
    }

    function test_lp_zero_skips_mint_lp_cap() external {
        _setEma(5000 ether, 5000 ether);
        assertEq(escrow.lpBalance(), 0);
        assertEq(issuance.nextPositiveBlockReward(), (5000 ether * 2500) / 10_000);
    }

    function test_manipulation_spike_damps_reward() external {
        _setEma(1000 ether, 2000 ether);
        uint256 undamped = (1000 ether * 2500) / 10_000;
        // G-23 (M-5): the continuous taper replaced the 8000-bps cliff. Derive the expected damping
        // from the contract's own curve (fast/slow ratio 20_000 bps -> slope past threshold, floored)
        // so this invariant tracks the params instead of drifting when they move. The dedicated
        // ManipulationTaper suite owns the curve-shape assertions.
        uint256 scale = issuance.manipulationScaleBps((2000 ether * 10_000) / 1000 ether);
        assertLt(scale, 10_000, "spike must damp");
        assertGe(scale, issuance.manipulationMintFloorBps(), "taper floored");
        assertEq(issuance.nextPositiveBlockReward(), (undamped * scale) / 10_000);
    }

    function test_settle_mints_without_supply_ceiling() external {
        _setEma(5000 ether, 5000 ether);

        (uint256 auditorMinted,, uint256 reward) =
            cellStub.settlePositiveBlock(1, auditor, protocol, 5000 ether);

        assertGt(reward, 0);
        assertEq(auditorMinted, reward);
        assertGt(token.totalSupply(), 0);
    }

    function test_genesis_preview_mint_from_first_bounty() external {
        uint256 bg = 5000 ether;
        uint256 slowSignal = (bg * issuance.emaSlowUnprovenWeightBps()) / 10_000;
        uint256 expected = (slowSignal * issuance.emaToMintBps()) / 10_000;
        // A-1 (G-17): this settle registers the auditor's 1st distinct protocol (< threshold) → mint weighted
        // x0.25. The per-block cap (25% of bg=5000 = 1250) is slack against 78.125, so only the weight binds.
        expected = (expected * issuance.mintUnprovenWeightBps()) / 10_000;

        (uint256 auditorMinted,, uint256 reward) =
            cellStub.settlePositiveBlock(0, auditor, protocol, bg);

        assertEq(reward, expected);
        assertEq(auditorMinted, expected);
        assertEq(issuance.emaSlow(), slowSignal);
    }

    function _setEma(uint256 slow, uint256 fast) internal {
        stdstore.target(address(issuance)).sig("emaSlow()").checked_write(slow);
        stdstore.target(address(issuance)).sig("emaFast()").checked_write(fast);
        stdstore.target(address(issuance)).sig("lastEmaFast()").checked_write(fast);
    }
}

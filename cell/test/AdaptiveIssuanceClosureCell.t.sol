// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/IssuanceModule.sol";

/// @notice Adaptive issuance state machine on uncapped activity curve (PR 1 rewrite).
contract AdaptiveIssuanceClosureCellTest is Test {
    using stdStorage for StdStorage;

    CellToken internal token;
    CellEscrow internal escrow;
    IssuanceModule internal issuance;

    function setUp() external {
        token = new CellToken();
        escrow = new CellEscrow(address(token));
        issuance = new IssuanceModule(address(this));
        issuance.wire(address(0xBEEF), address(token), address(escrow));
        escrow.setIssuanceModule(address(issuance));
    }

    function test_floorDecayBps_full_when_no_failed_attempts() external view {
        assertEq(issuance.floorDecayBps(), 10_000);
        assertEq(issuance.failedRecoveryAttempts(), 0);
    }

    function test_issuanceNetworkState_stable_before_any_confirm() external view {
        assertEq(
            uint256(issuance.issuanceNetworkState()),
            uint256(IssuanceModule.IssuanceNetworkState.Stable)
        );
    }

    function test_nextPositiveBlockReward_zero_when_emaSlow_unset() external view {
        assertEq(issuance.nextPositiveBlockReward(), 0);
    }

    function test_nextPositiveBlockReward_activity_curve_when_ema_set() external {
        _setEmaState(5000 ether, 5000 ether, 5000 ether);
        assertEq(issuance.nextPositiveBlockReward(), (5000 ether * 2500) / 10_000);
    }

    function test_manipulation_reduces_next_block_reward_when_emas_skewed() external {
        // G-23 (M-5): threshold must sit above parity (taper slope anchors on threshold-10000). At ratio ==
        // threshold the continuous taper equals the old cliff scale exactly, so the assertion is unchanged in
        // spirit: heavily-skewed EMAs -> the configured scale at the threshold.
        issuance.setAdaptiveIssuanceParams(13000, 5000, 2500, 5, 25, true, 5000);
        _setEmaState(1000 ether, 1300 ether, 1000 ether); // ratio == 13000 bps (the threshold)
        uint256 undamped = (1000 ether * 2500) / 10_000;
        assertEq(issuance.manipulationScaleBps(13000), 5000, "taper == cliff scale at the threshold");
        assertEq(issuance.nextPositiveBlockReward(), (undamped * 5000) / 10_000);
    }

    function test_depressionIntensity_zero_when_emas_uninitialized() external view {
        assertEq(issuance.depressionIntensityBps(), 0);
    }

    function test_greenLightMintAllowed_false_below_recoverabilityFactor() external {
        _setEmaState(1000 ether, 300 ether, 400 ether);
        assertFalse(issuance.greenLightMintAllowed());
    }

    function test_greenLightMintAllowed_false_when_ema_not_improving() external {
        _setEmaState(1000 ether, 500 ether, 600 ether);
        assertFalse(issuance.greenLightMintAllowed());
    }

    function test_greenLightMintAllowed_true_when_gates_met_in_depression() external {
        _setEmaState(1000 ether, 500 ether, 400 ether);
        assertTrue(issuance.greenLightMintAllowed());
    }

    function test_greenLightMintAllowed_false_when_not_in_depression() external {
        _setEmaState(1000 ether, 800 ether, 700 ether);
        assertFalse(issuance.greenLightMintAllowed());
    }

    function _setEmaState(uint256 slow, uint256 fast, uint256 prevFast) internal {
        stdstore.target(address(issuance)).sig("emaSlow()").checked_write(slow);
        stdstore.target(address(issuance)).sig("emaFast()").checked_write(fast);
        stdstore.target(address(issuance)).sig("lastEmaFast()").checked_write(prevFast);
    }
}

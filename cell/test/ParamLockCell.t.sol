// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "./helpers/CellTestDeploy.sol";
import "../contracts/CellParamIds.sol";
import "../contracts/CellLogicLib.sol";

/// @notice G6 oracle — generic param-lock bitmap (hybrid renunciation path).
contract ParamLockCellTest is Test {
    AuditCell cell;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        cell = d.cell;
    }

    function test_claim_resolution_lock() public {
        cell.setParam(CellParamIds.CLAIM_RESOLUTION, 11 minutes);
        assertEq(cell.claimResolutionWindow(), 11 minutes);
        cell.lockParam(CellParamIds.CLAIM_RESOLUTION);
        assertTrue(cell.paramLocked(CellParamIds.CLAIM_RESOLUTION));
        vm.expectRevert(CellLogicLib.ParamLockedErr.selector);
        cell.setParam(CellParamIds.CLAIM_RESOLUTION, 12 minutes);
    }

    function test_claim_filing_stake_lock() public {
        cell.setParam(CellParamIds.CLAIM_FILING_STAKE, 50 ether);
        cell.lockParam(CellParamIds.CLAIM_FILING_STAKE);
        vm.expectRevert(CellLogicLib.ParamLockedErr.selector);
        cell.setParam(CellParamIds.CLAIM_FILING_STAKE, 51 ether);
    }

    function test_canonical_threshold_lock() public {
        cell.setParam(CellParamIds.CANONICAL_THRESHOLD, 20);
        cell.lockParam(CellParamIds.CANONICAL_THRESHOLD);
        vm.expectRevert(CellLogicLib.ParamLockedErr.selector);
        cell.setParam(CellParamIds.CANONICAL_THRESHOLD, 21);
    }

    function test_discovery_economics_setters_and_locks() public {
        cell.setParam(CellParamIds.MAX_BOOST, 6);
        cell.setParam(CellParamIds.DISCOVERY_CAP, 600);
        cell.setParam(CellParamIds.DISCOVERY_FLOOR, 4000);
        assertEq(cell.maxBoostFactor(), 6);
        assertEq(cell.discoveryCapBps(), 600);
        assertEq(cell.discoveryFloorBps(), 4000);

        cell.lockParam(CellParamIds.MAX_BOOST);
        cell.lockParam(CellParamIds.DISCOVERY_CAP);
        cell.lockParam(CellParamIds.DISCOVERY_FLOOR);

        vm.expectRevert(CellLogicLib.ParamLockedErr.selector);
        cell.setParam(CellParamIds.MAX_BOOST, 7);
        vm.expectRevert(CellLogicLib.ParamLockedErr.selector);
        cell.setParam(CellParamIds.DISCOVERY_CAP, 700);
        vm.expectRevert(CellLogicLib.ParamLockedErr.selector);
        cell.setParam(CellParamIds.DISCOVERY_FLOOR, 4500);
    }

    function test_dispute_module_swap_blocked_when_locked() public {
        address replacement = address(0xDEAD);
        cell.lockParam(CellParamIds.DISPUTE_MODULES);
        vm.expectRevert(AuditCell.ParamLockedErr.selector);
        cell.setDisputeModule(0, replacement);
    }

    function test_lock_param_idempotent_reverts() public {
        cell.lockParam(CellParamIds.CLAIM_RESOLUTION);
        vm.expectRevert(CellLogicLib.AlreadyLocked.selector);
        cell.lockParam(CellParamIds.CLAIM_RESOLUTION);
    }

    function test_invalid_param_id_reverts() public {
        vm.expectRevert(CellLogicLib.InvalidParamId.selector);
        cell.lockParam(CellParamIds.ID_MAX + 1);
        vm.expectRevert(CellLogicLib.InvalidParamId.selector);
        cell.paramLocked(CellParamIds.ID_MAX + 1);
    }
}

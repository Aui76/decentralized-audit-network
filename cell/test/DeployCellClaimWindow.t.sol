// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "./helpers/CellTestDeploy.sol";
import "../script/DeployCell.s.sol";
import "../contracts/CellParamIds.sol";

contract DeployCellWindowHarness is DeployCell {
    function guard(AuditCell cell) external view {
        _requireClaimWindowCoversAuditorPath(cell);
    }

    /// G6 (PC-106): the testnet profile now also sets the stake floors, so it needs every module that carries one.
    function applyTestnet(Deployed memory dd) external {
        _applyTestnetTimeProfile(dd);
    }
}

/// @notice PC-88(a) / VD-182 (2026-09-15). The canonical cell shipped claimResolutionWindow 600 s beside decision 300 s,
///         in-audit 600 s and min-audit 600 s, so every dispute was expirable before its drawn auditor, using its own
///         windows, could reach a settled verdict - cured on chain that evening by setParam(0, 1800). These tests keep the
///         next cell from shipping it: DeployCell refuses a cell whose claim window is shorter than the auditor's path, and
///         the testnet profile itself now satisfies the rule.
contract DeployCellClaimWindowTest is Test {
    CellTestDeploy.Deployment d;
    DeployCellWindowHarness h;

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        h = new DeployCellWindowHarness();
    }

    function _sum() internal view returns (uint256) {
        return d.cell.decisionWindow() + d.cell.inAuditWindow() + d.cell.minAuditWindow();
    }

    function test_constructor_defaults_satisfy_the_rule() public view {
        assertGe(d.cell.claimResolutionWindow(), _sum(), "30 days >= 1 + 7 + 14 days");
        h.guard(d.cell);
    }

    /// RED before the guard: the shipped testnet values passed silently.
    function test_guard_REFUSES_the_shipped_testnet_values() public {
        d.cell.setParam(CellParamIds.DECISION, 5 minutes);
        d.cell.setParam(CellParamIds.IN_AUDIT, 10 minutes);
        d.cell.setParam(CellParamIds.MIN_AUDIT, 10 minutes);
        d.cell.setParam(CellParamIds.CLAIM_RESOLUTION, 10 minutes);
        vm.expectRevert();
        h.guard(d.cell);
    }

    /// RED before the profile fix: the testnet profile set 10 minutes against a 25-minute path.
    function test_the_testnet_profile_itself_satisfies_the_rule() public {
        DeployCell.Deployed memory dd;
        dd.cell = d.cell;
        dd.claimModule = d.claimModule;
        dd.specArbiterModule = d.specArbiterModule;
        dd.integrityReviewModule = d.integrityReviewModule;
        dd.structuralUpgradeModule = d.structuralUpgradeModule;
        d.cell.transferAdmin(address(h));
        d.claimModule.transferAdmin(address(h));
        d.specArbiterModule.transferAdmin(address(h));
        d.integrityReviewModule.transferAdmin(address(h));
        d.structuralUpgradeModule.transferAdmin(address(h));
        h.applyTestnet(dd);
        assertGe(d.cell.claimResolutionWindow(), _sum(), "testnet claim window covers decision + in-audit + min-audit");
        h.guard(d.cell);
    }
}

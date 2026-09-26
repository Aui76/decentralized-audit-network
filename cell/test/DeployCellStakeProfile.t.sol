// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./helpers/SpecValidationCellSetup.sol";
import "../script/DeployCell.s.sol";

contract StakeProfileTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

contract DeployCellStakeProfileHarness is DeployCell {
    function applyTestnet(Deployed memory dd) external {
        _applyTestnetTimeProfile(dd);
    }
}

/// @notice PC-106 (G6, VD-202(3)(a)): THE TESTNET PROFILE COULD NOT RUN ITS OWN MILESTONES. Every stake floor the milestones
///         need - the claim filing stake, the spec-challenge stake, the integrity filing and contest stakes, the gap filing
///         stake - was 100 AUDIT or more, while the only liquid AUDIT a fresh cell has after genesis is the genesis auditor's
///         reward (78.125 on the canonical cell). So the acceptance rehearsal of the cured hull (G-l on the next cell) would
///         fail on its first day for want of a stake the network cannot yet have minted.
///
///         The liquid supply is MEASURED here by running a real genesis on a fresh cell, not typed: the number moves with the
///         issuance module, and a typed number is how the old floors went stale. RED on the old profile: 100 > liquid.
contract DeployCellStakeProfileTest is SpecValidationCellSetup {
    CellTestDeploy.Deployment d;
    DeployCellStakeProfileHarness h;

    address genesisAuditor = address(0xA11CE);
    bytes32 specToolId = keccak256("spec-tool");
    bytes32 verdictToolId = keccak256("audit-tool");

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        CellTestDeploy.attachMinter(d);
        h = new DeployCellStakeProfileHarness();
    }

    /// Genesis exactly as the ladder runs it: the auditor registers, the admin submits the genesis audit (declared-unfunded),
    /// the auditor passes it, and confirm mints the first positive block. What the auditor then holds is the network's
    /// entire liquid AUDIT - the deployer holds none, and the escrow's share is not spendable.
    function _postGenesisLiquid() internal returns (uint256) {
        vm.prank(genesisAuditor);
        d.cell.register();
        StakeProfileTarget t = new StakeProfileTarget(1);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        uint256 id = d.cell.submitGenesisAudit(
            address(t), address(t).codehash, keccak256("genesis-spec"), specToolId, EMPTY_SPEC_ERRORS, 5000 ether, declared, 0, 0
        );
        d.cell.protocolAcceptAuditor(id);
        vm.prank(genesisAuditor);
        d.cell.acceptAudit(id, EMPTY_SPEC_ERRORS);
        vm.prank(genesisAuditor);
        d.cell.provePass(id, verdictToolId, keccak256("genesis-pass"));
        vm.warp(block.timestamp + d.cell.auditWindowOf(id));
        d.cell.confirmAudit(id);
        assertFalse(d.cell.genesisPending(), "fixture: genesis completed");
        return d.token.balanceOf(genesisAuditor);
    }

    function _applyTestnetProfile() internal {
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
    }

    function test_G6_every_milestone_stake_floor_fits_the_liquid_supply_after_genesis() public {
        uint256 liquid = _postGenesisLiquid();
        assertGt(liquid, 0, "fixture: genesis minted something");
        _applyTestnetProfile();

        assertLe(d.cell.claimFilingStake(), liquid, "claim filing stake (Phase D) fits");
        assertLe(d.specArbiterModule.specChallengeStake(), liquid, "spec-challenge stake (F1) fits");
        assertLe(d.integrityReviewModule.integrityFilingStake(), liquid, "integrity filing stake (F3) fits");
        assertLe(d.integrityReviewModule.integrityContestStake(), liquid, "integrity contest stake fits");
        assertLe(d.structuralUpgradeModule.gapFilingStake(), liquid, "gap filing stake (Phase G) fits");
    }

    /// VD-117's rule survives the lower floors: the spec-challenge fee stays strictly below its stake on the testnet profile.
    function test_G6_the_testnet_spec_challenge_fee_stays_below_its_stake() public {
        _applyTestnetProfile();
        // Read by signature so the file compiles on the pre-G6 script, where the constant does not exist.
        (bool ok, bytes memory ret) = address(h).staticcall(abi.encodeWithSignature("SPEC_CHALLENGE_FEE_TESTNET()"));
        assertTrue(ok, "the testnet profile declares its own spec-challenge fee");
        assertLt(abi.decode(ret, (uint256)), d.specArbiterModule.specChallengeStake(), "fee < stake (VD-117)");
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/StdStorage.sol";
import "./helpers/SpecValidationCellSetup.sol";
import "../contracts/CellParamIds.sol";
import "../contracts/CellEscrow.sol";

import "./StructuralUpgradeFlowCell.t.sol";

/// @notice R2 oracle — pass/adopt escrow tranche split (cathedral: test_full_structural_upgrade_adopt_split_escrow).
contract StructuralUpgradeTranchesCellTest is StructuralUpgradeFlowCellTest {
    using stdStorage for StdStorage;

    CellEscrow escrow;

    function setUp() public override {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        issuance = d.issuance;
        structural = d.structuralUpgradeModule;
        escrow = d.escrow;
        CellTestDeploy.registerDefaultTools(d, specToolId, harnessToolId);
        cell.registerTool(opsToolId, false);

        canonical = new CanonicalTarget();
        fixContract = new FixTarget();

        structural.setGapFilingStake(0);
        structural.setJuryAdoptThresholds(1, 1);
        structural.setJuryVoteParams(1, 1);
        structural.setJuryCredibilityParams(5, 8000, 0, 0);
        structural.setOpsRegressionWindow(1 days);
        structural.setCanonicalPromotionDuration(1 days);
        cell.setParam(CellParamIds.MIN_AUDIT, cell.MIN_AUDIT_WINDOW());

        token.genesisMint(filer, 200_000 ether);
        token.genesisMint(gapAuditor, 50_000 ether);
        token.genesisMint(fixAuditor, 50_000 ether);
        token.genesisMint(juror, 50_000 ether);
        token.genesisMint(address(this), 500_000 ether);
        CellTestDeploy.attachMinter(d);

        vm.prank(filer);
        cell.register();
        vm.prank(gapAuditor);
        cell.register();
        vm.prank(fixAuditor);
        cell.register();
        vm.prank(juror);
        cell.register();

        stdstore.target(address(cell)).sig("auditors(address)").with_key(filer).depth(0).checked_write(3);
    }

    function _fundEscrow() internal {
        token.transfer(address(escrow), 50_000 ether);
        vm.prank(address(cell));
        escrow.recordDeposit(50_000 ether);
    }

    function _expectedTranchePayout(uint256 trancheTarget, uint256 escrowBal) internal view returns (uint256) {
        uint256 cap = (escrowBal * structural.upgradeClaimCapBps()) / 10_000;
        return trancheTarget < cap ? trancheTarget : cap;
    }

    function test_full_structural_upgrade_adopt_split_escrow() external {
        _fundEscrow();
        (uint256 gapId, uint256 fixId) = _probationAfterFixConfirm();
        uint256 workId = _submitWorkAudit();
        _voteOk(gapId, workId);

        uint256 fullTarget = structural.upgradeProposalPayoutTarget(filer);
        uint256 passTarget = (fullTarget * structural.passPayoutBps()) / 10_000;
        uint256 adoptTarget = fullTarget > passTarget ? fullTarget - passTarget : 0;
        uint256 escrowBeforePass = escrow.escrowBalance();
        uint256 expectedPassPaid = _expectedTranchePayout(passTarget, escrowBeforePass);

        uint256 balBeforePass = token.balanceOf(filer);
        vm.prank(filer);
        uint256 passPaid = structural.claimStructuralUpgradeEscrow(
            fixId, StructuralUpgradeModule.EscrowTranche.Pass
        );
        assertEq(passPaid, expectedPassPaid);
        assertEq(token.balanceOf(filer) - balBeforePass, expectedPassPaid);

        uint256 balBeforeAdopt = token.balanceOf(filer);
        uint256 expectedMint = issuance.upgradeAdoptMintAmount();
        assertGt(expectedMint, 0);

        structural.adoptStructuralUpgrade(gapId);

        assertEq(structural.canonicalContractAuditId(address(fixContract)), fixId);
        assertEq(
            uint256(structural.canonicalTier(address(fixContract))),
            uint256(StructuralUpgradeModule.CanonicalTier.Probationary)
        );
        assertEq(uint256(structural.gapStateOf(gapId)), uint256(StructuralUpgradeModule.GapState.Adopted));

        uint256 escrowBeforeAdopt = escrowBeforePass - expectedPassPaid;
        uint256 expectedAdoptPaid = _expectedTranchePayout(adoptTarget, escrowBeforeAdopt);
        assertGe(token.balanceOf(filer) - balBeforeAdopt, expectedAdoptPaid + expectedMint);

        vm.prank(filer);
        vm.expectRevert(StructuralUpgradeModule.PassTrancheClaimed.selector);
        structural.claimStructuralUpgradeEscrow(fixId, StructuralUpgradeModule.EscrowTranche.Pass);

        vm.prank(filer);
        vm.expectRevert(StructuralUpgradeModule.AdoptTrancheClaimed.selector);
        structural.claimStructuralUpgradeEscrow(fixId, StructuralUpgradeModule.EscrowTranche.Adopt);
    }

    function test_pass_tranche_requires_probation_or_adopted() external {
        _fundEscrow();
        vm.startPrank(filer);
        token.approve(address(cell), 2_000 ether);
        uint256 gapAuditId;
        uint256 gapId;
        (gapId, gapAuditId) = structural.fileNetworkGap(
            address(canonical),
            gapSpecHash,
            harnessToolId,
            specToolId,
            EMPTY_SPEC_ERRORS,
            500 ether
        );
        vm.stopPrank();

        _assignedAccept(gapAuditId);
        vm.prank(cell.auditAuditorOf(gapAuditId));
        structural.proveGapFail(gapAuditId, harnessToolId, _resultRoot("gap-fail"));

        vm.startPrank(filer);
        token.approve(address(cell), 2_000 ether);
        uint256 fixId = structural.submitStructuralFix(
            address(fixContract),
            specHash,
            specToolId,
            EMPTY_SPEC_ERRORS,
            1_000 ether,
            gapId
        );
        vm.stopPrank();

        _assignedAccept(fixId);
        vm.prank(cell.auditAuditorOf(fixId));
        cell.provePass(fixId, harnessToolId, _resultRoot("fix-pass"));
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(fixId);
        assertEq(uint256(structural.gapStateOf(gapId)), uint256(StructuralUpgradeModule.GapState.FixInAudit));

        vm.prank(filer);
        vm.expectRevert(StructuralUpgradeModule.NotReadyForPassClaim.selector);
        structural.claimStructuralUpgradeEscrow(fixId, StructuralUpgradeModule.EscrowTranche.Pass);
    }

    function test_adopt_tranche_only_on_adopt() external {
        _fundEscrow();
        (uint256 gapId, uint256 fixId) = _probationAfterFixConfirm();
        uint256 workId = _submitWorkAudit();
        _voteOk(gapId, workId);

        vm.prank(filer);
        vm.expectRevert(StructuralUpgradeModule.NotAdopted.selector);
        structural.claimStructuralUpgradeEscrow(fixId, StructuralUpgradeModule.EscrowTranche.Adopt);
    }
}

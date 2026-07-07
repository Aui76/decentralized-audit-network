// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./helpers/SpecValidationCellSetup.sol";
import "../contracts/CellParamIds.sol";
import "../contracts/CellStorage.sol";
import "../contracts/StructuralUpgradeModule.sol";

contract CanonicalTarget {
    uint256 public version = 1;
}

contract FixTarget {
    uint256 public version = 2;
}

/// @notice F-41 structural upgrade on puzzle cell + StructuralUpgradeModule (X5 oracle).
contract StructuralUpgradeFlowCellTest is SpecValidationCellSetup {
    CellToken token;
    AuditCell cell;
    IssuanceModule issuance;
    StructuralUpgradeModule structural;

    CanonicalTarget canonical;
    FixTarget fixContract;

    address filer = address(0xF11E);
    address gapAuditor = address(0xA11CE);
    address fixAuditor = address(0xCAFE);
    address juror = address(0xB000);

    bytes32 specToolId = keccak256("spec-tool");
    bytes32 specHash = keccak256("spec-hash");
    bytes32 harnessToolId = keccak256("harness-tool");
    bytes32 opsToolId = keccak256("ops-tool");
    bytes32 gapSpecHash = keccak256("gap-spec");
    bytes32 opsSpecHash = keccak256("ops-spec");

    function setUp() public virtual {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        issuance = d.issuance;
        structural = d.structuralUpgradeModule;
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
    }

    function _resultRoot(string memory label) internal pure returns (bytes32) {
        return keccak256(bytes(label));
    }

    function _assignedAccept(uint256 auditId) internal {
        address assigned = cell.auditAuditorOf(auditId);
        vm.prank(assigned);
        cell.acceptAudit(auditId, EMPTY_SPEC_ERRORS);
    }

    function _probationAfterFixConfirm() internal returns (uint256 gapId, uint256 fixId) {
        vm.startPrank(filer);
        token.approve(address(cell), 2_000 ether);
        uint256 gapAuditId;
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
        fixId = structural.submitStructuralFix(
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
        structural.beginProbationAfterFixConfirm(fixId);

        assertEq(uint256(structural.gapStateOf(gapId)), uint256(StructuralUpgradeModule.GapState.Probation));
        assertEq(structural.canonicalContractAuditId(address(fixContract)), 0);
    }

    function _submitWorkAudit() internal returns (uint256 workId) {
        address protocol = address(0xD000);
        token.transfer(protocol, 50_000 ether);
        vm.startPrank(protocol);
        token.approve(address(cell), 10_000 ether);
        bytes32[] memory tools = new bytes32[](1);
        tools[0] = harnessToolId;
        workId = cell.submitAudit(
            address(canonical),
            address(canonical).codehash,
            specHash,
            specToolId,
            EMPTY_SPEC_ERRORS,
            10_000 ether,
            tools,
            0,
            0
        );
        vm.stopPrank();
        _reachAwaitingWindow(cell, workId, protocol, harnessToolId, _resultRoot("work-pass"));
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(workId);
    }

    function _voteOk(uint256 gapId, uint256 workId) internal {
        address workAuditor = cell.auditAuditorOf(workId);
        vm.prank(workAuditor);
        structural.voteStructuralUpgrade(gapId, true, workId);
    }

    function test_adopt_probationary_and_upg_mint() external {
        (uint256 gapId, uint256 fixId) = _probationAfterFixConfirm();
        uint256 workId = _submitWorkAudit();
        _voteOk(gapId, workId);

        uint256 before = token.balanceOf(filer);
        structural.adoptStructuralUpgrade(gapId);

        assertEq(structural.canonicalContractAuditId(address(fixContract)), fixId);
        assertEq(uint256(structural.canonicalTier(address(fixContract))), uint256(StructuralUpgradeModule.CanonicalTier.Probationary));
        assertGe(token.balanceOf(filer) - before, issuance.upgradeAdoptMintAmount());
    }

    function test_promote_after_duration() external {
        (uint256 gapId,) = _probationAfterFixConfirm();
        uint256 workId = _submitWorkAudit();
        _voteOk(gapId, workId);
        structural.adoptStructuralUpgrade(gapId);

        vm.warp(block.timestamp + 1 days);
        structural.promoteCanonicalToOfficial(gapId);
        assertEq(uint256(structural.canonicalTier(address(fixContract))), uint256(StructuralUpgradeModule.CanonicalTier.Official));
    }

    function test_rollback_probationary_only_F45() external {
        (uint256 gapId,) = _probationAfterFixConfirm();
        uint256 workId = _submitWorkAudit();
        _voteOk(gapId, workId);
        structural.adoptStructuralUpgrade(gapId);

        vm.warp(block.timestamp + 1 days);
        structural.promoteCanonicalToOfficial(gapId);

        vm.prank(juror);
        vm.expectRevert(StructuralUpgradeModule.AlreadyOfficial.selector);
        structural.rollbackStructuralUpgrade(gapId, opsSpecHash, opsToolId, _resultRoot("ops"));
    }

    function test_gap_filing_against_probationary_reverts() external {
        (uint256 gapId,) = _probationAfterFixConfirm();
        uint256 workId = _submitWorkAudit();
        _voteOk(gapId, workId);
        structural.adoptStructuralUpgrade(gapId);

        vm.startPrank(filer);
        token.approve(address(cell), 1_000 ether);
        vm.expectRevert(StructuralUpgradeModule.CanonicalNotOfficial.selector);
        structural.fileNetworkGap(
            address(fixContract),
            gapSpecHash,
            harnessToolId,
            specToolId,
            EMPTY_SPEC_ERRORS,
            500 ether
        );
        vm.stopPrank();
    }

    function test_fix_confirm_does_not_settle_unrelated_claim() external {
        address protocol = address(0xBEEF);
        token.transfer(protocol, 100_000 ether);
        vm.prank(protocol);
        cell.register();

        vm.startPrank(protocol);
        token.approve(address(cell), 20_000 ether);
        bytes32[] memory tools = new bytes32[](1);
        tools[0] = harnessToolId;
        uint256 originalId = cell.submitAudit(
            address(canonical),
            address(canonical).codehash,
            specHash,
            specToolId,
            EMPTY_SPEC_ERRORS,
            10_000 ether,
            tools,
            0,
            0
        );
        vm.stopPrank();

        _reachAwaitingWindow(cell, originalId, protocol, harnessToolId, _resultRoot("orig-pass"));
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(originalId);

        address claimant = address(0xC1A1);
        token.transfer(claimant, 200_000 ether);
        vm.prank(claimant);
        cell.register();
        vm.startPrank(claimant);
        token.approve(address(cell), type(uint256).max);
        cell.claimVulnerability(originalId, harnessToolId, _resultRoot("claim"), "");
        vm.stopPrank();

        assertEq(uint256(_auditState(cell, originalId)), uint256(CellTypeDefs.AuditState.Claimed));
        _probationAfterFixConfirm();
        assertEq(uint256(_auditState(cell, originalId)), uint256(CellTypeDefs.AuditState.Claimed));
    }

    function test_gap_audit_rejects_provePass() external {
        vm.startPrank(filer);
        token.approve(address(cell), 1_000 ether);
        (, uint256 gapAuditId) = structural.fileNetworkGap(
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
        vm.expectRevert(StructuralUpgradeModule.GapAuditRequiresFail.selector);
        cell.provePass(gapAuditId, harnessToolId, _resultRoot("bad"));
    }
}

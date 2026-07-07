// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/StdStorage.sol";
import "./helpers/SpecValidationCellSetup.sol";
import "../contracts/CellParamIds.sol";
import "../contracts/StructuralUpgradeModule.sol";

import "./StructuralUpgradeFlowCell.t.sol";

contract SaltedTarget {
    uint256 public immutable salt;

    constructor(uint256 _salt) {
        salt = _salt;
    }
}

/// @notice R3 oracle — jury credibility WC tallies + confirmJuryCredit (cathedral: StructuralUpgradeFlow jury tests).
contract StructuralUpgradeJuryCredibilityCellTest is SpecValidationCellSetup {
    using stdStorage for StdStorage;

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
    bytes32 juryToolId = keccak256("jury-tool");
    uint256 queueSkipNonce;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        issuance = d.issuance;
        structural = d.structuralUpgradeModule;
        CellTestDeploy.registerDefaultTools(d, specToolId, harnessToolId);
        cell.registerTool(opsToolId, false);
        cell.registerTool(juryToolId, false);

        canonical = new CanonicalTarget();
        fixContract = new FixTarget();

        structural.setGapFilingStake(0);
        structural.setJuryAdoptThresholds(30, 30);
        structural.setJuryVoteParams(1, 1);
        structural.setJuryCredibilityParams(5, 8000, 0, 0);
        structural.setOpsRegressionWindow(1 days);
        structural.setCanonicalPromotionDuration(1 days);
        cell.setParam(CellParamIds.MIN_AUDIT, cell.MIN_AUDIT_WINDOW());

        token.genesisMint(filer, 200_000 ether);
        token.genesisMint(gapAuditor, 50_000 ether);
        token.genesisMint(fixAuditor, 50_000 ether);
        token.genesisMint(juror, 50_000 ether);
        token.genesisMint(address(this), 100_000_000 ether);
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

    function _prepJuror(address auditor, uint256 successful) internal {
        stdstore.target(address(cell)).sig("auditors(address)").with_key(auditor).depth(0).checked_write(successful);
    }

    function _bringToQueueHead(address target) internal {
        if (cell.queueHead() == target) return;
        stdstore.target(address(cell)).sig("queueHead()").checked_write(target);
    }

    function _ensureRegistered(address auditor) internal {
        (,,,,, bool inQueue) = cell.auditors(auditor);
        if (!inQueue) {
            token.transfer(auditor, 50_000 ether);
            vm.prank(auditor);
            cell.register();
        }
    }

    function _fundProtocol(address protocol, uint256 bounty) internal {
        token.transfer(protocol, bounty + 1 ether);
    }

    function _deployUniqueTarget() internal returns (address target) {
        queueSkipNonce++;
        target = address(new SaltedTarget(queueSkipNonce));
    }

    function _submitOrdinaryAuditFor(address auditor, address protocol, uint256 successful)
        internal
        returns (uint256 auditId)
    {
        _ensureRegistered(auditor);
        _prepJuror(auditor, successful);
        _fundProtocol(protocol, 5_000 ether);
        _bringToQueueHead(auditor);

        vm.startPrank(protocol);
        token.approve(address(cell), 5_000 ether);
        bytes32[] memory tools = new bytes32[](1);
        tools[0] = juryToolId;
        address deployed = _deployUniqueTarget();
        auditId = cell.submitAudit(
            deployed,
            deployed.codehash,
            specHash,
            specToolId,
            EMPTY_SPEC_ERRORS,
            5_000 ether,
            tools,
            0,
            0
        );
        vm.stopPrank();

        assertEq(cell.auditAuditorOf(auditId), auditor);
        _reachAwaitingWindow(cell, auditId, protocol, juryToolId, _resultRoot("work-pass"));
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(auditId);
    }

    function _castJuryVotes(uint256 gapId, uint256 count, bool ok) internal {
        _castJuryVotesFrom(gapId, 0, count, ok, 5);
    }

    function _castJuryVotesFrom(uint256 gapId, uint256 startIndex, uint256 count, bool ok, uint256 successful)
        internal
    {
        for (uint256 i = 0; i < count; i++) {
            address auditor = address(uint160(0xB000 + startIndex + i));
            address protocol = address(uint160(0xC000 + startIndex + i));
            uint256 auditId = _submitOrdinaryAuditFor(auditor, protocol, successful);
            vm.prank(auditor);
            structural.voteStructuralUpgrade(gapId, ok, auditId);
        }
    }

    function test_jury_net_threshold_requires_more_ok_with_dissent() external {
        (uint256 gapId,) = _probationAfterFixConfirm();
        _castJuryVotes(gapId, 30, true);
        _castJuryVotesFrom(gapId, 30, 5, false, 10);

        (uint256 ok, uint256 notOk) = structural.juryTallyForGap(gapId);
        assertEq(ok, 30);
        assertEq(notOk, 5);

        (uint256 okW, uint256 notOkW) = structural.juryTallyWeightedForGap(gapId);
        assertEq(okW, 30);
        assertEq(notOkW, 15);

        vm.expectRevert(StructuralUpgradeModule.JuryThresholdNotMet.selector);
        structural.adoptStructuralUpgrade(gapId);

        _castJuryVotesFrom(gapId, 35, 15, true, 5);

        (okW, notOkW) = structural.juryTallyWeightedForGap(gapId);
        assertGe(okW, 45);
        assertEq(notOkW, 15);
        assertTrue(structural.juryAdoptReady(gapId));
        structural.adoptStructuralUpgrade(gapId);
    }

    function test_confirmJuryCredit_increments_correct_ok_count() external {
        structural.setJuryAdoptThresholds(1, 1);
        (uint256 gapId,) = _probationAfterFixConfirm();
        uint256 workId = _submitWorkAudit();
        address workAuditor = cell.auditAuditorOf(workId);
        vm.prank(workAuditor);
        structural.voteStructuralUpgrade(gapId, true, workId);
        structural.adoptStructuralUpgrade(gapId);

        assertEq(structural.jurorCorrectOkVoteCount(workAuditor), 0);
        vm.warp(block.timestamp + 1 days);
        vm.prank(workAuditor);
        structural.confirmJuryCredit(gapId);
        assertEq(structural.jurorCorrectOkVoteCount(workAuditor), 1);

        vm.prank(workAuditor);
        vm.expectRevert(StructuralUpgradeModule.CreditAlreadyClaimed.selector);
        structural.confirmJuryCredit(gapId);
    }

    function test_jury_credibility_wc_gate_blocks_when_dissent_dominates_wc() external {
        structural.setJuryCredibilityParams(5, 8000, 3000, 3000);
        (uint256 gapId,) = _probationAfterFixConfirm();
        _castJuryVotes(gapId, 30, true);
        _castJuryVotesFrom(gapId, 30, 30, false, 10);

        (uint256 okWC, uint256 notOkWC) = structural.juryTallyCredibilityForGap(gapId);
        assertGt(notOkWC, okWC);

        vm.expectRevert(StructuralUpgradeModule.JuryThresholdNotMet.selector);
        structural.adoptStructuralUpgrade(gapId);
    }
}

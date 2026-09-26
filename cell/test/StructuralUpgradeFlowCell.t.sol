// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./helpers/SpecValidationCellSetup.sol";
import "../contracts/CellParamIds.sol";
import "../contracts/CellStorage.sol";
import "../contracts/StructuralUpgradeModule.sol";
import "../contracts/ClaimDisputeModule.sol";

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
    ClaimDisputeModule claimModule;

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
        claimModule = d.claimModule;
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
        structural.rollbackStructuralUpgrade(gapId, opsSpecHash, opsToolId, _resultRoot("ops"), 0);
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

    // ================================================================================================
    // bug_001 (DEC-44 paid review; remedy ruled by VD-143(1)) — the rollback's THREE witness parameters
    // were checked for SHAPE only: non-zero, a registered non-spec tool. Never compared to state, never
    // stored, never emitted. So any registered eligible non-proposer could, inside opsRegressionWindow,
    // un-adopt a legitimate upgrade AND slash its proposer for FREE, with a fabricated proof that the
    // chain kept no record of.
    //
    // RED HALF FIRST: `_fabricatedWitness` below SUCCEEDS against the unfixed module, and that success is
    // the defect measured. The control that follows is the half that stops the fix being "revert always".
    // ================================================================================================

    /// Drive an audit on `target` all the way to `Exploited` - the ONE state the cell writes for an
    /// ADJUDICATED failure, and the predicate VD-153 ruled after this fix's first writing used `InBlock`
    /// and the control test caught it.
    ///
    /// The route is the realistic one: a discoverer claims against a passed audit, the protocol opens a
    /// dispute re-audit, and a SECOND auditor reproduces the failure under stake. That is what a rollback
    /// now costs. `stopBeforeDispute` leaves the claim unresolved - the red half for a regression that was
    /// alleged and never adjudicated.
    function _exploitedWitness(address target, bytes32 spec, bytes32 tool, bytes32 root, bool stopBeforeDispute)
        internal
        returns (uint256 id)
    {
        address[4] memory pool = [filer, gapAuditor, fixAuditor, juror];
        for (uint256 i = 0; i < pool.length; i++) {
            vm.prank(pool[i]);
            token.approve(address(cell), type(uint256).max);
        }
        address wProtocol = address(0xD222);
        address discoverer = address(0xD333);
        token.transfer(wProtocol, 100_000 ether);
        token.transfer(discoverer, 100_000 ether);
        vm.prank(discoverer);
        cell.register();

        vm.startPrank(wProtocol);
        token.approve(address(cell), type(uint256).max);
        bytes32[] memory tools = new bytes32[](1);
        tools[0] = tool;
        id = cell.submitAudit(
            target, target.codehash, spec, specToolId, EMPTY_SPEC_ERRORS, 10_000 ether, tools, 0, 0
        );
        vm.stopPrank();
        _protocolAcceptAndAssignedAccept(cell, id, wProtocol, EMPTY_SPEC_ERRORS);
        vm.prank(cell.auditAuditorOf(id));
        cell.provePass(id, tool, _resultRoot("witness-pass"));

        // THE CLAIM RECORD is what the fix reads - not the audit's verdict fields, which on this path
        // still describe the PASS being overturned. That is VD-153's correction, and this helper is the
        // only place a test could have noticed it.
        vm.startPrank(discoverer);
        token.approve(address(cell), type(uint256).max);
        cell.claimVulnerability(id, tool, root, "");
        vm.stopPrank();
        if (stopBeforeDispute) return id;

        vm.startPrank(wProtocol);
        token.approve(address(cell), type(uint256).max);
        uint256 disputeId = claimModule.openDisputeReaudit(id, (10_000 ether * 5000) / 10_000);
        vm.stopPrank();
        address da = cell.auditAuditorOf(disputeId);
        vm.prank(da);
        cell.acceptAudit(disputeId, EMPTY_SPEC_ERRORS);
        vm.prank(da);
        cell.proveFail(disputeId, tool, root);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Exploited));
    }

    function _adopted() internal returns (uint256 gapId) {
        (gapId,) = _probationAfterFixConfirm();
        _voteOk(gapId, _submitWorkAudit());
        structural.adoptStructuralUpgrade(gapId);
    }

    /// CONTROL, and VD-143(1)'s third acceptance clause: the event carries the witness and the roller,
    /// and the witness is STORED. Without this a regression that drops a field from the emit stays green.
    function test_rollback_accepts_an_adjudicated_regression_bug001() external {
        uint256 gapId = _adopted();
        bytes32 root = _resultRoot("ops-fail");
        uint256 w = _exploitedWitness(address(fixContract), opsSpecHash, opsToolId, root, false);
        uint256 failedBefore = _auditorFailed(cell, filer);

        // The EMIT half, asserted from the log rather than predicted: `blockHash` is derived inside the
        // cell and cannot be known here, so `vm.expectEmit` would either check nothing useful or force the
        // test to reimplement the hash. Recording and decoding checks the fields that matter - and it is
        // the clause VD-143(1) named and the first writing of these tests left untested, so a regression
        // that dropped a field from the emit stayed green.
        vm.recordLogs();
        vm.prank(juror);
        structural.rollbackStructuralUpgrade(gapId, opsSpecHash, opsToolId, root, w);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(structural)) continue;
            if (logs[i].topics[0] != keccak256(
                "StructuralUpgradeRolledBack(uint256,uint256,uint256,address,bytes32,uint256,bytes32,bytes32,bytes32)"
            )) continue;
            seen = true;
            assertEq(uint256(logs[i].topics[1]), gapId, "event: gapId");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), juror, "event: the ROLLER");
            // data is priorCanonicalAuditId, blockHash, then the four witness fields - SIX values, not
            // five. The first writing skipped one and decoded the block hash as the audit id.
            (,, uint256 evOps, bytes32 evSpec, bytes32 evTool, bytes32 evRoot) =
                abi.decode(logs[i].data, (uint256, bytes32, uint256, bytes32, bytes32, bytes32));
            assertEq(evOps, w, "event: the witness audit");
            assertEq(evSpec, opsSpecHash, "event: the ops spec hash");
            assertEq(evTool, opsToolId, "event: the tool");
            assertEq(evRoot, root, "event: the result root");
        }
        assertTrue(seen, "the rollback event was not emitted at all");

        assertEq(uint256(structural.gapStateOf(gapId)), uint256(StructuralUpgradeModule.GapState.RolledBack));
        assertEq(_auditorFailed(cell, filer), failedBefore + 1);
        assertEq(structural.rollbackWitnessAuditId(gapId), w, "the STORE half of VD-143(1)");
    }

    /// RED: alleged and never adjudicated - a free grief with one extra step, which a looser predicate
    /// than VD-153's would have waved through.
    function test_rollback_refuses_an_unadjudicated_claim_bug001() external {
        uint256 gapId = _adopted();
        bytes32 root = _resultRoot("ops-fail");
        uint256 w = _exploitedWitness(address(fixContract), opsSpecHash, opsToolId, root, true);

        vm.prank(juror);
        vm.expectRevert(StructuralUpgradeModule.WitnessNotUpheld.selector);
        structural.rollbackStructuralUpgrade(gapId, opsSpecHash, opsToolId, root, w);
    }

    /// RED: a real adjudicated regression - against a DIFFERENT contract.
    function test_rollback_refuses_a_witness_against_another_contract_bug001() external {
        uint256 gapId = _adopted();
        bytes32 root = _resultRoot("ops-fail");
        uint256 w = _exploitedWitness(address(canonical), opsSpecHash, opsToolId, root, false);

        vm.prank(juror);
        vm.expectRevert(StructuralUpgradeModule.WitnessTargetMismatch.selector);
        structural.rollbackStructuralUpgrade(gapId, opsSpecHash, opsToolId, root, w);
    }

    /// RED: the result root claimed here is not the one the claim record holds - the fabrication the
    /// original defect waved straight through.
    function test_rollback_refuses_a_fabricated_result_root_bug001() external {
        uint256 gapId = _adopted();
        uint256 w =
            _exploitedWitness(address(fixContract), opsSpecHash, opsToolId, _resultRoot("ops-fail"), false);

        vm.prank(juror);
        vm.expectRevert(StructuralUpgradeModule.WitnessResultMismatch.selector);
        structural.rollbackStructuralUpgrade(gapId, opsSpecHash, opsToolId, _resultRoot("fabricated"), w);
    }

    /// RED: a real adjudicated regression, credited to the wrong tool.
    function test_rollback_refuses_a_wrong_tool_bug001() external {
        uint256 gapId = _adopted();
        bytes32 root = _resultRoot("ops-fail");
        uint256 w = _exploitedWitness(address(fixContract), opsSpecHash, opsToolId, root, false);

        vm.prank(juror);
        vm.expectRevert(StructuralUpgradeModule.WitnessToolMismatch.selector);
        structural.rollbackStructuralUpgrade(gapId, opsSpecHash, harnessToolId, root, w);
    }

    /// RED: the spec hash the parameter advertises is not the one the witness audit ran under. The vault
    /// read this check as impossible without new cell bytes against AuditCell's 87; `AuditCell.audits()`
    /// already returns specHash, so it is module-side and costs the cell nothing.
    function test_rollback_refuses_a_wrong_spec_hash_bug001() external {
        uint256 gapId = _adopted();
        bytes32 root = _resultRoot("ops-fail");
        uint256 w = _exploitedWitness(address(fixContract), opsSpecHash, opsToolId, root, false);

        vm.prank(juror);
        vm.expectRevert(StructuralUpgradeModule.WitnessSpecMismatch.selector);
        structural.rollbackStructuralUpgrade(gapId, gapSpecHash, opsToolId, root, w);
    }
}

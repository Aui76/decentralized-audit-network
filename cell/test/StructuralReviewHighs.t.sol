// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./helpers/SpecValidationCellSetup.sol";
import "../contracts/CellParamIds.sol";
import "../contracts/StructuralUpgradeModule.sol";
import "../contracts/SpecArbiterModule.sol";

contract SRCanonical {
    uint256 public version = 1;
}

contract SRFix {
    uint256 public version = 2;
}

/// @notice The structural lane's three linked HIGH findings from the 2026-09-15 second-family review of the fresh scope
///         (VD-180; record OnAir/records/REVIEW-2026-09-15-cursor-cli-gpt56sol-fresh-scope.md, its bug_008, bug_010,
///         bug_011), REPRODUCED here as pins and FLIPPED in the hull window's G4(b) and G4(d) (PC-92).
///
///         The two "void" cases drive `AuditCell.settlementOverlay(0, 2, id, ...)` AS the spec-arbiter module - the exact
///         call `SpecArbiterModule` makes when a challenge voids a Submitted or Assigned row - rather than a full
///         challenge, so the assertion is about what the cell and the structural module do with that void.
///
///         G4(d)'s exit is PERMISSIONLESS and pulled, not pushed: `recoverStructuralGap` reads the cell's row and moves a
///         gap whose audit ended without its outcome to a state with an exit. No cell callback, so no cell bytes, and no
///         counterparty whose call must succeed (I4). It is reached through an encoded signature so the file compiles on
///         the pre-G4 bytes and goes red there.
contract StructuralReviewHighsTest is SpecValidationCellSetup {
    CellTestDeploy.Deployment d;
    CellToken token;
    AuditCell cell;
    StructuralUpgradeModule structural;
    SpecArbiterModule specArbiter;

    SRCanonical canonical;
    SRFix fixContract;

    address filer = address(0xF11E);
    address gapAuditor = address(0xA11CE);
    address fixAuditor = address(0xCAFE);
    address challenger = address(0xC4A1);

    bytes32 specToolId = keccak256("spec-tool");
    bytes32 specHash = keccak256("spec-hash");
    bytes32 harnessToolId = keccak256("harness-tool");
    bytes32 gapSpecHash = keccak256("gap-spec");
    bytes32 failErrorsRoot = keccak256("spec-tool-errors");

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        structural = d.structuralUpgradeModule;
        specArbiter = d.specArbiterModule;
        CellTestDeploy.registerDefaultTools(d, specToolId, harnessToolId);
        canonical = new SRCanonical();
        fixContract = new SRFix();

        structural.setGapFilingStake(0);
        specArbiter.setSpecChallengeFee(100 ether);
        specArbiter.setSpecChallengeStake(500 ether);
        cell.setParam(CellParamIds.MIN_AUDIT, cell.MIN_AUDIT_WINDOW());

        token.genesisMint(filer, 200_000 ether);
        token.genesisMint(gapAuditor, 50_000 ether);
        token.genesisMint(fixAuditor, 50_000 ether);
        token.genesisMint(challenger, 10_000 ether);
        CellTestDeploy.attachMinter(d);

        vm.prank(filer);
        cell.register();
        vm.prank(gapAuditor);
        cell.register();
        vm.prank(fixAuditor);
        cell.register();
    }

    function _fileGap() internal returns (uint256 gapId, uint256 gapAuditId) {
        vm.startPrank(filer);
        token.approve(address(cell), 2_000 ether);
        (gapId, gapAuditId) = structural.fileNetworkGap(address(canonical), gapSpecHash, harnessToolId, specToolId,
                                                        EMPTY_SPEC_ERRORS, 500 ether);
        vm.stopPrank();
    }

    function _accept(uint256 id) internal {
        vm.prank(cell.auditAuditorOf(id));
        cell.acceptAudit(id, EMPTY_SPEC_ERRORS);
    }


    function _recover(uint256 gapId) internal returns (bool ok) {
        (ok,) = address(structural).call(abi.encodeWithSignature("recoverStructuralGap(uint256)", gapId));
    }

    /// bug_008, FLIPPED in G4(b) (I3): `proveGapFail` -> `structuralGapFailRecorded` recorded the verdict with no
    /// settlement-block check, so a LIVE spec challenge on the gap audit did not freeze it. It now refuses exactly as every
    /// ordinary verdict path does under the same challenge.
    function test_G4b_a_gap_verdict_is_refused_under_a_live_spec_challenge() public {
        (uint256 gapId, uint256 gapAuditId) = _fileGap();
        _accept(gapAuditId);
        assertEq(uint256(cell.auditStateOf(gapAuditId)), uint256(CellTypeDefs.AuditState.InAudit), "gap audit held");

        vm.startPrank(challenger);
        token.approve(address(cell), specArbiter.specChallengeStake());
        specArbiter.challengeSpecInvalid(gapAuditId, failErrorsRoot);
        vm.stopPrank();
        assertTrue(specArbiter.challengeActive(gapAuditId), "a spec challenge is live on the gap audit");

        vm.prank(cell.auditAuditorOf(gapAuditId));
        vm.expectRevert(CellLogicLib.SpecChallengeActive.selector);
        structural.proveGapFail(gapAuditId, harnessToolId, keccak256("gap-fail"));
        assertEq(uint256(structural.gapStateOf(gapId)), uint256(StructuralUpgradeModule.GapState.GapFiled),
                 "the gap waits for the challenge");
        assertEq(uint256(cell.auditStateOf(gapAuditId)), uint256(CellTypeDefs.AuditState.InAudit), "and so does its audit");
    }

    /// bug_010, FLIPPED in G4(d) (I4): a fix audit that ended Invalidated left its gap in FixInAudit, and
    /// `submitStructuralFix` requires GapConfirmed, so no later fix could ever be submitted. Anyone now returns the gap to
    /// GapConfirmed, and the next fix is accepted.
    function test_G4d_a_voided_fix_audit_returns_its_gap_to_GapConfirmed() public {
        (uint256 gapId, uint256 gapAuditId) = _fileGap();
        _accept(gapAuditId);
        vm.prank(cell.auditAuditorOf(gapAuditId));
        structural.proveGapFail(gapAuditId, harnessToolId, keccak256("gap-fail"));

        vm.startPrank(filer);
        token.approve(address(cell), 2_000 ether);
        uint256 fixId = structural.submitStructuralFix(address(fixContract), specHash, specToolId, EMPTY_SPEC_ERRORS,
                                                       1_000 ether, gapId);
        vm.stopPrank();
        assertEq(uint256(structural.gapStateOf(gapId)), uint256(StructuralUpgradeModule.GapState.FixInAudit));
        assertFalse(_recover(gapId), "nothing to recover while the fix audit is live");

        vm.prank(address(specArbiter)); // the spec-arbiter's void of a Submitted/Assigned row
        cell.settlementOverlay(0, 2, fixId, challenger);
        assertEq(uint256(cell.auditStateOf(fixId)), uint256(CellTypeDefs.AuditState.Invalidated), "the fix audit is void");

        vm.prank(address(0x5712A)); // permissionless
        assertTrue(_recover(gapId), "anyone recovers the gap");
        assertEq(uint256(structural.gapStateOf(gapId)), uint256(StructuralUpgradeModule.GapState.GapConfirmed),
                 "the gap is back where a fix can be submitted");
        assertEq(structural.activeStructuralFixAuditId(gapId), 0, "and its fix slot is clear (I1)");
        assertFalse(_recover(gapId), "once");

        SRFix another = new SRFix();
        vm.startPrank(filer);
        token.approve(address(cell), 2_000 ether);
        structural.submitStructuralFix(address(another), specHash, specToolId, EMPTY_SPEC_ERRORS, 1_000 ether, gapId);
        vm.stopPrank();
        assertEq(uint256(structural.gapStateOf(gapId)), uint256(StructuralUpgradeModule.GapState.FixInAudit),
                 "a second fix is in audit");
    }

    /// bug_011, FLIPPED in G4(d) (I4, VD-117): the spec-arbiter overlay voided a Submitted/Assigned structural GAP audit
    /// with no structural callback, so the NetworkGap stayed GapFiled with no audit that could ever confirm it and the
    /// filer's stake locked. Anyone now ends the gap VOIDED, and the filer's stake comes back: no adjudicated outcome, no
    /// adjudicated loser.
    function test_G4d_a_voided_gap_audit_ends_its_gap_voided_with_the_stake_refunded() public {
        structural.setGapFilingStake(250 ether);
        uint256 filerBefore = token.balanceOf(filer);
        vm.startPrank(filer);
        token.approve(address(structural), 250 ether);
        vm.stopPrank();
        (uint256 gapId, uint256 gapAuditId) = _fileGap();
        CellTypeDefs.AuditState s = cell.auditStateOf(gapAuditId);
        assertTrue(s == CellTypeDefs.AuditState.Submitted || s == CellTypeDefs.AuditState.Assigned, "precondition: voidable");
        assertFalse(_recover(gapId), "nothing to recover while the gap audit is live");

        vm.prank(address(specArbiter));
        cell.settlementOverlay(0, 2, gapAuditId, challenger);
        assertEq(uint256(cell.auditStateOf(gapAuditId)), uint256(CellTypeDefs.AuditState.Invalidated), "the gap audit is void");

        assertTrue(_recover(gapId), "anyone recovers the gap");
        assertEq(uint256(structural.gapStateOf(gapId)), 8, "GapVoided: terminal, appended to the enum");
        assertEq(filerBefore - token.balanceOf(filer), 500 ether, "the filer is out only the voided audit's own bounty");
        assertFalse(_recover(gapId), "once: the stake is refunded exactly once");
    }

    /// VD-218(4) F3: bug_004's shape on the structural lane. `proveGapFail` had no in-audit deadline, so past
    /// `pickupTime + inAuditWindow` a late gap verdict and the permissionless timeout were both valid. It now closes where the
    /// timeout opens, read from the cell's row (module side, no cell bytes).
    function test_F3_a_gap_verdict_is_refused_once_the_in_audit_timeout_is_open() public {
        (uint256 gapId, uint256 gapAuditId) = _fileGap();
        _accept(gapAuditId);
        address a = cell.auditAuditorOf(gapAuditId);
        uint256 deadline = cell.getAudit(gapAuditId).pickupTime + cell.inAuditWindow();

        vm.warp(deadline + 1);
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSignature("InAuditWindowPassed()"));
        structural.proveGapFail(gapAuditId, harnessToolId, keccak256("gap-fail"));
        cell.advanceInAudit(gapAuditId); // the only valid call now
        assertEq(uint256(structural.gapStateOf(gapId)), uint256(StructuralUpgradeModule.GapState.GapFiled));
    }

    function test_F3_a_gap_verdict_at_the_last_in_audit_second_still_lands() public {
        (uint256 gapId, uint256 gapAuditId) = _fileGap();
        _accept(gapAuditId);
        address a = cell.auditAuditorOf(gapAuditId);
        vm.warp(cell.getAudit(gapAuditId).pickupTime + cell.inAuditWindow());
        vm.prank(a);
        structural.proveGapFail(gapAuditId, harnessToolId, keccak256("gap-fail"));
        assertEq(uint256(structural.gapStateOf(gapId)), uint256(StructuralUpgradeModule.GapState.GapConfirmed));
    }

    /// VD-218(6): bug_010's EXPLOITED arm, owed as a fixture. A fix audit reaches Exploited through its own auditor's claim,
    /// disputed by the fix's proposer and reproduced; the gap returns to GapConfirmed like the voided case.
    function test_G4d_an_exploited_fix_audit_returns_its_gap_to_GapConfirmed() public {
        (uint256 gapId, uint256 gapAuditId) = _fileGap();
        _accept(gapAuditId);
        vm.prank(cell.auditAuditorOf(gapAuditId));
        structural.proveGapFail(gapAuditId, harnessToolId, keccak256("gap-fail"));

        vm.startPrank(filer);
        token.approve(address(cell), 2_000 ether);
        uint256 fixId = structural.submitStructuralFix(address(fixContract), specHash, specToolId, EMPTY_SPEC_ERRORS,
                                                       1_000 ether, gapId);
        vm.stopPrank();
        address fa = cell.auditAuditorOf(fixId);
        _accept(fixId);
        bytes32 fixFail = keccak256("fix-fail");
        vm.startPrank(fa);
        token.approve(address(cell), cell.requiredClaimStake(fixId));
        cell.proveFail(fixId, harnessToolId, fixFail); // the fix auditor's own claim
        vm.stopPrank();

        vm.startPrank(filer); // the fix's proposer is its protocol, and funds the dispute
        token.approve(address(cell), 500 ether);
        uint256 disputeId = d.claimModule.openDisputeReaudit(fixId, 500 ether);
        vm.stopPrank();
        address ra = cell.auditAuditorOf(disputeId);
        assertTrue(ra != address(0) && ra != fa, "fixture: a distinct re-auditor");
        _accept(disputeId);
        vm.prank(ra);
        cell.proveFail(disputeId, harnessToolId, fixFail);
        vm.warp(block.timestamp + cell.getAudit(disputeId).auditWindow + 1);
        cell.confirmAudit(disputeId);
        assertEq(uint256(cell.auditStateOf(fixId)), uint256(CellTypeDefs.AuditState.Exploited), "the fix audit is exploited");
        assertEq(uint256(structural.gapStateOf(gapId)), uint256(StructuralUpgradeModule.GapState.FixInAudit));

        assertTrue(_recover(gapId), "anyone recovers the gap");
        assertEq(uint256(structural.gapStateOf(gapId)), uint256(StructuralUpgradeModule.GapState.GapConfirmed));
        assertEq(structural.activeStructuralFixAuditId(gapId), 0);
    }

    /// PC-92 bug_009 (G5, I5): the gap verdict checked identity and state and never `isEligible`, which the ordinary verdict
    /// path rechecks at the moment of the verdict (`CellLogicLib.submitVerdictAfterProof`). An auditor who has fallen below
    /// the hold since accepting must not be the one who decides the gap.
    function test_G5_a_gap_verdict_from_an_ineligible_auditor_is_refused() public {
        (uint256 gapId, uint256 gapAuditId) = _fileGap();
        _accept(gapAuditId);
        address a = cell.auditAuditorOf(gapAuditId);

        // requiredHold = (queue position - 1) * increment, and the drawn auditor is registered second or third, so this
        // puts the hold above the 50,000 it holds either way.
        cell.setIncrement(60_000 ether);
        assertFalse(cell.isEligible(a), "fixture: the gap auditor no longer meets the hold");

        vm.prank(a);
        vm.expectRevert(abi.encodeWithSignature("InsufficientHold()"));
        structural.proveGapFail(gapAuditId, harnessToolId, keccak256("gap-fail"));
        assertEq(uint256(structural.gapStateOf(gapId)), uint256(StructuralUpgradeModule.GapState.GapFiled),
                 "the gap is not confirmed by an auditor the cell would not have drawn");
    }

    /// PC-92 bug_012 (G5): `fileNetworkGap` computed its spec digest directly and never ran the spec-tool validation that
    /// ordinary submission runs (`SubmitAuditLib._requireValidSpecAtSubmit`), so a gap could be admitted whose spec tool is
    /// unregistered - or is not a spec-validation tool at all.
    function test_G5_a_gap_whose_spec_tool_is_not_a_spec_tool_is_refused_at_intake() public {
        vm.startPrank(filer);
        token.approve(address(cell), 4_000 ether);
        vm.expectRevert(abi.encodeWithSignature("NotSpecValidationTool()"));
        structural.fileNetworkGap(address(canonical), gapSpecHash, harnessToolId, harnessToolId, EMPTY_SPEC_ERRORS, 500 ether);
        vm.expectRevert(abi.encodeWithSignature("SpecToolNotRegistered()"));
        structural.fileNetworkGap(address(canonical), gapSpecHash, harnessToolId, keccak256("never-registered"),
                                  EMPTY_SPEC_ERRORS, 500 ether);
        vm.stopPrank();
    }
}

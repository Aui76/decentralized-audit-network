// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/CellStorage.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "./helpers/CellTestDeploy.sol";
import "../contracts/CellParamIds.sol";

contract Target {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @dev Gate 0 Step 4b negative controls at harness window mins (10m audit, 30m claim).
contract Gate0Step4bTest is Test {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;

    address protocol = address(0xA11CE);
    address auditorA = address(0xB0B);
    address auditorB = address(0xC0DE);
    address claimant = address(0xDEAD);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 passRoot = keccak256("pass.root");
    bytes32 failRoot = keccak256("fail.root");

    uint256 constant BOUNTY = 40 ether;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        escrow = d.escrow;
        token.genesisMint(protocol, 2_000 ether);
        token.genesisMint(claimant, 500 ether);
        token.genesisMint(auditorB, 50 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        cell.setParam(CellParamIds.MIN_AUDIT, 10 minutes);
        cell.setParam(CellParamIds.CLAIM_RESOLUTION, 30 minutes);
        d.claimModule.setProtocolClaimDecisionWindow(30 minutes);
    }

    function _registerAll() internal {
        vm.prank(auditorA);
        cell.register();
        vm.prank(claimant);
        cell.register();
        vm.prank(auditorB);
        cell.register();
    }

    function _wrongPassToInBlock(address auditor) internal returns (uint256 id, Target original) {
        original = new Target(991040);
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        id = cell.submitAudit(address(original), address(original).codehash, specHash, specToolId, specErrors, BOUNTY, declared, 0, 0);
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditor);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditor);
        cell.provePass(id, verdictToolId, passRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        vm.prank(protocol);
        cell.confirmAudit(id);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InBlock));
    }

    /// Scenario A — throwaway fix confirm must not settle claim on O'.
    function test_scenarioA_throwaway_fix_leaves_claim_open() public {
        _registerAll();
        (uint256 originalId,) = _wrongPassToInBlock(auditorA);

        uint256 stake = cell.claimFilingStake();
        vm.prank(claimant);
        token.approve(address(cell), stake);
        vm.prank(claimant);
        cell.claimVulnerability(originalId, verdictToolId, failRoot, "");
        assertEq(uint256(cell.auditStateOf(originalId)), uint256(CellTypeDefs.AuditState.Claimed));

        Target throwaway = new Target(991041);
        vm.prank(protocol);
        token.approve(address(cell), 20 ether);
        vm.prank(protocol);
        uint256 fixId = cell.submitFixAudit(
            address(throwaway), specHash, specToolId, specErrors, 20 ether, originalId
        );
        address fixAuditor = cell.auditAuditorOf(fixId);
        vm.prank(fixAuditor);
        cell.acceptAudit(fixId, specErrors);
        vm.prank(fixAuditor);
        cell.provePass(fixId, verdictToolId, passRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        vm.prank(protocol);
        cell.confirmAudit(fixId);

        assertEq(uint256(cell.auditStateOf(originalId)), uint256(CellTypeDefs.AuditState.Claimed));
        (,,,,, bool resolved,,,,,,,) = cell.vulnerabilityClaims(originalId);
        assertFalse(resolved);
    }

    /// Scenario B — expireClaim restores InBlock; G-14 (no failed++, no mint).
    function test_scenarioB_expire_restores_inblock() public {
        _registerAll();
        (uint256 id,) = _wrongPassToInBlock(auditorA);

        uint256 stake = cell.claimFilingStake();
        vm.prank(claimant);
        token.approve(address(cell), stake);
        vm.prank(claimant);
        cell.claimVulnerability(id, verdictToolId, failRoot, "");
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Claimed));

        (, uint256 failedBefore,,,,) = cell.auditors(auditorA);
        uint256 supplyPre = token.totalSupply();
        uint256 heightPre = cell.blockHeight();

        vm.warp(block.timestamp + 30 minutes + 30 minutes + 1);
        cell.expireClaim(id);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InBlock));
        (,,,,, bool resolved,,,,,,,) = cell.vulnerabilityClaims(id);
        assertTrue(resolved);
        (, uint256 failedAfter,,,,) = cell.auditors(auditorA);
        assertEq(failedAfter, failedBefore);
        assertEq(token.totalSupply(), supplyPre);
        assertEq(cell.blockHeight(), heightPre);
    }
}

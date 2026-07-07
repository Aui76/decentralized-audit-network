// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/CellStorage.sol";
import "../contracts/SubmitAuditLib.sol";
import "../contracts/RunDigests.sol";
import "../contracts/tools/AuditCaseV1.sol";
import "./helpers/CellTestDeploy.sol";

/// @dev Distinct-codehash target (immutable salt embedded in runtime code) — mirrors the other cell suites.
contract Target {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/*
 * Coverage for the re-landed domain-agnostic intake (Pillar B): `submitArtifactAudit`, the case-root preview
 * helpers `previewCaseRoot` / `previewCaseRootFromHash`, and the `declaredVerdictToolsOf` enumerator. These
 * were present in the Genesis cell-v2, dropped in the satellite decomposition, and re-landed 2026-07-05 —
 * but were UNTESTED (green by absence: no test called them, which is exactly why the drop went unnoticed).
 * This suite makes the re-land real by CALLING each restored function and asserting it behaves.
 */
contract DomainAgnosticIntakeCellTest is Test {
    AuditCell cell;
    CellToken token;

    address protocol = address(0xA11CE);
    address auditorA = address(0xB0B);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");

    uint256 constant BOUNTY = 40 ether;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        cell = d.cell;
        token = d.token;
        token.genesisMint(protocol, 2_000 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
    }

    function _declared() internal view returns (bytes32[] memory declared) {
        declared = new bytes32[](1);
        declared[0] = verdictToolId;
    }

    /// Off-chain twin of the on-chain case-root formula (same helper the AuditCaseRoot suite uses).
    function _expectedRoot(bytes32 artifactHash, bytes32[] memory tools) internal view returns (bytes32) {
        bytes32 passDigest = RunDigests.specRunDigest(specHash, specToolId, true, specErrors);
        return AuditCaseV1.caseRoot(artifactHash, specHash, specToolId, passDigest, AuditCaseV1.sortToolIds(tools));
    }

    // ---- previewCaseRoot (EVM-anchored form) == off-chain twin == the root submit actually pins ----
    function test_previewCaseRoot_matches_offchain_and_submit() public {
        Target t = new Target(1);
        bytes32[] memory declared = _declared();

        bytes32 preview = cell.previewCaseRoot(address(t), specHash, specToolId, specErrors, declared);
        assertEq(preview, _expectedRoot(address(t).codehash, declared), "preview == off-chain twin");

        vm.prank(auditorA);
        cell.register();
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        vm.prank(protocol);
        uint256 id =
            cell.submitAudit(address(t), address(t).codehash, specHash, specToolId, specErrors, BOUNTY, declared, 0, 0);
        assertEq(cell.caseRootOf(id), preview, "preview == the root the submit path pinned");
    }

    // ---- previewCaseRootFromHash (bare) + submitArtifactAudit(bare) pin the SAME root ----
    function test_previewCaseRootFromHash_matches_bare_submit() public {
        bytes32 artifactHash = keccak256("offchain-artifact-v1"); // a BARE O — no EVM contract behind it
        bytes32[] memory declared = _declared();

        bytes32 preview = cell.previewCaseRootFromHash(artifactHash, specHash, specToolId, specErrors, declared);
        assertEq(preview, _expectedRoot(artifactHash, declared), "bare preview == off-chain twin");

        vm.prank(auditorA);
        cell.register();
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        vm.prank(protocol);
        uint256 id =
            cell.submitArtifactAudit(artifactHash, address(0), specHash, specToolId, specErrors, BOUNTY, declared, 0, 0);
        assertEq(cell.caseRootOf(id), preview, "bare submit pinned the previewed root");
    }

    // ---- a bare (non-EVM) artifact settles through the IDENTICAL lifecycle to a positive-block mint ----
    function test_submitArtifactAudit_bare_full_lifecycle() public {
        vm.prank(auditorA);
        cell.register();

        bytes32 artifactHash = keccak256("offchain-build-hash-v1");
        bytes32[] memory declared = _declared();
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        vm.prank(protocol);
        uint256 id =
            cell.submitArtifactAudit(artifactHash, address(0), specHash, specToolId, specErrors, BOUNTY, declared, 0, 0);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Assigned), "assigned");
        assertEq(cell.auditAuditorOf(id), auditorA, "auditor assigned to a bare artifact");

        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditorA);
        cell.provePass(id, verdictToolId, resultRoot);

        uint256 balBefore = token.balanceOf(auditorA);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InBlock), "bare artifact reached InBlock");
        assertGt(token.balanceOf(auditorA), balBefore + BOUNTY, "auditor paid bounty + positive-block reward");
        (uint256 successful,,,,,) = cell.auditors(auditorA);
        assertEq(successful, 1, "successful++ on a bare-artifact audit");
    }

    // ---- anti-double-submit keys on the bare artifactHash+spec (caseRoot), not on an address ----
    function test_submitArtifactAudit_bare_dedupe() public {
        bytes32 artifactHash = keccak256("offchain-artifact-dup");
        bytes32[] memory declared = _declared();

        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        vm.prank(protocol);
        uint256 id =
            cell.submitArtifactAudit(artifactHash, address(0), specHash, specToolId, specErrors, BOUNTY, declared, 0, 0);

        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(CellLogicLib.CaseAlreadyAudited.selector, id));
        cell.submitArtifactAudit(artifactHash, address(0), specHash, specToolId, specErrors, BOUNTY, declared, 0, 0);
    }

    // ---- optional EVM anchor: a supplied address must actually hold the pinned artifact ----
    function test_submitArtifactAudit_address_codehash_must_match() public {
        Target t = new Target(3);
        bytes32 wrongHash = keccak256("not-this-contract");
        bytes32[] memory declared = _declared();

        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        vm.prank(protocol);
        vm.expectRevert(SubmitAuditLib.ArtifactHashMismatch.selector);
        cell.submitArtifactAudit(wrongHash, address(t), specHash, specToolId, specErrors, BOUNTY, declared, 0, 0);
    }

    // ---- declaredVerdictToolsOf enumerates the audit's declared tools; reverts on an unknown id ----
    function test_declaredVerdictToolsOf_enumerates() public {
        Target t = new Target(4);
        bytes32[] memory declared = _declared();
        vm.prank(auditorA);
        cell.register();
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        vm.prank(protocol);
        uint256 id =
            cell.submitAudit(address(t), address(t).codehash, specHash, specToolId, specErrors, BOUNTY, declared, 0, 0);

        (bytes32[4] memory slots, uint8 n) = cell.declaredVerdictToolsOf(id);
        assertEq(uint256(n), 1, "one declared tool");
        assertEq(slots[0], verdictToolId, "the declared verdict tool");

        vm.expectRevert(SubmitAuditLib.NoAudit.selector);
        cell.declaredVerdictToolsOf(4242);
    }
}

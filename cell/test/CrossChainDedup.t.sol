// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/CellStorage.sol";
import "../contracts/SubmitAuditLib.sol";
import "./helpers/CellTestDeploy.sol";

/// @dev Distinct-codehash target (immutable salt embedded in runtime code) — mirrors the other cell suites.
contract Target {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/*
 * G-30 — targetChainId storage reserve (DEC-18 / DEC-22, 2026-07-08).
 *
 * The LEAN reserve: the Audit struct gains `targetChainId`; NO write path sets it (0 = home chain,
 * by definition); the raw `targetChainId` field stays 0 for home rows (normalized off-chain). The point of this suite
 * is (a) the reserve-field semantics, and (b) a REGRESSION PIN that the reserve changed nothing on the home
 * path: dedup indexes, first-writer pointer, and duplicate-case revert behave exactly as before.
 * The foreign-target path is deliberately NOT built (FEATURES-TO-CONSIDER FC-1/FC-2; trigger =
 * a second chain becomes a named goal).
 */
contract CrossChainDedupTest is Test {
    AuditCell cell;
    CellToken token;

    address protocol = address(0xA11CE);
    address auditorA = address(0xB0B);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specHash2 = keccak256("spec.v2"); // second case for the same artifact (different caseRoot)
    bytes32 specErrors = keccak256("errors.v1");

    uint256 constant BOUNTY = 40 ether;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        cell = d.cell;
        token = d.token;
        token.genesisMint(protocol, 2_000 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);

        vm.prank(auditorA);
        cell.register();
    }

    function _declared() internal view returns (bytes32[] memory declared) {
        declared = new bytes32[](1);
        declared[0] = verdictToolId;
    }

    function _submitAnchored(Target t, bytes32 sh) internal returns (uint256 id) {
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        vm.prank(protocol);
        id = cell.submitAudit(
            address(t), address(t).codehash, sh, specToolId, specErrors, BOUNTY, _declared(), 0, 0
        );
    }

    // ---- (1) view semantics: every row the cell writes today reads as HOME chain ----
    function test_g30_anchored_row_reads_home_chain() public {
        Target t = new Target(1);
        uint256 id = _submitAnchored(t, specHash);
        assertEq(cell.getAudit(id).targetChainId, 0, "anchored row stores the 0 home-chain sentinel");
    }

    function test_g30_bare_row_reads_home_chain() public {
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        vm.prank(protocol);
        uint256 id = cell.submitArtifactAudit(
            keccak256("offchain.artifact.v1"), address(0), specHash, specToolId, specErrors, BOUNTY, _declared(), 0, 0
        );
        assertEq(cell.getAudit(id).targetChainId, 0, "bare (domain-agnostic) row stores the 0 home-chain sentinel");
    }

    // ---- (2) regression pin: home-path dedup is byte-identical to pre-reserve behavior ----
    function test_g30_home_dedup_regression_first_writer_pinned() public {
        Target t = new Target(2);
        uint256 first = _submitAnchored(t, specHash);

        assertTrue(cell.artifactRegistered(address(t).codehash), "artifact indexed on first submit");
        assertEq(cell.artifactToAuditId(address(t).codehash), first, "index points at first row");

        // Same artifact, DIFFERENT spec => new caseRoot, so the submit is allowed; the artifact
        // index must still point at the FIRST row (first-writer pinned — unchanged by the reserve).
        uint256 second = _submitAnchored(t, specHash2);
        assertTrue(second != first, "second case creates a distinct row");
        assertEq(cell.artifactToAuditId(address(t).codehash), first, "first-writer pointer unchanged");
        assertEq(cell.getAudit(second).targetChainId, 0, "second row stores the 0 home-chain sentinel");
    }

    function test_g30_duplicate_case_still_reverts() public {
        Target t = new Target(3);
        uint256 first = _submitAnchored(t, specHash);

        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(CellLogicLib.CaseAlreadyAudited.selector, first));
        cell.submitAudit(
            address(t), address(t).codehash, specHash, specToolId, specErrors, BOUNTY, _declared(), 0, 0
        );
    }
}

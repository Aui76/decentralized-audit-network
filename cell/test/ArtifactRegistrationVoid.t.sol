// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellToken.sol";
import "./helpers/CellTestDeploy.sol";

contract ArtifactTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice bug_002 of the 2026-09-15 second-family review, verified by call path and narrowed here. Ordinary
///         submission registers an artifact ONLY when it is not yet registered (`CellLogicLib._finalizeCreatedAudit`,
///         `!L.artifactRegistered[artifactHash]`), so `artifactToAuditId` keeps pointing at the FIRST audit of that
///         artifact while a superseding audit reuses it (`SupersedesSameORequired`). Both void paths clear the
///         registration UNCONDITIONALLY (`AuditCell._voidAuditRow`, and the spec-arbiter arm of `settlementOverlay`) -
///         so voiding the NEWER row wipes a registration that belongs to the OLDER row, which is still live.
///
///         PINNED AS IT STANDS (green while the defect exists); the cure - clear only when
///         `artifactToAuditId[hash] == auditId` - flips the assertion. Hull bytes: books to the value-bearing window.
contract ArtifactRegistrationVoidTest is Test {
    CellTestDeploy.Deployment d;
    address protocol = address(0xA11CE);
    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specErrors = keccak256("errors.v1");

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        d.token.genesisMint(protocol, 2_000 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
    }

    function _submit(ArtifactTarget t, bytes32 specHash, uint256 supersedes) internal returns (uint256 id) {
        vm.prank(protocol);
        d.token.approve(address(d.cell), 40 ether);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        id = d.cell.submitAudit(address(t), address(t).codehash, specHash, specToolId, specErrors, 40 ether, declared, supersedes, 0);
    }

    function test_BUG_voiding_the_newer_row_clears_the_older_rows_registration() public {
        ArtifactTarget t = new ArtifactTarget(1);
        bytes32 artifact = address(t).codehash;
        uint256 older = _submit(t, keccak256("spec.v1"), 0);
        uint256 newer = _submit(t, keccak256("spec.v2"), older);

        assertTrue(d.cell.artifactRegistered(artifact), "registered");
        assertEq(d.cell.artifactToAuditId(artifact), older, "the registration points at the OLDER row, not the newer");

        vm.prank(address(d.specArbiterModule));
        d.cell.settlementOverlay(0, 2, newer, address(0xC0FFEE)); // spec-arbiter void of the NEWER row

        assertEq(uint256(d.cell.auditStateOf(newer)), uint256(CellTypeDefs.AuditState.Invalidated), "the newer row is void");
        assertTrue(uint256(d.cell.auditStateOf(older)) != uint256(CellTypeDefs.AuditState.Invalidated), "the older row is NOT");
        assertFalse(d.cell.artifactRegistered(artifact), "yet the older row's registration is GONE - the defect");
        assertEq(d.cell.artifactToAuditId(artifact), 0, "and its pointer deleted");
    }
}

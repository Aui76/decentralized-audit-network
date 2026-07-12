// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellStorage.sol";
import "./helpers/CellTestDeploy.sol";

contract Target {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice G-28 oracle (2026-07-08, DEC-22 docket, option 2 — structural fix).
///
/// The positional `audits()` tuple is kept for external ABI/surface conservation; all in-contract module
/// consumers were migrated to the name-based `getAudit()` struct getter so a future struct-field reorder can
/// no longer silently misroute a consumer (compiler resolves names, not comma positions). This suite PINS
/// the two getters field-for-field on a populated row — if anyone reorders the struct or the positional
/// getter, the mapping breaks here LOUDLY (the desync we removed for the modules, now caught for the ABI too).
contract AuditGetterParity is Test {
    AuditCell cell;
    CellToken token;

    address protocol = address(0xA11CE);
    address auditor = address(0xB0B);

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
        vm.prank(auditor);
        cell.register();
    }

    function _submit() internal returns (uint256 id) {
        Target t = new Target(7);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        vm.prank(protocol);
        id = cell.submitAudit(address(t), address(t).codehash, specHash, specToolId, specErrors, BOUNTY, declared, 0, 0);
    }

    // getAudit(id).<field> == the positional audits(id) slot, field for field (the 20 the tuple exposes).
    function test_getAudit_matches_positional_tuple() public {
        uint256 id = _submit();

        CellTypeDefs.Audit memory a = cell.getAudit(id);
        (
            address protocol_,
            address auditor_,
            address deployedAddress_,
            uint256 bounty_,
            uint256 windowStart_,
            CellTypeDefs.AuditState state_,
            bytes32 specHash_,
            bytes32 artifactHash_,
            bytes32 specToolId_,
            bytes32 specPassDigest_,
            bool specAuditorAttested_,
            uint256 pickupTime_,
            bool isVulnerabilityReport_,
            bool isClaimDispute_,
            uint256 linkedAuditId_,
            CellTypeDefs.AuditState stateBeforeClaim_,
            address lastDiscoverer_,
            bool protocolApprovedAssignment_,
            bytes32 caseRoot_,
            uint256 supersedesAuditId_
        ) = cell.audits(id);

        assertEq(a.protocol, protocol_, "protocol");
        assertEq(a.auditor, auditor_, "auditor");
        assertEq(a.deployedAddress, deployedAddress_, "deployedAddress");
        assertEq(a.bounty, bounty_, "bounty");
        assertEq(a.windowStart, windowStart_, "windowStart");
        assertEq(uint256(a.state), uint256(state_), "state");
        assertEq(a.specHash, specHash_, "specHash");
        assertEq(a.artifactHash, artifactHash_, "artifactHash");
        assertEq(a.specToolId, specToolId_, "specToolId");
        assertEq(a.specPassDigest, specPassDigest_, "specPassDigest");
        assertEq(a.specAuditorAttested, specAuditorAttested_, "specAuditorAttested");
        assertEq(a.pickupTime, pickupTime_, "pickupTime");
        assertEq(a.isVulnerabilityReport, isVulnerabilityReport_, "isVulnerabilityReport");
        assertEq(a.isClaimDispute, isClaimDispute_, "isClaimDispute");
        assertEq(a.linkedAuditId, linkedAuditId_, "linkedAuditId");
        assertEq(uint256(a.stateBeforeClaim), uint256(stateBeforeClaim_), "stateBeforeClaim");
        assertEq(a.lastDiscoverer, lastDiscoverer_, "lastDiscoverer");
        assertEq(a.protocolApprovedAssignment, protocolApprovedAssignment_, "protocolApprovedAssignment");
        assertEq(a.caseRoot, caseRoot_, "caseRoot");
        assertEq(a.supersedesAuditId, supersedesAuditId_, "supersedesAuditId");
    }

    // getAudit also exposes the fields the positional tuple OMITS (the point of the struct getter).
    function test_getAudit_exposes_omitted_fields() public {
        uint256 id = _submit();
        CellTypeDefs.Audit memory a = cell.getAudit(id);
        assertGt(a.auditWindow, 0, "auditWindow exposed (omitted by positional getter)");
        assertEq(a.targetChainId, 0, "targetChainId exposed, home-sentinel 0 (G-30)");
        assertEq(a.protocolRejectCount, 0, "protocolRejectCount exposed");
        // bountyEscrowed reachable by name too (value depends on flow; just assert it reads)
        a.bountyEscrowed;
    }
}

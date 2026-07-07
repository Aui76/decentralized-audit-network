// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellStorage.sol";
import "./helpers/CellTestDeploy.sol";

contract Target {
    uint256 public x = 1;
}

contract SmartAccount {
    function submit(
        AuditCell cell,
        address deployed,
        bytes32 expectedCodehash,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        uint256 bounty,
        bytes32[] calldata declared,
        uint256 supersedes
    ) external returns (uint256) {
        return cell.submitAudit(
            deployed, expectedCodehash, specHash, specToolId, specErrorsRoot, bounty, declared, supersedes, 0
        );
    }
}

/// @notice G3 oracle — expectedCodehash binding, bounty cap, account-agnostic submit.
contract SigningSafetyCellTest is Test {
    CellTestDeploy.Deployment internal d;
    Target internal target;
    SmartAccount internal smart;

    address internal protocol = address(0xBEEF);
    address internal impostor = address(0xBAD);

    bytes32 internal specToolId = keccak256("spec.tool.v1");
    bytes32 internal verdictToolId = keccak256("verdict.tool.v1");
    bytes32 internal specHash = keccak256("spec.v1");
    bytes32 internal specErrors = keccak256("errors.v1");

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        target = new Target();
        smart = new SmartAccount();
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        d.token.genesisMint(protocol, 100_000 ether);
        d.token.genesisMint(address(smart), 10_000 ether);
        vm.prank(address(0xA11CE));
        d.cell.register();
    }

    function test_wrong_expectedCodehash_reverts() public {
        bytes32[] memory declared = _declared();
        vm.startPrank(protocol);
        d.token.approve(address(d.cell), 10_000 ether);
        vm.expectRevert(AuditCell.ArtifactHashMismatch.selector);
        d.cell.submitAudit(
            address(target), bytes32(uint256(1)), specHash, specToolId, specErrors, 1 ether, declared, 0, 0
        );
        vm.stopPrank();
    }

    function test_bounty_above_cap_reverts() public {
        d.cell.setMaxBountyPerSubmit(5 ether);
        bytes32[] memory declared = _declared();
        vm.startPrank(protocol);
        d.token.approve(address(d.cell), 10_000 ether);
        vm.expectRevert(AuditCell.BountyExceedsCap.selector);
        d.cell.submitAudit(
            address(target), address(target).codehash, specHash, specToolId, specErrors, 6 ether, declared, 0, 0
        );
        vm.stopPrank();
    }

    function test_smart_account_may_submit_as_protocol() public {
        bytes32[] memory declared = _declared();
        vm.startPrank(address(smart));
        d.token.approve(address(d.cell), 10_000 ether);
        uint256 id = smart.submit(
            d.cell,
            address(target),
            address(target).codehash,
            specHash,
            specToolId,
            specErrors,
            1 ether,
            declared,
            0
        );
        vm.stopPrank();
        assertEq(d.cell.auditProtocolOf(id), address(smart));
    }

    function test_non_protocol_cannot_protocolReject() public {
        uint256 id = _submitAs(protocol);
        assertEq(uint256(d.cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Assigned));
        vm.prank(impostor);
        vm.expectRevert(AuditCell.OnlyProtocol.selector);
        d.cell.protocolRejectAuditor(id);
    }

    function _submitAs(address who) internal returns (uint256 id) {
        bytes32[] memory declared = _declared();
        vm.startPrank(who);
        d.token.approve(address(d.cell), 10_000 ether);
        id = CellTestDeploy.submitAudit(
            d.cell, address(target), specHash, specToolId, specErrors, 1 ether, declared, 0
        );
        vm.stopPrank();
    }

    function _declared() internal view returns (bytes32[] memory tools) {
        tools = new bytes32[](1);
        tools[0] = verdictToolId;
    }
}

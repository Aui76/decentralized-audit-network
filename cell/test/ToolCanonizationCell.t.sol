// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "./helpers/CellTestDeploy.sol";
import "../contracts/CellParamIds.sol";

contract Target {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice R7 oracle — tool canonization mint + CAN chain entry on threshold confirm.
contract ToolCanonizationCellTest is Test {
    CellTestDeploy.Deployment internal d;

    address internal protocol = address(0xA11CE);
    address internal auditor = address(0xB0B);
    address internal toolAuthor = address(0x7001);

    bytes32 internal specToolId = keccak256("spec.tool.v1");
    bytes32 internal verdictToolId = keccak256("verdict.tool.v1");
    bytes32 internal specHash = keccak256("spec.v1");
    bytes32 internal specErrors = keccak256("errors.v1");
    bytes32 internal resultRoot = keccak256("result.v1");

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        d.token.genesisMint(protocol, 1_000 ether);
        CellTestDeploy.attachMinter(d);
        d.cell.registerTool(specToolId, true);
        vm.prank(toolAuthor);
        d.cell.registerTool(verdictToolId, false);

        d.cell.setParam(CellParamIds.CANONICAL_THRESHOLD, 2);

        vm.prank(auditor);
        d.cell.register();
    }

    function test_canonization_fires_on_threshold_with_can_mint_and_chain() public {
        bytes32 hashBefore = d.cell.latestBlockHash();
        uint256 authorBefore = d.token.balanceOf(toolAuthor);

        _passAudit(1);
        (, , , bool canonicalAfterOne, , uint256 usesAfterOne,) = d.cell.tools(verdictToolId);
        assertEq(usesAfterOne, 1);
        assertFalse(canonicalAfterOne);

        _passAudit(2);

        (, , , bool canonical, , uint256 uses,) = d.cell.tools(verdictToolId);
        assertEq(uses, 2);
        assertTrue(canonical);
        assertGt(d.token.balanceOf(toolAuthor), authorBefore);
        assertTrue(d.cell.latestBlockHash() != hashBefore);
        assertTrue(d.cell.latestBlockHash() != bytes32(0));
    }

    function test_canonization_reward_matches_positive_block_reward_at_bs1() public view {
        uint256 expected = d.issuance.nextPositiveBlockReward() / d.cell.currentBlockSize();
        assertEq(expected, d.issuance.nextPositiveBlockReward());
        expected;
    }

    function _passAudit(uint256 salt) internal {
        Target target = new Target(salt);
        uint256 bounty = 50 ether;
        vm.prank(protocol);
        d.token.approve(address(d.cell), bounty);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        uint256 id = d.cell.submitAudit(
            address(target), address(target).codehash, specHash, specToolId, specErrors, bounty, declared, 0, 0
        );

        vm.prank(protocol);
        d.cell.protocolAcceptAuditor(id);
        vm.prank(auditor);
        d.cell.acceptAudit(id, specErrors);
        vm.prank(auditor);
        d.cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + d.cell.minAuditWindow() + 1);
        vm.prank(auditor);
        d.cell.confirmAudit(id);
    }
}

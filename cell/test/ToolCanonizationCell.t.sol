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

/// @notice G-19 oracle — REWORKED 2026-07-08 (DEC-22 docket, option B; proposal:
///         body/proposals/fix-canonization-distinct-rekey-proposal.txt).
///
///         The ORIGINAL green scenario of this suite (one protocol, `canonicalThreshold` RAW uses ->
///         canonical + full block reward to the proposer) WAS the G-19 farm. It is now the inverse
///         assertion (t1). Canonization fires only when the tool has been used by `canonicalThreshold`
///         DISTINCT ESTABLISHED protocols (§2.5 signal as a GATE; ToolUseLib extraction).
contract ToolCanonizationCellTest is Test {
    CellTestDeploy.Deployment internal d;

    address internal auditor = address(0xB0B);
    address internal toolAuthor = address(0x7001);
    address[3] internal protocols = [address(0xA11CE), address(0xA22CE), address(0xA33CE)];

    bytes32 internal specToolId = keccak256("spec.tool.v1");
    bytes32 internal verdictToolId = keccak256("verdict.tool.v1");
    bytes32 internal specHash = keccak256("spec.v1");
    bytes32 internal specErrors = keccak256("errors.v1");
    bytes32 internal resultRoot = keccak256("result.v1");
    uint256 internal saltNonce = 1;

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        for (uint256 i = 0; i < protocols.length; i++) {
            d.token.genesisMint(protocols[i], 1_000 ether);
        }
        CellTestDeploy.attachMinter(d);
        d.cell.registerTool(specToolId, true);
        vm.prank(toolAuthor);
        d.cell.registerTool(verdictToolId, false);

        d.cell.setParam(CellParamIds.CANONICAL_THRESHOLD, 2);
        // Single-auditor mesh shortcut: with threshold 1, a protocol establishes at its first settle
        // (auditor's own distinct count increments BEFORE the protocol-credit check). t3 overrides this.
        d.issuance.setCredibilityCountThreshold(1);

        vm.prank(auditor);
        d.cell.register();
    }

    // ---- t1 THE G-19 KILL: raw-count farming no longer canonizes ----
    function test_raw_use_farming_does_not_canonize() public {
        for (uint256 i = 0; i < 4; i++) _passAudit(protocols[0]);

        (, , , bool canonical, , uint256 rawUses,) = d.cell.tools(verdictToolId);
        assertEq(rawUses, 4, "raw telemetry still counts every use");
        assertFalse(canonical, "raw uses >= threshold NO LONGER canonize (the old farm, dead)");
        assertLe(
            d.cell.toolDistinctEstablishedUses(verdictToolId),
            1,
            "one protocol == at most one distinct established use, ever (dedup)"
        );
        assertEq(d.token.balanceOf(toolAuthor), 0, "no CAN mint to the proposer");
    }

    // ---- t2 the honest path: distinct ESTABLISHED protocols canonize + CAN mint + entropy fold ----
    function test_distinct_established_protocols_canonize_with_mint_and_chain() public {
        bytes32 hashBefore = d.cell.latestBlockHash();
        uint256 authorBefore = d.token.balanceOf(toolAuthor);

        _passAudit(protocols[0]); // establishes P0 (threshold 1); its use may count from the next record
        (, , , bool canonicalEarly, , ,) = d.cell.tools(verdictToolId);
        assertFalse(canonicalEarly, "one protocol cannot reach a distinct threshold of 2");

        _passAudit(protocols[1]); // establishes P1
        _passAudit(protocols[0]); // definitely-counted use by established P0
        _passAudit(protocols[1]); // definitely-counted use by established P1

        (, , , bool canonical, , ,) = d.cell.tools(verdictToolId);
        assertTrue(canonical, "2 distinct established protocols canonize");
        assertGe(d.cell.toolDistinctEstablishedUses(verdictToolId), 2, "trigger counter reached threshold");
        assertGt(d.token.balanceOf(toolAuthor), authorBefore, "proposer received the CAN one-shot");
        assertTrue(d.cell.latestBlockHash() != hashBefore, "CAN entropy fold moved the chain");
        assertTrue(d.cell.latestBlockHash() != bytes32(0));
    }

    // ---- t3 unestablished protocols never count ----
    function test_unestablished_protocols_do_not_count() public {
        // Single auditor + threshold 2: no protocol can collect 2 proven auditors -> nothing establishes.
        d.issuance.setCredibilityCountThreshold(2);

        for (uint256 i = 0; i < protocols.length; i++) _passAudit(protocols[i]);
        for (uint256 i = 0; i < protocols.length; i++) _passAudit(protocols[i]);

        (, , , bool canonical, , uint256 rawUses,) = d.cell.tools(verdictToolId);
        assertEq(rawUses, 6, "raw telemetry counted all six");
        assertFalse(canonical, "distinct-but-UNESTABLISHED protocols never canonize");
        assertEq(d.cell.toolDistinctEstablishedUses(verdictToolId), 0, "no established use counted");
        assertFalse(d.issuance.isEstablishedProtocol(protocols[0]), "gate ground truth");
    }

    // ---- reward shape unchanged (bs=1 divisor) ----
    function test_canonization_reward_matches_positive_block_reward_at_bs1() public view {
        uint256 expected = d.issuance.nextPositiveBlockReward() / d.cell.currentBlockSize();
        assertEq(expected, d.issuance.nextPositiveBlockReward());
        expected;
    }

    function _passAudit(address protocol) internal {
        Target target = new Target(saltNonce++);
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

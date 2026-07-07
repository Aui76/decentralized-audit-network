// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/RunDigests.sol";
import "../contracts/tools/AuditCaseV1.sol";
import "../contracts/ClaimDisputeModule.sol";
import "./helpers/CellTestDeploy.sol";

contract Target {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

contract AuditCaseRootTest is Test {
    AuditCell cell;
    ClaimDisputeModule claimModule;
    CellToken token;

    address protocol = address(0xA11CE);
    address auditor = address(0xB0B);
    address adversary = address(0xDEAD);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");
    bytes32 claimRoot = keccak256("claim.proof");

    uint256 constant BOUNTY = 40 ether;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        cell = d.cell;
        claimModule = d.claimModule;
        token = d.token;
        token.genesisMint(protocol, 2_000 ether);
        token.genesisMint(adversary, 500 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
    }

    function _expectedCaseRoot(address target, bytes32[] memory tools) internal view returns (bytes32) {
        bytes32 passDigest = RunDigests.specRunDigest(specHash, specToolId, true, specErrors);
        bytes32[] memory sorted = AuditCaseV1.sortToolIds(tools);
        return AuditCaseV1.caseRoot(target.codehash, specHash, specToolId, passDigest, sorted);
    }

    function _submitOrdinary(address target) internal returns (uint256 id) {
        vm.prank(auditor);
        cell.register();
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        id = cell.submitAudit(target, target.codehash, specHash, specToolId, specErrors, BOUNTY, declared, 0, 0);
    }

    function test_case_root_matches_off_chain_helper() public {
        Target t = new Target(1);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        bytes32 expected = _expectedCaseRoot(address(t), declared);

        uint256 id = _submitOrdinary(address(t));
        assertEq(cell.caseRootOf(id), expected);
    }

    function test_declared_tools_order_independent() public {
        Target t = new Target(2);
        bytes32 toolA = keccak256("tool.a");
        bytes32 toolB = keccak256("tool.b");
        vm.prank(address(this));
        cell.registerTool(toolA, false);
        vm.prank(address(this));
        cell.registerTool(toolB, false);

        bytes32[] memory order1 = new bytes32[](2);
        order1[0] = toolA;
        order1[1] = toolB;
        bytes32[] memory order2 = new bytes32[](2);
        order2[0] = toolB;
        order2[1] = toolA;

        bytes32 root1 = _expectedCaseRoot(address(t), order1);
        bytes32 root2 = _expectedCaseRoot(address(t), order2);
        assertEq(root1, root2);
    }

    function test_preview_matches_submit() public {
        Target t = new Target(3);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        bytes32 preview = _expectedCaseRoot(address(t), declared);
        uint256 id = _submitOrdinary(address(t));
        assertEq(cell.caseRootOf(id), preview);
    }

    function test_dispute_copies_case_root() public {
        Target t = new Target(4);
        uint256 id = _submitOrdinary(address(t));
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditor);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditor);
        cell.provePass(id, verdictToolId, resultRoot);

        vm.prank(adversary);
        cell.register();
        uint256 stake = cell.claimFilingStake();
        vm.prank(adversary);
        token.approve(address(cell), stake);
        vm.prank(adversary);
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");

        uint256 minB = (BOUNTY * 5000) / 10_000;
        vm.prank(protocol);
        token.approve(address(cell), minB);
        vm.prank(protocol);
        uint256 disputeId = claimModule.openDisputeReaudit(id, minB);

        assertEq(cell.caseRootOf(disputeId), cell.caseRootOf(id));
    }

    function test_fix_audit_differs_case_root() public {
        Target original = new Target(5);
        uint256 id = _submitOrdinary(address(original));
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditor);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditor);
        cell.provePass(id, verdictToolId, resultRoot);

        vm.prank(adversary);
        cell.register();
        uint256 stake = cell.claimFilingStake();
        vm.prank(adversary);
        token.approve(address(cell), stake);
        vm.prank(adversary);
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");

        Target fix = new Target(99);
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        vm.prank(protocol);
        uint256 fixId = cell.submitFixAudit(address(fix), specHash, specToolId, specErrors, BOUNTY, id);

        assertTrue(cell.caseRootOf(fixId) != cell.caseRootOf(id));
        assertTrue(cell.caseRootOf(fixId) != bytes32(0));
    }

    function test_audit_case_pinned_event() public {
        Target t = new Target(6);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        bytes32 expectedRoot = _expectedCaseRoot(address(t), declared);

        vm.recordLogs();
        uint256 id = _submitOrdinary(address(t));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 pinnedTopic = keccak256(
            "AuditCasePinned(uint256,bytes32,bytes32,bytes32,uint256,bool,bool,uint256)"
        );
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != pinnedTopic) continue;
            assertEq(uint256(logs[i].topics[1]), id);
            assertEq(logs[i].topics[2], expectedRoot);
            found = true;
        }
        assertTrue(found);
    }

    function test_verdict_tool_getter() public {
        Target t = new Target(7);
        uint256 id = _submitOrdinary(address(t));
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditor);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditor);
        cell.provePass(id, verdictToolId, resultRoot);
        assertEq(cell.auditVerdictToolId(id), verdictToolId);
    }
}

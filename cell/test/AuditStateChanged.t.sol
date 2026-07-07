// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellStorage.sol";
import "./helpers/CellTestDeploy.sol";

contract Target {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

contract AuditStateChangedTest is Test {
    AuditCell cell;
    CellToken token;

    address protocol = address(0xA11CE);
    address auditor = address(0xB0B);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        cell = d.cell;
        token = d.token;
        token.genesisMint(protocol, 500 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
    }

    function test_submit_emits_none_to_submitted_and_assign() public {
        Target t = new Target(1);
        vm.prank(auditor);
        cell.register();
        vm.prank(protocol);
        token.approve(address(cell), 40 ether);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;

        vm.recordLogs();
        vm.prank(protocol);
        uint256 id = cell.submitAudit(address(t), address(t).codehash, specHash, specToolId, specErrors, 40 ether, declared, 0, 0);

        bytes32 topic = keccak256("AuditStateChanged(uint256,bytes32,uint8,uint8)");
        bytes32 root = cell.caseRootOf(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawNoneToSubmitted;
        bool sawSubmittedToAssigned;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != topic) continue;
            (uint8 from, uint8 to) = abi.decode(logs[i].data, (uint8, uint8));
            if (from == uint8(CellTypeDefs.AuditState.None) && to == uint8(CellTypeDefs.AuditState.Submitted)) {
                sawNoneToSubmitted = true;
                assertEq(uint256(logs[i].topics[1]), id);
                assertEq(logs[i].topics[2], root);
            }
            if (from == uint8(CellTypeDefs.AuditState.Submitted) && to == uint8(CellTypeDefs.AuditState.Assigned)) {
                sawSubmittedToAssigned = true;
            }
        }
        assertTrue(sawNoneToSubmitted);
        assertTrue(sawSubmittedToAssigned);
    }

    function test_accept_emits_assigned_to_in_audit() public {
        Target t = new Target(2);
        vm.prank(auditor);
        cell.register();
        vm.prank(protocol);
        token.approve(address(cell), 40 ether);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        uint256 id = cell.submitAudit(address(t), address(t).codehash, specHash, specToolId, specErrors, 40 ether, declared, 0, 0);
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);

        vm.recordLogs();
        vm.prank(auditor);
        cell.acceptAudit(id, specErrors);

        bytes32 topic = keccak256("AuditStateChanged(uint256,bytes32,uint8,uint8)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool saw;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != topic) continue;
            (uint8 from, uint8 to) = abi.decode(logs[i].data, (uint8, uint8));
            if (from == uint8(CellTypeDefs.AuditState.Assigned) && to == uint8(CellTypeDefs.AuditState.InAudit)) {
                saw = true;
            }
        }
        assertTrue(saw);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../../contracts/AuditCell.sol";
import "../../contracts/CellStorage.sol";
import "./CellTestDeploy.sol";

/// @dev Shared helpers for Gate A cell tests (declare + re-run, no signers).
abstract contract SpecValidationCellSetup is Test {
    bytes32 internal constant EMPTY_SPEC_ERRORS = keccak256("");

    function _registerSpecTool(AuditCell cell, bytes32 specToolId) internal {
        cell.registerTool(specToolId, true);
    }

    function _registerVerdictTool(AuditCell cell, bytes32 toolId) internal {
        cell.registerTool(toolId, false);
    }

    function _protocolAcceptAndAssignedAccept(
        AuditCell cell,
        uint256 auditId,
        address protocol,
        bytes32 specErrorsRoot
    ) internal {
        vm.prank(protocol);
        cell.protocolAcceptAuditor(auditId);
        address assigned = cell.auditAuditorOf(auditId);
        vm.prank(assigned);
        cell.acceptAudit(auditId, specErrorsRoot);
    }

    function _protocolAcceptAndAssignedAccept(AuditCell cell, uint256 auditId, address protocol) internal {
        _protocolAcceptAndAssignedAccept(cell, auditId, protocol, EMPTY_SPEC_ERRORS);
    }

    function _reachAwaitingWindow(
        AuditCell cell,
        uint256 auditId,
        address protocol,
        bytes32 verdictToolId,
        bytes32 resultRoot
    ) internal {
        _protocolAcceptAndAssignedAccept(cell, auditId, protocol, EMPTY_SPEC_ERRORS);
        address assigned = cell.auditAuditorOf(auditId);
        vm.prank(assigned);
        cell.provePass(auditId, verdictToolId, resultRoot);
    }

    function _auditState(AuditCell cell, uint256 id) internal view returns (CellTypeDefs.AuditState) {
        return cell.auditStateOf(id);
    }

    function _auditorFailed(AuditCell cell, address auditor) internal view returns (uint256 failed) {
        (, failed,,,,) = cell.auditors(auditor);
    }
}

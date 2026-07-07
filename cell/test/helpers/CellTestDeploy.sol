// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "../../contracts/CellToken.sol";
import "../../contracts/CellEscrow.sol";
import "../../contracts/AuditCell.sol";
import "../../contracts/IssuanceModule.sol";
import "../../contracts/ClaimDisputeModule.sol";
import "../../contracts/SpecGapModule.sol";
import "../../contracts/SpecArbiterModule.sol";
import "../../contracts/IntegrityReviewModule.sol";
import "../../contracts/StructuralUpgradeModule.sol";
import "../../contracts/FmeaRegistry.sol";
import "../../contracts/AssignmentModule.sol";
import "../../contracts/IAssignmentModule.sol";

/// @dev Shared testnet-in-a-box: cell trio + issuance + claim/dispute module wired like production.
library CellTestDeploy {
    struct Deployment {
        CellToken token;
        CellEscrow escrow;
        AuditCell cell;
        IssuanceModule issuance;
        ClaimDisputeModule claimModule;
        SpecGapModule specGapModule;
        SpecArbiterModule specArbiterModule;
        IntegrityReviewModule integrityReviewModule;
        StructuralUpgradeModule structuralUpgradeModule;
        FmeaRegistry fmeaRegistry;
        AssignmentModule assignmentModule;
    }

    function deploy(address admin) internal returns (Deployment memory d) {
        d = deployWithoutAssignment(admin);
        d.assignmentModule = new AssignmentModule(admin);
        d.assignmentModule.wire(address(d.cell));
        d.cell.setAssignmentModule(address(d.assignmentModule));
        d.assignmentModule.setAssignmentMode(IAssignmentModule.AssignmentMode.QueueFifo);
    }

    function deployWithoutAssignment(address admin) internal returns (Deployment memory d) {
        d.token = new CellToken();
        d.cell = new AuditCell(address(d.token));
        d.escrow = new CellEscrow(address(d.token));
        d.issuance = new IssuanceModule(admin);
        d.claimModule = new ClaimDisputeModule(admin);
        d.specGapModule = new SpecGapModule(admin);
        d.specArbiterModule = new SpecArbiterModule(admin);
        d.integrityReviewModule = new IntegrityReviewModule(admin);
        d.structuralUpgradeModule = new StructuralUpgradeModule(admin);
        d.fmeaRegistry = new FmeaRegistry(admin);
        d.issuance.wire(address(d.cell), address(d.token), address(d.escrow));
        d.claimModule.wire(address(d.cell));
        d.fmeaRegistry.wireClaimModule(address(d.claimModule));
        d.claimModule.wireFmeaRegistry(address(d.fmeaRegistry));
        d.specGapModule.wire(address(d.cell));
        d.specArbiterModule.wire(address(d.cell));
        d.integrityReviewModule.wire(address(d.cell), address(d.specArbiterModule));
        d.structuralUpgradeModule.wire(address(d.cell), address(d.issuance));
        d.issuance.setStructuralModule(address(d.structuralUpgradeModule));
        d.escrow.setNetwork(address(d.cell));
        d.escrow.setIssuanceModule(address(d.issuance));
        d.escrow.setStructuralUpgradeModule(address(d.structuralUpgradeModule));
        d.escrow.setIntegrityReviewModule(address(d.integrityReviewModule));
        d.cell.setTreasuryEscrow(address(d.escrow));
        d.cell.setIssuanceModule(address(d.issuance));
        d.cell.setDisputeModule(0, address(d.claimModule));
        d.cell.setDisputeModule(1, address(d.specGapModule));
        d.cell.setDisputeModule(2, address(d.specArbiterModule));
        d.cell.setDisputeModule(3, address(d.integrityReviewModule));
        d.cell.setDisputeModule(4, address(d.structuralUpgradeModule));
    }

    function attachMinter(Deployment memory d) internal {
        d.token.setMinter(address(d.issuance));
    }

    function registerDefaultTools(Deployment memory d, bytes32 specToolId, bytes32 verdictToolId) internal {
        d.cell.registerTool(specToolId, true);
        d.cell.registerTool(verdictToolId, false);
    }

    function submitAudit(
        AuditCell cell,
        address deployed,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        uint256 bounty,
        bytes32[] memory declaredVerdictTools,
        uint256 supersedesAuditId
    ) internal returns (uint256) {
        return submitAudit(
            cell, deployed, specHash, specToolId, specErrorsRoot, bounty, declaredVerdictTools, supersedesAuditId, 0
        );
    }

    function submitAudit(
        AuditCell cell,
        address deployed,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        uint256 bounty,
        bytes32[] memory declaredVerdictTools,
        uint256 supersedesAuditId,
        uint256 auditWindow
    ) internal returns (uint256) {
        return cell.submitAudit(
            deployed,
            deployed.codehash,
            specHash,
            specToolId,
            specErrorsRoot,
            bounty,
            declaredVerdictTools,
            supersedesAuditId,
            auditWindow
        );
    }
}

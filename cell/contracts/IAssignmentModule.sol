// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IAssignmentModule — X7 assignment CRD satellite interface.
/// @notice Ordinary-audit assignment policy, external to the cell. The cell delegates ordinary
///         selection to `pickOrdinary` (with an in-cell FIFO fallback on address(0)); the dispute/
///         fix lanes stay in-cell FIFO+exclusion. Reject memory + dyad counters live in this module's
///         own storage — zero new frozen cell storage. Spec: proposals/assignment-crd-satellite-proposal.txt
interface IAssignmentModule {
    enum AssignmentMode {
        RandomConstrained, // default — reservoir draw over eligible, non-excluded, dyad-capped pool
        QueueFifo // rollback — module returns address(0), cell uses its FIFO head
    }

    /// @notice Select an ordinary-audit auditor. Returns address(0) → cell falls back to FIFO (liveness).
    ///         State-changing (per-audit re-roll counter) so re-assignment after a decline differs.
    function pickOrdinary(uint256 auditId, address protocol) external returns (address);

    /// @notice onlyCell hook — record a protocol-reject so the auditor is excluded on re-roll.
    function noteReject(uint256 auditId, address auditor) external;

    /// @notice onlyCell hook — record an auditor-decline so the auditor is excluded on re-roll.
    function noteDecline(uint256 auditId, address auditor) external;

    /// @notice onlyCell hook — increment the protocol↔auditor dyad counter on audit completion.
    function noteCompletion(address protocol, address auditor) external;

    // ---- views ----
    function assignmentMode() external view returns (AssignmentMode);
    function maxDyadRepeats() external view returns (uint256);
    function rejectedOnAudit(uint256 auditId, address auditor) external view returns (bool);
    function protocolAuditorCompleted(address protocol, address auditor) external view returns (uint256);
}

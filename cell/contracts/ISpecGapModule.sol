// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./SpecGapLib.sol";

interface ISpecGapModule {
    function openSpecGap(
        uint256 originalAuditId,
        bytes32 classId,
        bytes32 finderToolId,
        bytes32 resultRoot,
        bytes32 evaluatorToolId,
        bytes32 invariantId,
        bytes32 locationCommitment,
        bytes32 witnessCommitment,
        bytes32 contextRoot
    ) external;

    function protocolConcedeSpecGap(uint256 auditId, bytes32 classId) external;
    function protocolDeclineSpecGapRelevance(uint256 auditId, bytes32 classId) external;
    function protocolContestSpecGap(uint256 auditId, bytes32 classId, uint256 disputeBounty)
        external
        returns (uint256 disputeId);
    function confirmSpecGapSilence(uint256 auditId, bytes32 classId) external;
    function adoptSpecGap(uint256 auditId, bytes32 classId, uint256 discoveryReward) external;
    function expireSpecGap(uint256 auditId, bytes32 classId) external;
    function expireSpecGapDispute(uint256 auditId, bytes32 classId) external;

    function resolveFromDispute(uint256 originalAuditId, uint256 disputeId) external;

    function specGapStatusOf(uint256 auditId, bytes32 classId) external view returns (SpecGapLib.Status);
    function activeSpecGapDisputeAuditId(uint256 auditId, bytes32 classId) external view returns (uint256);
    function evaluatorForDispute(uint256 disputeId) external view returns (bytes32);
}

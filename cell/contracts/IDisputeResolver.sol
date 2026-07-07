// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

interface IDisputeResolver {
    function resolveFromDispute(uint256 originalId, uint256 disputeId) external;
}

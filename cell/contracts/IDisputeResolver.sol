// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IDisputeResolver {
    function resolveFromDispute(uint256 originalId, uint256 disputeId) external;
}

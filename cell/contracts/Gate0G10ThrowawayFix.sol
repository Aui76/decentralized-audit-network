// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title Gate0G10ThrowawayFix
/// @dev R4 throwaway fix artifact — distinct codehash; not a real security fix.
contract Gate0G10ThrowawayFix {
    uint256 public immutable salt;

    constructor(uint256 s) {
        salt = s;
    }
}

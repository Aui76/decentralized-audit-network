// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @dev Smoke PASS bounty target — distinct runtime codehash via `salt`; no planted bug.
contract SmokeTarget {
    uint256 public immutable salt;

    constructor(uint256 s) {
        salt = s;
    }
}

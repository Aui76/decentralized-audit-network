// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @dev Minimal audit target for genesis bootstrap (distinct codehash via salt).
contract GenesisBootstrapTarget {
    uint256 public immutable salt;

    constructor(uint256 s) {
        salt = s;
    }
}

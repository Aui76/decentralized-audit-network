// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./IEntropyProvider.sol";

/// @dev Stateless entropy read for dispute/arbiter draws. Never selfdestruct.
library AssignmentEntropyLib {
    function providerSeed(address entropyProvider, bytes32 salt) internal view returns (bytes32) {
        return IEntropyProvider(entropyProvider).seed(salt);
    }
}

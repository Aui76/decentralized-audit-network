// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @dev G-10: Option F seam — claim proof verification at the claim door.
interface IRunProofVerifier {
    function verify(bytes32 statement, bytes calldata proof) external view returns (bool ok);
}

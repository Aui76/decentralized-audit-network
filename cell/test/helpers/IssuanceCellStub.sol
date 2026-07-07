// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "../../contracts/IssuanceModule.sol";

/// @dev Minimal cell stub for IssuanceModule unit tests (auditors view + settle relay).
contract IssuanceCellStub {
    IssuanceModule public immutable issuance;

    constructor(IssuanceModule _issuance) {
        issuance = _issuance;
    }

    function auditors(address)
        external
        pure
        returns (uint256, uint256, uint256, uint256, uint256, bool)
    {
        return (0, 0, 0, 0, 0, false);
    }

    function settlePositiveBlock(uint256 id, address auditor, address protocol, uint256 rawBounty)
        external
        returns (uint256, uint256, uint256)
    {
        return issuance.settlePositiveBlock(id, auditor, protocol, rawBounty);
    }
}

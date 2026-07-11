// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @dev Gate A spec-challenge overlay (F-44 / X1). Settlement-touching organ — not in-cell.
interface ISpecArbiterModule {
    struct SpecChallenge {
        address challenger;
        bytes32 failErrorsRoot;
        uint256 stakeAmount;
        uint256 openedAt;
        bool active;
        address specArbiter;
    }

    function challengeActive(uint256 auditId) external view returns (bool);

    function specChallenges(uint256 auditId)
        external
        view
        returns (
            address challenger,
            bytes32 failErrorsRoot,
            uint256 stakeAmount,
            uint256 openedAt,
            bool active,
            address specArbiter
        );

    function specDefendedChallengeCount(uint256 auditId, address challenger) external view returns (uint256);

    function challengeSpecInvalid(uint256 auditId, bytes32 failErrorsRoot) external;

    function defendSpecChallenge(uint256 auditId, bytes32 passErrorsRoot) external;

    function declareSpecArbitrament(uint256 auditId, bytes32 specErrorsRoot) external;

    function reassignSpecArbiter(uint256 auditId) external;

    function expireSilentSpecArbiter(uint256 auditId) external;

    function finalizeSpecChallenge(uint256 auditId) external;
}

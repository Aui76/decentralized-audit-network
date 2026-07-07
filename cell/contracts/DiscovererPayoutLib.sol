// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

interface IPayoutToken {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IPayoutEscrow {
    function escrowBalance() external view returns (uint256);
    function payDiscoverer(address recipient, uint256 amount, uint256 maxIterations) external returns (uint256);
}

/// @dev Discoverer payout math extracted from AuditCell for EIP-170 headroom (P1 gate 4).
library DiscovererPayoutLib {
    error BountyTopupTransferFailed();
    error BountyRefundFailed();

    function pay(
        IPayoutToken token,
        IPayoutEscrow escrow,
        uint256 discoveryCapBps,
        uint256 discoveryFloorBps,
        uint256 payDiscovererMaxIterations,
        address protocol,
        address claimant,
        address boostSubject,
        uint256 escrowDraw,
        bool bountyPotLocked,
        uint256 bounty
    ) external returns (uint256 paid) {
        uint256 bountyTopupPaid = 0;

        if (escrowDraw > 0) {
            uint256 escrowBal = address(escrow) != address(0) ? escrow.escrowBalance() : 0;
            uint256 escrowCap = (escrowBal * discoveryCapBps) / 10_000;
            uint256 floorCap = (bounty * discoveryFloorBps) / 10_000;
            uint256 effectiveCap = escrowCap > floorCap ? escrowCap : floorCap;
            uint256 payoutTarget = escrowDraw < effectiveCap ? escrowDraw : effectiveCap;
            // M-2 (G-18): never pay a discoverer more than the escrowed bounty. The reputation boost may order a
            // larger draw, but it cannot be PAID above the stake — kills the claim-ring escrow drain at the one
            // choke point every payout takes. See body/proposals/fix-payout-cap-proposal.txt.
            if (payoutTarget > bounty) payoutTarget = bounty;

            if (payoutTarget > 0 && address(escrow) != address(0)) {
                paid = escrow.payDiscoverer(claimant, payoutTarget, payDiscovererMaxIterations);
            }
            if (payoutTarget > paid && bountyPotLocked) {
                uint256 shortfall = payoutTarget - paid;
                uint256 topup = shortfall > bounty ? bounty : shortfall;
                if (topup > 0) {
                    if (!token.transfer(claimant, topup)) revert BountyTopupTransferFailed();
                    bountyTopupPaid = topup;
                    paid += topup;
                }
            }
        }

        if (bountyPotLocked && bounty > 0) {
            uint256 refund = bounty > bountyTopupPaid ? (bounty - bountyTopupPaid) : 0;
            if (refund > 0 && !token.transfer(protocol, refund)) revert BountyRefundFailed();
        }
    }
}

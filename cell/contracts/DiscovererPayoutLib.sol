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

    /// @notice A discoverer was paid LESS than their computed target, and this is the only place that
    ///         says so. Three routes converge here (2026-08-09 loudness fix): the escrow short with the
    ///         bounty pot already disbursed (no topup source — `bountyPotLocked` false), the escrow
    ///         drained ahead of the claim (PC-26), and `_payFromBucket`'s iteration budget cutting the
    ///         walk short (underpays even a FULL escrow). Deliberately an event and NOT a revert:
    ///         reverting would let anyone who can depress the escrow BLOCK settlement outright — a
    ///         strictly worse lever than the silence being fixed. The claim settles; the shortfall
    ///         becomes arguable.
    event DiscovererShortfall(address indexed claimant, uint256 target, uint256 paid, bool bountyPotLocked);

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
            // Loudness (2026-08-09): `paid` is now final for the escrow leg — every source has had its
            // chance. If it is still short of the target: say so where an indexer will see it.
            // DEC-48 (2026-10-01): the gap is no longer recorded as debt. On a post-confirm claim the
            // market pays the finding (the finder's price, ClaimDisputeModule) and the pool adds a
            // bonus from what it holds at that moment: best-effort, no IOU. On a pre-confirm claim the
            // pot's topup above always reaches the target, so nothing was ever recorded there. The
            // escrow keeps `recordDiscovererDebt` and `settleDiscovererDebt`; nothing on the cell
            // writes into them any more, and the live cell keeps calling the library it was linked
            // with until a hull redeploy, so the module also clamps its bonus to the pool's balance.
            if (paid < payoutTarget) {
                emit DiscovererShortfall(claimant, payoutTarget, paid, bountyPotLocked);
            }
        }

        if (bountyPotLocked && bounty > 0) {
            uint256 refund = bounty > bountyTopupPaid ? (bounty - bountyTopupPaid) : 0;
            if (refund > 0 && !token.transfer(protocol, refund)) revert BountyRefundFailed();
        }
    }
}

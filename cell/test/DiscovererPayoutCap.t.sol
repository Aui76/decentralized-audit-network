// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

// Teeth for M-2 (G-18): the discoverer payout is capped at 1x the escrowed bounty.
// Unit-tests the choke point directly (DiscovererPayoutLib.pay). REMOVE the cap line in the library and
// test_payout_never_exceeds_bounty_large_pool must FAIL — that's the teeth.

import "forge-std/Test.sol";
import "../contracts/DiscovererPayoutLib.sol";

contract MockToken {
    function transfer(address, uint256) external pure returns (bool) { return true; }
}

contract MockEscrow {
    uint256 public bal;
    constructor(uint256 b) { bal = b; }
    function escrowBalance() external view returns (uint256) { return bal; }
    function payDiscoverer(address, uint256 amount, uint256) external view returns (uint256) {
        return amount <= bal ? amount : bal; // pays what's asked, up to its balance
    }
}

contract DiscovererPayoutCap is Test {
    MockToken token;
    uint256 constant CAP_BPS = 500;    // discoveryCapBps — 5% of the pool
    uint256 constant FLOOR_BPS = 5000; // discoveryFloorBps — 50% of the bounty
    address constant P = address(0xA11CE);
    address constant C = address(0xC1A1);
    address constant B = address(0xB0B);

    function setUp() public { token = new MockToken(); }

    function _pay(uint256 escrowBal, uint256 escrowDraw, uint256 bounty) internal returns (uint256) {
        MockEscrow escrow = new MockEscrow(escrowBal);
        return DiscovererPayoutLib.pay(
            IPayoutToken(address(token)), IPayoutEscrow(address(escrow)),
            CAP_BPS, FLOOR_BPS, 8, P, C, B, escrowDraw, false, bounty
        );
    }

    // Big pool: without the cap this pays 10 (5% of 200) on a 5 bounty — the drain. The cap must clip to 5.
    function test_payout_never_exceeds_bounty_large_pool() public {
        uint256 paid = _pay(200 ether, 15 ether, 5 ether); // boost 3x → escrowDraw 15
        assertLe(paid, 5 ether, "payout must not exceed the bounty");
        assertEq(paid, 5 ether, "capped exactly at the bounty on a large pool");
    }

    // Small pool: the cap must NOT inflate a payout that was already below the bounty.
    function test_cap_does_not_inflate_small_pool() public {
        uint256 paid = _pay(40 ether, 15 ether, 5 ether); // 5% of 40 = 2; floor 50% of 5 = 2.5 → 2.5
        assertLe(paid, 5 ether);
        assertEq(paid, 2.5 ether, "unchanged when already below the bounty");
    }
}

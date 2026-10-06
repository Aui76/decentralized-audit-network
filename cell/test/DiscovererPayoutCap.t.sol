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
    // Debt-ledger capture (2026-08-09): the lib now records shortfalls; the mock implements the
    // interface member and remembers the call so tests can assert the exact gap. Extending the mock
    // is legitimate isolation, not a weakened claim — no existing assertion changed.
    address public lastDebtClaimant;
    uint256 public lastDebtAmount;
    uint256 public debtCalls;

    constructor(uint256 b) { bal = b; }
    function escrowBalance() external view returns (uint256) { return bal; }
    function payDiscoverer(address, uint256 amount, uint256) external view returns (uint256) {
        return amount <= bal ? amount : bal; // pays what's asked, up to its balance
    }
    function recordDiscovererDebt(address claimant, uint256 amount) external {
        lastDebtClaimant = claimant;
        lastDebtAmount = amount;
        debtCalls += 1;
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

    // ---- Loudness (2026-08-09): a shortfall must EMIT; a full payment must not ----
    // NOTE 0.8.20: qualified access to a library's events (emit Lib.Event / Lib.Event.selector) needs
    // 0.8.21+, so the event is re-declared locally (expectEmit matches topics+data, not the definer)
    // and topic0 is derived from the signature string.

    event DiscovererShortfall(address indexed claimant, uint256 target, uint256 paid, bool bountyPotLocked);
    bytes32 constant SHORTFALL_TOPIC0 = keccak256("DiscovererShortfall(address,uint256,uint256,bool)");

    // Escrow nearly empty, pot UNLOCKED (post-settlement claim): target = floor 50% of 5 = 2.5,
    // escrow can only pay 1, no topup source -> event with the exact gap. DEC-48 (2026-10-01): the gap is
    // NOT recorded as debt any more. The market pays the finding on a post-confirm claim and the pool's
    // share is a best-effort bonus; the mock keeps its ledger so this test can prove nothing wrote into it.
    function test_shortfall_emits_when_escrow_short() public {
        MockEscrow escrow = new MockEscrow(1 ether);
        vm.expectEmit(true, false, false, true);
        emit DiscovererShortfall(C, 2.5 ether, 1 ether, false);
        uint256 paid = DiscovererPayoutLib.pay(
            IPayoutToken(address(token)), IPayoutEscrow(address(escrow)),
            CAP_BPS, FLOOR_BPS, 8, P, C, B, 15 ether, false, 5 ether
        );
        assertEq(paid, 1 ether, "paid only what the escrow held");
        assertEq(escrow.debtCalls(), 0, "DEC-48: a shortfall is loud but records no debt");
        assertEq(escrow.lastDebtAmount(), 0, "nothing owed on the ledger");
    }

    // Same short escrow but the pot is LOCKED: the topup covers the gap from the bounty, paid == target,
    // NO event. This is also the first direct test the topup path has ever had.
    function test_topup_prevents_shortfall_event_when_locked() public {
        MockEscrow escrow = new MockEscrow(1 ether);
        vm.recordLogs();
        uint256 paid = DiscovererPayoutLib.pay(
            IPayoutToken(address(token)), IPayoutEscrow(address(escrow)),
            CAP_BPS, FLOOR_BPS, 8, P, C, B, 15 ether, true, 5 ether
        );
        assertEq(paid, 2.5 ether, "escrow 1 + bounty topup 1.5 = the 2.5 target");
        assertEq(escrow.debtCalls(), 0, "no debt when the topup made the claimant whole");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != SHORTFALL_TOPIC0,
                "no shortfall event when the topup made the claimant whole"
            );
        }
    }

    // A payment made in full emits nothing - the event must never cry wolf.
    function test_no_event_when_paid_in_full() public {
        MockEscrow escrow = new MockEscrow(200 ether);
        vm.recordLogs();
        uint256 paid = DiscovererPayoutLib.pay(
            IPayoutToken(address(token)), IPayoutEscrow(address(escrow)),
            CAP_BPS, FLOOR_BPS, 8, P, C, B, 15 ether, false, 5 ether
        );
        assertEq(paid, 5 ether, "the existing large-pool case, paid in full");
        assertEq(escrow.debtCalls(), 0, "a full payment records no debt");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != SHORTFALL_TOPIC0,
                "no shortfall event on a full payment"
            );
        }
    }
}

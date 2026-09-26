// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

// ---------------------------------------------------------------------------
// PC-3 (DEC-31) — Option A: lifetime cumulative cap on the auditor positive-block mint.
// Proves the BOUND binds: once positiveBlockMintedCumulative reaches the lifetime cap
// (bps of totalSupply, read at mint time), the auditor mint clamps to the remaining
// budget and then to ZERO — and the cap is GLOBAL, so fresh sock-puppet auditors and
// protocols share the one budget (the anti-Sybil property; this is what closes the ring's
// UNBOUNDEDNESS). Drives settlePositiveBlock directly via IssuanceCellStub, mirroring the
// unit-level tests in SybilFarmClosure.t.sol.
//   run:  cd cell && forge test --match-contract PC3PositiveBlockMintCap -vv
// ---------------------------------------------------------------------------

import "forge-std/Test.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/IssuanceModule.sol";
import "./helpers/IssuanceCellStub.sol";

contract PC3PositiveBlockMintCap is Test {
    IssuanceModule iss;
    IssuanceCellStub stub;
    CellToken t;
    CellEscrow e;

    address holder = address(0xF00D);

    function _wire(uint256 floorEther) internal {
        iss = new IssuanceModule(address(this));
        stub = new IssuanceCellStub(iss);
        t = new CellToken();
        e = new CellEscrow(address(t));
        // Supply floor BEFORE the minter is set → this becomes the LATCHED cap basis at the first armed
        // settle. Sized per-test: a large floor keeps the cap far above a single small reward (low-bps
        // regime); a small floor lets a HIGH-bps cap still bind within a bounded loop (top-of-range regime).
        t.genesisMint(holder, floorEther);
        iss.wire(address(stub), address(t), address(e));
        t.setMinter(address(iss));
        e.setIssuanceModule(address(iss));
    }

    // Build emaSlow > 0 (so reward > 0) with the cap DISABLED, across distinct auditor/protocol
    // pairs — mirrors _issuanceWarm in SybilFarmClosure.t.sol. cumulative stays 0 while cap==0
    // (the clamp block is skipped entirely when positiveBlockMintCapBps==0).
    function _warmNoCap(uint256 bounty) internal {
        iss.setPositiveBlockMintCap(0);
        address[4] memory auds = [address(0xB100), address(0xB200), address(0xB300), address(0xB400)];
        address[4] memory pros = [address(0xC100), address(0xC200), address(0xC300), address(0xC400)];
        for (uint256 i = 0; i < 4; i++) {
            stub.settlePositiveBlock(i + 100, auds[i], pros[i], bounty);
            stub.settlePositiveBlock(i + 200, auds[i], pros[(i + 1) % 4], bounty);
        }
        assertEq(iss.positiveBlockMintedCumulative(), 0, "cumulative untouched while cap disabled");
    }

    function test_lifetime_cap_binds_and_is_global() public {
        _wire(1_000 ether);
        _warmNoCap(50 ether);

        // Honest-bootstrap sanity: with the cap OFF, a settle mints > 0 (we did not break issuance).
        (uint256 preMint,,) = stub.settlePositiveBlock(1_000, address(0xA0A0), address(0xD0D0), 50 ether);
        assertGt(preMint, 0, "below/without cap, positive-block mint is still paid");

        // Enable a cap sized to ~3 rewards so it binds within a handful of settles, robustly,
        // regardless of the exact reward magnitude at this profile.
        uint256 r = iss.nextPositiveBlockReward();
        assertGt(r, 0, "warm produced a positive next-reward");
        uint256 T = t.totalSupply();
        // ceil so a tiny reward still yields bps >= 1; sized to ~3 rewards so the budget binds within the loop
        uint256 bps = (r * 3 * 10_000 + T - 1) / T;
        if (bps == 0) bps = 1;
        iss.setPositiveBlockMintCap(bps);
        uint256 capAtEnable = (t.totalSupply() * bps) / 10_000;
        emit log_named_uint("per-settle reward r (wei)", r);
        emit log_named_uint("lifetime cap at enable (wei)", capAtEnable);

        // Settle repeatedly with DISTINCT auditors/protocols each time (sock puppets). Track the
        // minted-to-auditor amounts and prove: mints continue until the budget is spent, then ZERO,
        // and the zero holds for brand-new wallets (global budget, not per-wallet).
        uint256 mintedSum;
        bool sawZero;
        uint256 firstZeroAt;
        for (uint256 k = 0; k < 80; k++) {
            address aud = address(uint160(uint256(keccak256(abi.encode("aud", k)))));
            address pro = address(uint160(uint256(keccak256(abi.encode("pro", k)))));
            (uint256 m,,) = stub.settlePositiveBlock(2_000 + k, aud, pro, 50 ether);
            if (m == 0) {
                if (!sawZero) { sawZero = true; firstZeroAt = k; }
            } else {
                // once the budget is exhausted it must NEVER pay again, even to a fresh wallet
                assertTrue(!sawZero, "a mint occurred AFTER the budget was exhausted (cap not global / leaked)");
                mintedSum += m;
            }
        }

        assertTrue(sawZero, "the lifetime cap bound within the loop (mints stopped)");
        emit log_named_uint("settles before first zero", firstZeroAt);
        emit log_named_uint("total auditor mint under the cap (wei)", mintedSum);

        // The counter equals what was actually paid, and no further budget remains. Ceiling is basis x bps
        // where basis is the LATCHED snapshot (NOT live totalSupply) — the fix for the live-supply divergence.
        assertEq(iss.positiveBlockMintedCumulative(), mintedSum, "cumulative == sum actually minted");
        uint256 fixedCap = (iss.positiveBlockCapBasis() * iss.positiveBlockMintCapBps()) / 10_000;
        assertGe(iss.positiveBlockMintedCumulative(), fixedCap, "cumulative has reached the fixed (latched) cap");

        // Explicit global-budget proof: a pristine auditor+protocol pair still mints ZERO.
        (uint256 fresh,,) = stub.settlePositiveBlock(9_999, address(0xFEED), address(0xBEEF), 50 ether);
        assertEq(fresh, 0, "fresh sock-puppet shares the one exhausted budget (mints zero)");
    }

    // The cap is a pure ceiling: with a generous cap, nothing changes vs the uncapped path —
    // guards against the clamp perturbing normal below-cap issuance.
    function test_generous_cap_does_not_perturb_below_budget() public {
        _wire(1_000 ether);
        _warmNoCap(50 ether);
        // generous cap: 2% of the latched basis, far above a single small reward
        iss.setPositiveBlockMintCap(200);
        (uint256 m,,) = stub.settlePositiveBlock(1, address(0xA1), address(0xD1), 50 ether);
        assertGt(m, 0, "below the cap the mint is unchanged");
        assertEq(iss.positiveBlockMintedCumulative(), m, "cumulative counts the paid mint");
    }

    // REGRESSION for the review finding (2026-07-18) — MUST GO RED IF THE FIX IS REVERTED.
    // A LIVE-supply ceiling (totalSupply x bps) NEVER binds for bps ≳ 4460: the positive-block mint drives
    // totalSupply ~2.03x faster than the auditor-share counter (auditor + 100% treasury + 3.05% founder), so
    // at a top-of-range 9000 bps the ceiling grows ~1.83x reward/settle while the counter grows ~1x reward/settle
    // — the ceiling OUTRUNS the counter and the auditor mint NEVER reaches zero. The latched basis freezes the
    // ceiling, so the monotone counter reaches it and the mint hits ZERO. THE TEETH: assertTrue(sawZero) below is
    // GREEN under the latch and RED if the clamp's `lifetimeCap` is reverted to `(supplyForCap * bps) / 10_000`.
    // Verify that by hand before trusting this test — a regression test that cannot fail on the un-fixed code is
    // decoration, which is exactly what the prior Δremaining==m version was (a bookkeeping identity true either way).
    //
    // Sizing: a TINY genesis floor and NO warm-up latch a tiny basis, so a 90% budget is a small absolute number
    // reached in a few settles. reward>0 on the first armed settle via the preview EMA (emaSlow==0) with LP
    // unfunded → uncapped activity mint (IssuanceModule _positiveBlockRewardFromEmaSlow, effLp==0 branch). The
    // earlier version's failure was _warmNoCap inflating the basis before arming — a test-sizing bug, not a fault.
    function test_cap_binds_at_top_of_range() public {
        _wire(0.01 ether);                     // tiny latch basis → a 90% budget binds within a few settles
        iss.setPositiveBlockMintCap(9_000);    // 90% — the regime a live-supply ceiling can NEVER bind

        // First armed settle: preview EMA gives reward>0 (LP unfunded → uncapped activity mint); the basis latches
        // at the ~0.01-ether floor (supply BEFORE this settle's mint), NOT a warm-inflated supply.
        (uint256 m0,,) = stub.settlePositiveBlock(1, address(0xA1), address(0xD1), 50 ether);
        assertGt(m0, 0, "first armed settle mints (below the fixed ceiling)");
        uint256 basis = iss.positiveBlockCapBasis();
        assertGt(basis, 0, "basis latched once supply exists");
        uint256 ceiling = (basis * 9_000) / 10_000;

        // Drive DISTINCT sock-puppets until the auditor mint is ZERO. Under the latch this is GUARANTEED (frozen
        // ceiling + monotone counter). Under a live-supply ceiling at 9000 bps it NEVER happens — the loop runs to
        // its bound with sawZero=false and the assert below fails. That divergence is the entire point.
        bool sawZero;
        uint256 mintedSum = m0;
        uint256 firstZeroAt;
        for (uint256 k = 0; k < 1_000; k++) {
            address aud = address(uint160(uint256(keccak256(abi.encode("hi", k)))));
            address pro = address(uint160(uint256(keccak256(abi.encode("hp", k)))));
            (uint256 m,,) = stub.settlePositiveBlock(3_000 + k, aud, pro, 50 ether);
            assertEq(iss.positiveBlockCapBasis(), basis, "basis is latched set-once (ceiling frozen)");
            if (m == 0) { sawZero = true; firstZeroAt = k; break; }
            assertTrue(!sawZero, "a mint occurred AFTER the budget was exhausted (cap not global / leaked)");
            mintedSum += m;
        }

        assertTrue(sawZero, "a 9000-bps cap BINDS to ZERO under the latched basis (RED under a live-supply ceiling)");
        emit log_named_uint("settles before first zero at 9000 bps", firstZeroAt);
        emit log_named_uint("total auditor mint under the 9000-bps cap (wei)", mintedSum);
        assertGe(iss.positiveBlockMintedCumulative(), ceiling, "counter reached the frozen ceiling");
        assertEq(iss.positiveBlockMintedCumulative(), mintedSum, "cumulative == sum actually minted");

        // Global-budget proof: a pristine auditor+protocol pair still mints ZERO once the one budget is spent.
        (uint256 fresh,,) = stub.settlePositiveBlock(9_999, address(0xFEED), address(0xBEEF), 50 ether);
        assertEq(fresh, 0, "fresh sock-puppet shares the one exhausted budget (mints zero)");
    }
}

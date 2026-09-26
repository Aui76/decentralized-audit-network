// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../contracts/satellites/AuditEthMembrane.sol";

/// Minimal standard ERC-20 stand-in for AUDIT. Decoupled on purpose: the membrane must work against any
/// standard token, and the test must not drag the whole cell in.
contract MockAudit {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

/// Re-enters `sell` the instant it is paid ETH. If the guard works, the whole outer call reverts and no
/// ETH is extracted twice.
///
/// @dev M-3, fixed 2026-08-22. TWO defects, and the first one made the second invisible:
///      (1) the re-entrant hit was `m.sell(1, 0)` -- ONE WEI of AUDIT, which floors to zero ETH out and
///          reverts `ZeroOutput()` whether or not the guard exists. So the attack could never reach the
///          guard, and the test observed a revert that had nothing to do with re-entrancy.
///      (2) the assertion was a bare `vm.expectRevert()`, which accepts ANY revert -- including that one.
///      MEASURED before the fix, not argued: with `if (_entered == 2) revert Reentrancy();` deleted from
///      the modifier, `test_reentrancy_on_sell_is_blocked` still PASSED. A test that passes against the
///      code it exists to guard is asserting nothing.
///      The re-entrant amount is now material (`REENTRANT_AUD`) and `catching` lets a test capture the
///      INNER revert so the guard's own selector can be asserted, rather than inferring it from the
///      outer `EthSendFailed` the propagating shape produces.
contract ReentrantSeller {
    AuditEthMembrane immutable m;
    MockAudit immutable a;
    bool public armed;
    /// @dev When true the inner revert is caught and recorded instead of propagating, so a test can read
    ///      WHICH error fired. When false the revert propagates and blows up the whole outer call.
    bool public catching;
    bytes public innerErr;
    bool public innerReturned;

    /// @dev Material: large enough that the re-entrant sell would SUCCEED if the guard were absent, so a
    ///      deleted guard changes the observed outcome instead of hiding behind ZeroOutput.
    uint256 public constant REENTRANT_AUD = 10 ether;

    constructor(AuditEthMembrane _m, MockAudit _a) { m = _m; a = _a; }
    function arm() external { armed = true; }
    function armCatching() external { armed = true; catching = true; }
    function attack(uint256 audIn) external {
        a.approve(address(m), type(uint256).max);
        m.sell(audIn, 0);
    }
    receive() external payable {
        if (!armed) return;
        armed = false;
        if (catching) {
            try m.sell(REENTRANT_AUD, 0) returns (uint256) {
                innerReturned = true;               // guard absent: the re-entrant sell went through
            } catch (bytes memory err) {
                innerErr = err;                     // guard present: record WHICH error fired
            }
        } else {
            m.sell(REENTRANT_AUD, 0);               // re-entrant hit -> must revert, taking the outer call with it
        }
    }
}

contract AuditEthMembraneTest is Test {
    MockAudit aud;
    AuditEthMembrane m;

    address USER = address(0xBEEF);
    uint16 constant FEE = 30;           // 0.30% per side
    uint256 constant AUD_SEED = 1_000_000 ether;
    uint256 constant ETH_SEED = 1_000 ether;
    uint256 constant BPS = 10_000;

    function setUp() public {
        vm.deal(address(this), 100_000 ether);
        aud = new MockAudit();
        aud.mint(address(this), AUD_SEED);
        // Approve the membrane's FUTURE address (standard Foundry pattern), then deploy: the constructor
        // pulls AUD_SEED via transferFrom and takes ETH_SEED as msg.value.
        uint256 nonce = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), nonce);
        aud.approve(predicted, AUD_SEED);
        m = new AuditEthMembrane{value: ETH_SEED}(address(aud), FEE, AUD_SEED);
        require(address(m) == predicted, "address prediction");
    }

    receive() external payable {}

    // ---- opening state --------------------------------------------------------------------------
    function test_constructor_sets_opening_reserves_and_price() public {
        (uint256 a, uint256 e) = m.getReserves();
        assertEq(a, AUD_SEED, "aud reserve");
        assertEq(e, ETH_SEED, "eth reserve");
        // opening mid price = ETH/AUD = 1000/1_000_000 = 0.001 ETH per AUDIT, scaled 1e18
        assertEq(m.midPriceEthPerAudE18(), (ETH_SEED * 1e18) / AUD_SEED, "opening mid");
    }

    function test_constructor_rejects_zero_fee_and_fat_fee() public {
        vm.expectRevert(AuditEthMembrane.BadFee.selector);
        new AuditEthMembrane{value: 1 ether}(address(aud), 0, 1 ether);
        vm.expectRevert(AuditEthMembrane.BadFee.selector);
        new AuditEthMembrane{value: 1 ether}(address(aud), 1000, 1 ether);
    }

    function test_constructor_rejects_zero_seed() public {
        vm.expectRevert(AuditEthMembrane.BadSeed.selector);
        new AuditEthMembrane{value: 0}(address(aud), FEE, 1 ether);
    }

    // ---- buy ------------------------------------------------------------------------------------
    /// @dev M-10 E1, fixed 2026-08-22. Was `return (a * afterFee) / (e + afterFee);` -- a
    ///      character-for-character copy of AuditEthMembrane.sol:104, so `assertEq(got, exp)` at the
    ///      call sites below proved only that the formula was typed twice: a sign error or an
    ///      inverted ratio pasted into both sides would still pass. Re-derived from the x*y=k
    ///      INVARIANT DEFINITION instead (new AUD reserve = k / new ETH reserve) -- a different
    ///      algebraic path that only agrees with the contract's shortcut when both are actually
    ///      correct, so a swapped numerator/denominator or a flipped sign in the contract's formula
    ///      would make this DISAGREE with `got`, not silently echo it.
    function _expectedBuy(uint256 ethIn) internal view returns (uint256) {
        (uint256 a, uint256 e) = m.getReserves();
        uint256 k = a * e;
        uint256 afterFee = (ethIn * (BPS - FEE)) / BPS;
        uint256 eNew = e + afterFee;
        // floor(a*afterFee/eNew) == a - ceil(k/eNew), an exact integer identity (a*afterFee =
        // a*eNew - k, and floor(a - r) = a - ceil(r) for integer a): so a - floor(k/eNew) is off by
        // exactly one whenever the division has a remainder, and this reconstructs ceil(k/eNew)
        // explicitly rather than truncating to floor(k/eNew) and hoping it lines up.
        uint256 aNewFloor = k / eNew;
        uint256 aNewCeil = (k % eNew == 0) ? aNewFloor : aNewFloor + 1;
        return a - aNewCeil;
    }

    function test_buy_pays_audit_and_updates_reserves() public {
        uint256 ethIn = 10 ether;
        uint256 exp = _expectedBuy(ethIn);
        vm.deal(USER, ethIn);
        vm.prank(USER);
        uint256 got = m.buy{value: ethIn}(0);
        assertEq(got, exp, "audOut matches formula");
        assertEq(aud.balanceOf(USER), exp, "user received AUDIT");
        (uint256 a, uint256 e) = m.getReserves();
        assertEq(e, ETH_SEED + ethIn, "eth reserve += full input (fee retained)");
        assertEq(a, AUD_SEED - exp, "aud reserve -= out");
    }

    function test_buy_slippage_reverts_when_below_min() public {
        uint256 ethIn = 10 ether;
        uint256 exp = _expectedBuy(ethIn);
        vm.deal(USER, ethIn);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(AuditEthMembrane.Slippage.selector, exp, exp + 1));
        m.buy{value: ethIn}(exp + 1);
    }

    function test_buy_zero_reverts() public {
        vm.expectRevert(AuditEthMembrane.ZeroInput.selector);
        m.buy{value: 0}(0);
    }

    // ---- sell -----------------------------------------------------------------------------------
    /// @dev M-10 E2, caught in review 2026-08-22: `test_sell_slippage_reverts_when_below_min` (below)
    ///      originally computed `(e0 * afterFee) / (a0 + afterFee)` inline -- character-for-character
    ///      the same shape as AuditEthMembrane.sol:122's `ethOut = (ethReserve * audInAfterFee) /
    ///      (audReserve + audInAfterFee)`. That is the exact echo E1 was fixed to stop being: a swapped
    ///      numerator/denominator or inverted ratio in the contract would be typed into this formula
    ///      too, and the test would still pass. Re-derived from the x*y=k invariant, symmetric to
    ///      `_expectedBuy` above (new ETH reserve = k / new AUD reserve, ceil reconstructed explicitly
    ///      so the integer identity holds exactly) -- NOT used by `test_sell_pays_eth_and_updates_reserves`,
    ///      whose own inline computation was reviewed and credited as independently tracked, not an echo.
    function _expectedSell(uint256 audIn) internal view returns (uint256) {
        (uint256 a, uint256 e) = m.getReserves();
        uint256 k = a * e;
        uint256 afterFee = (audIn * (BPS - FEE)) / BPS;
        uint256 aNew = a + afterFee;
        // Symmetric to _expectedBuy's identity: floor(e*afterFee/aNew) == e - ceil(k/aNew).
        uint256 eNewFloor = k / aNew;
        uint256 eNewCeil = (k % aNew == 0) ? eNewFloor : eNewFloor + 1;
        return e - eNewCeil;
    }

    function test_sell_pays_eth_and_updates_reserves() public {
        // first buy some AUDIT to sell
        vm.deal(USER, 10 ether);
        vm.prank(USER);
        uint256 audBought = m.buy{value: 10 ether}(0);

        (uint256 a0, uint256 e0) = m.getReserves();
        uint256 afterFee = (audBought * (BPS - FEE)) / BPS;
        uint256 expEth = (e0 * afterFee) / (a0 + afterFee);

        vm.startPrank(USER);
        aud.approve(address(m), audBought);
        uint256 balBefore = USER.balance;
        uint256 gotEth = m.sell(audBought, 0);
        vm.stopPrank();

        assertEq(gotEth, expEth, "ethOut matches formula");
        assertEq(USER.balance, balBefore + expEth, "user received ETH");
        (uint256 a1, uint256 e1) = m.getReserves();
        assertEq(a1, a0 + audBought, "aud reserve += in");
        assertEq(e1, e0 - expEth, "eth reserve -= out");
    }

    /// @dev M-9: sell-side revert coverage. `test_buy_zero_reverts` (above) exists buy-side; the
    ///      mirror never existed sell-side -- an asymmetry that reads like a copy left unfinished.
    function test_sell_zero_reverts() public {
        vm.expectRevert(AuditEthMembrane.ZeroInput.selector);
        m.sell(0, 0);
    }

    /// @dev M-9: sell-side revert coverage, mirroring `test_buy_slippage_reverts_when_below_min`.
    ///      Uses `_expectedSell` (M-10 E2 fix, 2026-08-22) rather than an inline echo of
    ///      AuditEthMembrane.sol:122 -- see that helper's doc comment for why.
    function test_sell_slippage_reverts_when_below_min() public {
        vm.deal(USER, 10 ether);
        vm.prank(USER);
        uint256 audBought = m.buy{value: 10 ether}(0);

        uint256 expEth = _expectedSell(audBought);

        vm.startPrank(USER);
        aud.approve(address(m), audBought);
        vm.expectRevert(abi.encodeWithSelector(AuditEthMembrane.Slippage.selector, expEth, expEth + 1));
        m.sell(audBought, expEth + 1);
        vm.stopPrank();
    }

    // ---- THE SPREAD: a round trip must lose money -----------------------------------------------
    function test_round_trip_loses_the_spread() public {
        vm.deal(USER, 100 ether);
        vm.startPrank(USER);
        uint256 aud1 = m.buy{value: 100 ether}(0);
        aud.approve(address(m), aud1);
        uint256 ethBack = m.sell(aud1, 0);
        vm.stopPrank();
        assertLt(ethBack, 100 ether, "buy-then-sell must return LESS than put in - that IS the spread");
    }

    // ---- SELF-THICKENING: k rises after a round trip --------------------------------------------
    function test_fees_grow_depth_k() public {
        uint256 kBefore = m.depth();
        vm.deal(USER, 100 ether);
        vm.startPrank(USER);
        uint256 aud1 = m.buy{value: 100 ether}(0);
        aud.approve(address(m), aud1);
        m.sell(aud1, 0);
        vm.stopPrank();
        assertGt(m.depth(), kBefore, "retained fees must grow k - the pool self-thickens");
    }

    // ---- UN-DRAINABILITY ------------------------------------------------------------------------
    function test_eth_reserve_cannot_be_emptied() public {
        // mint an absurd pile of AUDIT and dump it all
        uint256 whale = 1e30;
        aud.mint(USER, whale);
        vm.startPrank(USER);
        aud.approve(address(m), whale);
        m.sell(whale, 0);
        vm.stopPrank();
        (, uint256 e) = m.getReserves();
        assertGt(e, 0, "ETH reserve must remain strictly positive after a whale dump");
        assertGt(address(m).balance, 0, "actual ETH balance never zero");
    }

    function test_aud_reserve_cannot_be_emptied() public {
        uint256 whaleEth = 1e30;
        vm.deal(USER, whaleEth);
        vm.prank(USER);
        m.buy{value: whaleEth}(0);
        (uint256 a, ) = m.getReserves();
        assertGt(a, 0, "AUDIT reserve must remain strictly positive after a whale buy");
    }

    // ---- REENTRANCY -----------------------------------------------------------------------------
    /// The outer call must die. The revert is `EthSendFailed` and NOT `Reentrancy`, on purpose: the guard
    /// reverts inside the attacker's `receive()`, which makes the membrane's ETH send fail, and that is
    /// what surfaces. Naming the selector is the point -- a bare `vm.expectRevert()` accepted the
    /// `ZeroOutput()` a one-wei re-entrant hit produced, which is how this test passed with the guard
    /// deleted (M-3, measured 2026-08-22).
    function test_reentrancy_on_sell_is_blocked() public {
        ReentrantSeller atk = new ReentrantSeller(m, aud);
        aud.mint(address(atk), 1000 ether);
        // control: unarmed attacker sells fine
        atk.attack(10 ether);
        // armed: the re-entrant hit on ETH receipt must blow up the whole call
        aud.mint(address(atk), 1000 ether);
        atk.arm();
        vm.expectRevert(AuditEthMembrane.EthSendFailed.selector);
        atk.attack(10 ether);
    }

    /// The half the outer revert cannot show: WHICH error the guard raised. The attacker catches the
    /// inner revert, so the outer call completes, and the test asserts the recorded selector is
    /// `Reentrancy()`. Delete the guard and the re-entrant sell RETURNS instead -- `innerReturned` flips
    /// and both assertions below fail, which is the property `test_reentrancy_on_sell_is_blocked` alone
    /// could not give.
    function test_reentrancy_guard_raises_the_Reentrancy_selector() public {
        ReentrantSeller atk = new ReentrantSeller(m, aud);
        aud.mint(address(atk), 1000 ether);
        atk.armCatching();
        atk.attack(10 ether);

        assertFalse(atk.innerReturned(), "the re-entrant sell must NOT succeed - the guard is absent if it does");
        bytes memory err = atk.innerErr();
        assertEq(err.length, 4, "expected a bare 4-byte custom error selector from the guard");
        assertEq(bytes4(err), AuditEthMembrane.Reentrancy.selector, "guard must revert Reentrancy()");
    }

    // ---- DONATION IMMUNITY: pricing uses internal reserves --------------------------------------
    function test_forced_eth_donation_does_not_move_price() public {
        uint256 pBefore = m.midPriceEthPerAudE18();
        vm.deal(address(m), address(m).balance + 500 ether); // force actual balance up
        assertEq(m.midPriceEthPerAudE18(), pBefore, "internal-reserve pricing ignores donated ETH");
    }

    // ---- NO DOOR: a bare ETH send has nowhere to go ---------------------------------------------
    function test_bare_eth_send_reverts() public {
        vm.deal(USER, 1 ether);
        vm.prank(USER);
        (bool ok, ) = address(m).call{value: 1 ether}("");
        assertFalse(ok, "no receive()/fallback - bare ETH must revert, not vanish into the pool");
    }
}

/// M-9. Zero fuzz and zero invariants existed anywhere in cell/test (grep: no `invariant_`,
/// `testFuzz`, `StdInvariant`, `targetContract`) before this file. Every existing property above is
/// ONE hand-picked round trip (`test_round_trip_loses_the_spread`, `test_fees_grow_depth_k`), and one
/// round trip cannot establish monotonicity across arbitrary sequences of trades. This handler drives
/// forge's stateful fuzzer through bounded, arbitrary-length sequences of buys and sells against a
/// live membrane, and `AuditEthMembraneInvariantTest` below checks the two properties the doctrine
/// rests on after every sequence: k NON-DECREASING, and NEITHER RESERVE ever reaching zero.
///
/// @dev Every call is wrapped in `try/catch` and swallows reverts on purpose: the fuzzer will
///      generate plenty of inputs that legitimately revert (ZeroInput, Slippage never triggers here
///      since minOut is always 0, WouldDrainReserve on a large `sell` against a small pool). A
///      reverted call changes no state, so it cannot violate either invariant -- what the harness
///      needs is COVERAGE of the successful-call state space, not a crash on the first revert.
contract MembraneHandler is Test {
    AuditEthMembrane public m;
    MockAudit public aud;

    constructor(AuditEthMembrane _m, MockAudit _aud) {
        m = _m;
        aud = _aud;
    }

    function buy(uint256 ethInSeed) external {
        uint256 ethIn = bound(ethInSeed, 1, 500 ether);
        vm.deal(address(this), ethIn);
        try m.buy{value: ethIn}(0) {} catch {}
    }

    function sell(uint256 audInSeed) external {
        // Mint fresh AUDIT into the handler as needed -- the property under test is the POOL's
        // reserves and depth, not whether the handler itself ever runs out of tokens to trade with.
        uint256 have = aud.balanceOf(address(this));
        if (have < 1_000_000 ether) {
            aud.mint(address(this), 1_000_000 ether);
            have = aud.balanceOf(address(this));
        }
        uint256 audIn = bound(audInSeed, 1, have);
        aud.approve(address(m), audIn);
        try m.sell(audIn, 0) {} catch {}
    }
}

/// M-9. StdInvariant + targetContract(handler) is the standard Foundry shape: forge drives many
/// independent RUNS, each a sequence of `depth` randomly-chosen calls into the handler, and checks
/// every `invariant_*` function after each run. `k` non-decreasing is checked against `kOpen`, the
/// depth measured once at genesis in `setUp` -- so this is really "k never falls below its OPENING
/// value across any sequence reachable from genesis", which is the property the doctrine (the pool
/// self-thickens and never un-thickens) actually depends on.
contract AuditEthMembraneInvariantTest is StdInvariant, Test {
    MockAudit aud;
    AuditEthMembrane m;
    MembraneHandler handler;
    uint256 kOpen;

    uint16 constant FEE = 30;
    uint256 constant AUD_SEED = 1_000_000 ether;
    uint256 constant ETH_SEED = 1_000 ether;

    function setUp() public {
        vm.deal(address(this), 100_000 ether);
        aud = new MockAudit();
        aud.mint(address(this), AUD_SEED);
        uint256 nonce = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), nonce);
        aud.approve(predicted, AUD_SEED);
        m = new AuditEthMembrane{value: ETH_SEED}(address(aud), FEE, AUD_SEED);
        require(address(m) == predicted, "address prediction");

        kOpen = m.depth();

        handler = new MembraneHandler(m, aud);
        aud.mint(address(handler), 1_000_000 ether);
        vm.deal(address(handler), 1_000_000 ether);

        targetContract(address(handler));
    }

    function invariant_k_never_falls_below_opening() public view {
        assertGe(m.depth(), kOpen, "k must never fall below its opening value across any sequence of buys/sells");
    }

    function invariant_reserves_never_reach_zero() public view {
        (uint256 a, uint256 e) = m.getReserves();
        assertGt(a, 0, "AUD reserve must never reach zero across any sequence of buys/sells");
        assertGt(e, 0, "ETH reserve must never reach zero across any sequence of buys/sells");
    }
}

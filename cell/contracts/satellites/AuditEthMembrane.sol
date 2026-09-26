// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @notice Minimal ERC-20 surface the membrane needs. AUDIT (CellToken) is standard (returns bool).
interface IAuditToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @title AuditEthMembrane - a doorless AUDIT<->ETH currency window (FC-17 / body/proposals/lp-membrane-proposal.txt)
///
/// The LP named honestly: not the entry point (entry is the mechanism), but the MEMBRANE between DAN's
/// internal AUDIT economy and the outside ETH one. Two design commitments, both mechanical:
///
///   1. NO KEYHOLDER. There is no owner, no admin, no pause, no withdraw, no setter - grep this file: the
///      ONLY state-changing functions are `buy` and `sell`, and neither is privileged. ETH leaves only
///      through a `sell` at the formula price; AUDIT leaves only through a `buy`. A currency window with a
///      key is a vault with a teller (FC-17). This has no teller.
///
///   2. NO ORACLE SURFACE. The settlement cell does NOT read this contract, by design. The mint cap reads
///      `escrow.lpBalance()`, a pure accounting number that is manipulation-immune BECAUSE it is not a
///      market price. Feeding a tradeable pool into issuance would graduate a hardened proxy to a
///      gameable metric and reopen the flash-loan attack. This satellite is deliberately decoupled: no
///      cell contract imports it and it imports nothing from the cell - a topology fact verified by call
///      path (grep), not asserted by a unit test.
///
/// PRICING: constant product (x*y=k) with a symmetric fee. The fee is the SPREAD - a buy pays slightly
/// more and a sell receives slightly less than the mid, so a round trip loses ~2*fee. Retained fees grow
/// k, so the pool SELF-THICKENS: slippage falls and the exit stabilises the longer the system runs, with
/// nobody steering. x*y=k is chosen because it is the only shape needing neither a peg (Curve), a range
/// manager (Uniswap v3), nor an external feed (oracle AMMs) - its slippage IS its manipulation resistance.
///
/// UN-DRAINABILITY: the ARITHMETIC does this, not the guards. `audOut = A*e/(E+e)` is strictly less than
/// `A` whenever `E >= 1`, exactly and before flooring, because `audOut >= A` would require `0 >= A*E`;
/// `sell` is symmetric. Both reserves therefore stay `>= 1` forever by induction from a constructor that
/// requires both seeds non-zero, and a finite input can never take the whole of either side.
/// The two `WouldDrainReserve` checks below are consequently UNREACHABLE - kept as belt-and-braces
/// against a future edit that breaks the invariant, not because anything today depends on them, and no
/// test asserts that error. (M-8, fixed 2026-08-22. The sentence here used to credit "the strict
/// `< reserve` guards plus floored division"; the conclusion was true and the attribution was not, which
/// is a claim overstating its evidence - the PC-25 family living in a comment. Established 2026-08-09 by
/// two independent readings, one brute-forcing 2.1M exhaustive plus 800k random cases with zero guard
/// hits, and re-derived by call path 2026-08-22.)
///
/// NOT AN LP POOL: there are no LP tokens and no `addLiquidity`. The reserves are a fixed, system-owned
/// float set once at construction. Removing LP shares removes the entire share-inflation / first-depositor
/// attack class - there is simply no share accounting to attack.
///
/// SCOPE: this is the standalone window, and the feed question is now CLOSED - DEC-38 (operator, 2026-08-08)
/// SEVERED it. The membrane is NOT fed by the mint split and is not wired to the cell at all: it is seeded
/// once at genesis with real AUDIT + ETH and thereafter touched by no one, self-thickening on its own spread.
/// `withdrawForLP` was REMOVED from CellEscrow on 2026-08-09 applying that decision, so the alternative this
/// comment used to weigh no longer exists, and C-3/G-27 is dissolved rather than answered. `lpBalance` stays
/// exactly where it was, renamed in doctrine to what it always was - a mint throttle, untradeable accounting,
/// which is precisely why the mint cap can keep reading it without acquiring an oracle surface.
contract AuditEthMembrane {
    IAuditToken public immutable audit;
    uint16 public immutable feeBps; // symmetric per-side fee = the spread. Immutable: no dial, no keyholder.

    uint256 public audReserve; // AUDIT the pricing uses. Internal accounting, NOT balanceOf (donation-proof).
    uint256 public ethReserve; // ETH the pricing uses.

    uint256 private constant BPS = 10_000;
    uint256 private _entered; // reentrancy latch (1 = idle, 2 = inside)

    event Bought(address indexed buyer, uint256 ethIn, uint256 audOut, uint256 audReserve, uint256 ethReserve);
    event Sold(address indexed seller, uint256 audIn, uint256 ethOut, uint256 audReserve, uint256 ethReserve);

    error ZeroInput();
    error ZeroOutput();
    error Slippage(uint256 got, uint256 min);
    error WouldDrainReserve();
    error EthSendFailed();
    error TokenPullFailed();
    error TokenSendFailed();
    error BadFee();
    error BadSeed();
    error Reentrancy();

    modifier nonReentrant() {
        if (_entered == 2) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    /// @param _audit AUDIT (CellToken) address.
    /// @param _feeBps symmetric spread, in bps. Must be >0 (a zero-spread pool never thickens) and <1000 (10%).
    /// @param _audSeed opening AUDIT reserve; pulled from the deployer, who MUST `approve` this contract first.
    /// @dev msg.value is the opening ETH reserve. The two seeds set the opening price (ethReserve/audReserve).
    ///      No first-depositor race exists: the deployer is the sole, one-time liquidity source and no shares
    ///      are minted.
    constructor(address _audit, uint16 _feeBps, uint256 _audSeed) payable {
        if (_audit == address(0)) revert BadSeed();
        if (_feeBps == 0 || _feeBps >= 1000) revert BadFee();
        if (_audSeed == 0 || msg.value == 0) revert BadSeed();
        audit = IAuditToken(_audit);
        feeBps = _feeBps;
        if (!IAuditToken(_audit).transferFrom(msg.sender, address(this), _audSeed)) revert TokenPullFailed();
        audReserve = _audSeed;
        ethReserve = msg.value;
        _entered = 1;
    }

    /// @notice Buy AUDIT with ETH. Send ETH as msg.value; receive AUDIT at the constant-product price.
    /// @param minAudOut revert if the output would be below this (caller's own sandwich protection).
    function buy(uint256 minAudOut) external payable nonReentrant returns (uint256 audOut) {
        uint256 ethIn = msg.value;
        if (ethIn == 0) revert ZeroInput();
        uint256 ethInAfterFee = (ethIn * (BPS - feeBps)) / BPS; // the spread: buyer pays fee, it stays in pool
        // x*y=k: audOut = audReserve - k/(ethReserve+ethInAfterFee); floored, which favors the pool.
        audOut = (audReserve * ethInAfterFee) / (ethReserve + ethInAfterFee);
        if (audOut == 0) revert ZeroOutput();
        if (audOut < minAudOut) revert Slippage(audOut, minAudOut);
        if (audOut >= audReserve) revert WouldDrainReserve(); // strict: at least one unit always remains
        // effects before interaction; full ethIn is retained (fee grows k), so the pool self-thickens
        ethReserve += ethIn;
        audReserve -= audOut;
        if (!audit.transfer(msg.sender, audOut)) revert TokenSendFailed();
        emit Bought(msg.sender, ethIn, audOut, audReserve, ethReserve);
    }

    /// @notice Sell AUDIT for ETH. Approve `audIn` to this contract first; receive ETH at the formula price.
    /// @param minEthOut revert if the output would be below this (caller's own sandwich protection).
    function sell(uint256 audIn, uint256 minEthOut) external nonReentrant returns (uint256 ethOut) {
        if (audIn == 0) revert ZeroInput();
        // pull first; pricing uses INTERNAL reserves, so a fee-on-transfer or donation cannot skew it
        if (!audit.transferFrom(msg.sender, address(this), audIn)) revert TokenPullFailed();
        uint256 audInAfterFee = (audIn * (BPS - feeBps)) / BPS; // the spread on the sell side
        ethOut = (ethReserve * audInAfterFee) / (audReserve + audInAfterFee); // floored, favors the pool
        if (ethOut == 0) revert ZeroOutput();
        if (ethOut < minEthOut) revert Slippage(ethOut, minEthOut);
        if (ethOut >= ethReserve) revert WouldDrainReserve(); // strict: ETH reserve can never be emptied
        // effects before the ETH interaction
        audReserve += audIn;
        ethReserve -= ethOut;
        (bool ok, ) = msg.sender.call{value: ethOut}("");
        if (!ok) revert EthSendFailed();
        emit Sold(msg.sender, audIn, ethOut, audReserve, ethReserve);
    }

    // ---- read-only: the published health numbers. No writes, no risk. ---------------------------
    function getReserves() external view returns (uint256 aud, uint256 eth) { return (audReserve, ethReserve); }
    /// @notice The depth invariant k = audReserve * ethReserve. Rises monotonically as fees accrue.
    function depth() external view returns (uint256) { return audReserve * ethReserve; }
    /// @notice Marginal ETH per AUDIT, scaled 1e18. A quote, never used as an oracle by the cell.
    function midPriceEthPerAudE18() external view returns (uint256) { return (ethReserve * 1e18) / audReserve; }

    // No receive() and no fallback: a bare ETH send with no calldata reverts, so ETH cannot be
    // fat-fingered into the void. `buy` is the only payable path.
}

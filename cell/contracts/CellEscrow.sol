// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

interface ICellTokenMin {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @dev G-24: founder vesting pace reads the A-1-anchored distinct-pair signal from the issuance module —
///      NOT the raw `totalSuccessfulAudits` count, which a wash ring can pump at dust cost.
interface IIssuanceDistinct {
    function totalDistinctAuditPairs() external view returns (uint256);
}

/// @dev G-01: mutual bind with AuditCell.treasuryEscrow().
interface IAuditCellTreasuryBinding {
    function treasuryEscrow() external view returns (address);
}

/*
 * CellEscrow — treasury escrow organ for AuditCell (Genesis public surface).
 * Treasury share: 75.1% LP bucket + 24.9% escrow (general + integrity ring-fence).
 * F-42: LP credit capped at 15% of trailing supply; aged general escrow migrates to LP after TIMELOCK.
 */
contract CellEscrow {
    struct PendingDeposit {
        uint256 amount;
        uint256 timestamp;
    }

    ICellTokenMin public token;
    address public admin;
    address public network;
    address public issuanceModule;
    address public structuralUpgradeModule;
    address public integrityReviewModule;
    // lpManager REMOVED 2026-08-09 with DEC-38's `withdrawForLP` — its only reader was that function's
    // `msg.sender == lpManager` check. Slot, constructor default, setter and getter all gone together.
    address public founder;

    uint256 public escrowBalance;
    // escrowMigrated REMOVED 2026-08-09 with migrate() — it was written only by that function.
    uint256 public integrityEscrowBalance;
    uint256 public lpBalance;
    uint256 public integrityEscrowShareBps = 800;

    PendingDeposit[] public pendingDeposits;
    uint256 public pendingDepositsHead;

    /// @dev Discoverer debt ledger (2026-08-09, discoverer-debt-ledger-proposal). What the network OWES
    ///      claimants whose adjudicated payout exceeded the pot at pay time. DELIBERATELY OUTSIDE
    ///      `accountedLiability()`: a debt is a promise against FUTURE deposits, not a claim on tokens
    ///      held — adding it to the backed-liability ledger would fail G-26 at the moment of recording,
    ///      by the invariant's own design. Settlement pays from `escrowBalance` (backed) through
    ///      `_payFromBucket` like every other debit, so `_assertSolvent` semantics are untouched.
    ///      `totalDiscovererDebt` is the public measure of how far promises exceed holdings.
    mapping(address => uint256) public discovererDebt;
    uint256 public totalDiscovererDebt;

    uint256 public constant LP_BPS = 7510;
    uint256 public constant ESCROW_BPS = 2490;
    // TIMELOCK is INERT since migrate() was removed (2026-08-09): its only reader was that function, and the
    // `timestamp` still written into each PendingDeposit now has no reader at all. Both go when the queue is
    // removed (queue-removal-proposal). Kept, not deleted, so the queue-era machinery stays coherent for that
    // single follow-on change rather than being half-dismantled here.
    uint256 public constant TIMELOCK = 180 days;
    uint256 public constant LP_CAP_BPS = 1500;
    uint256 public constant FOUNDER_CAP_ABS = 15_000_000 ether;

    uint256 public founderBalance;
    uint256 public founderClaimed;
    uint256 public founderTotalMinted;
    uint256 public founderReleaseTarget = 1000;

    event Deposited(uint256 totalAmount, uint256 toLP, uint256 toGeneralEscrow, uint256 toIntegrityEscrow);
    event FounderDeposit(uint256 amount, uint256 founderTotalMintedAfter);
    event FounderClaimed(address indexed founder, uint256 amount);
    // MigratedToLP removed with migrate() (2026-08-09). Sole emitter was that function.
    // LPWithdrawn removed with withdrawForLP (DEC-38, 2026-08-08). Sole emitter was that function.
    event Slashed(uint256 amount);
    event IntegrityReviewSubsidy(uint256 amount, uint256 integrityEscrowBalanceAfter);
    event IntegrityReturnRecorded(uint256 amount, uint256 integrityEscrowBalanceAfter);
    event DiscovererPaid(address indexed recipient, uint256 amount);
    event DiscovererDebtRecorded(address indexed claimant, uint256 amount, uint256 totalDebtAfter);
    event DiscovererDebtSettled(address indexed claimant, uint256 paid, uint256 remainingDebt);
    event FloorSupplementPaid(address indexed recipient, uint256 amount, uint256 escrowBalanceAfter);
    event StructuralUpgradeEscrowPaid(address indexed recipient, uint256 amount, uint256 escrowBalanceAfter);
    event IssuanceModuleUpdated(address indexed issuanceModule);
    event StructuralUpgradeModuleUpdated(address indexed structuralUpgradeModule);
    event NetworkUpdated(address indexed network);
    // LPManagerUpdated removed with setLPManager (DEC-38 follow-through, 2026-08-09).
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    constructor(address _token) {
        require(_token != address(0), "Zero token");
        token = ICellTokenMin(_token);
        admin = msg.sender;
    }

    function setNetwork(address n) external onlyAdmin {
        require(network == address(0), "Network already set");
        require(n != address(0), "Zero network");
        address bound = IAuditCellTreasuryBinding(n).treasuryEscrow();
        require(bound == address(0) || bound == address(this), "Network bound elsewhere");
        network = n;
        emit NetworkUpdated(n);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Zero admin");
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    // setLPManager REMOVED 2026-08-09. It configured `lpManager`, whose only reader was the deleted
    // `withdrawForLP`. Left in place it would have been a public, admin-callable, successfully-executing
    // setter that changes nothing an admin could observe — a name making an interface claim nothing
    // honours (lessons 12). Deleted rather than documented, because a comment does not stop the call.

    /// @dev VD-25 (set-once), ratified by VD-39, admitted to the hull window by VD-52 as its ONE code item.
    ///      This was a bare `onlyAdmin` setter, and `founder` is the address `claimFounder` pays: the admin
    ///      could repoint the payee at any moment. On this guarded cell the admin, the operator and the
    ///      founder are the same person, so the harm was zero - and non-zero the instant value arrives,
    ///      which is why the re-trigger read MANDATORY BEFORE THE FIRST VALUE-BEARING DEPLOY rather than
    ///      being parked (DEC-22 forbids a mainnet-gate deferral).
    ///
    ///      SET-ONCE, NOT REMOVED, and the reason is measured rather than assumed: `DeployCell.s.sol` never
    ///      calls this - it calibrates `founderReleaseTarget` and nothing else - so `founder` is genuinely
    ///      address(0) at deploy and exactly one post-deploy call must remain possible. Deleting the setter
    ///      would strand the slot empty with no way to fill it.
    ///
    ///      A CUSTOM ERROR IN A require-STRING FILE, recorded rather than drifted into. VD-52 names
    ///      `FounderAlreadySet`, and every module here that has errors at all uses that form (AuditCell 99,
    ///      CellLogicLib 52). But note `setIntegrityReviewModule` four functions below: CellEscrow already
    ///      has a set-once, written `require(x == address(0), "...")`. Two idioms for one concept in one
    ///      file is a real cost, flagged in the proposal for the reviewer rather than silently resolved -
    ///      the ruling named the error, so the ruling is what landed. Not a licence to convert the other 30.
    error FounderAlreadySet();

    function setFounder(address f) external onlyAdmin {
        require(f != address(0), "Zero founder");
        if (founder != address(0)) revert FounderAlreadySet();
        founder = f;
    }

    function setFounderReleaseTarget(uint256 v) external onlyAdmin {
        require(v > 0, "Zero target");
        // G-27 (founder scope): once the network is wired, the release target may only be RAISED (vesting can
        // tighten, never loosen — no tx exists that accelerates the founder's own unlock). Free before
        // setNetwork for deploy-time calibration.
        require(network == address(0) || v >= founderReleaseTarget, "Vesting: raise-only");
        founderReleaseTarget = v;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    function setIntegrityReviewModule(address m) external onlyAdmin {
        require(integrityReviewModule == address(0), "Integrity module set");
        require(m != address(0), "Zero module");
        integrityReviewModule = m;
    }

    function setIssuanceModule(address m) external onlyAdmin {
        require(issuanceModule == address(0), "Issuance module set");
        require(m != address(0), "Zero module");
        issuanceModule = m;
        emit IssuanceModuleUpdated(m);
    }

    function setStructuralUpgradeModule(address m) external onlyAdmin {
        require(structuralUpgradeModule == address(0), "Structural module set");
        require(m != address(0), "Zero module");
        structuralUpgradeModule = m;
        emit StructuralUpgradeModuleUpdated(m);
    }

    modifier onlyNetwork() {
        require(msg.sender == network, "Not network");
        _;
    }

    modifier onlyNetworkOrIntegrity() {
        require(msg.sender == network || msg.sender == integrityReviewModule, "Not network");
        _;
    }

    modifier onlyIssuanceModule() {
        require(msg.sender == issuanceModule, "Not issuance module");
        _;
    }

    modifier onlyIssuanceOrNetwork() {
        require(msg.sender == issuanceModule || msg.sender == network, "Not issuer");
        _;
    }

    modifier onlyStructuralUpgradeModule() {
        require(msg.sender == structuralUpgradeModule, "Not structural module");
        _;
    }

    function recordDeposit(uint256 amount) external onlyIssuanceOrNetwork {
        require(amount > 0, "Zero deposit");
        uint256 toLP = (amount * LP_BPS) / 10_000;
        uint256 toEscrow = amount - toLP;

        uint256 lpCap = _lpCap();
        if (lpCap != type(uint256).max) {
            uint256 headroom = lpCap > lpBalance ? lpCap - lpBalance : 0;
            if (toLP > headroom) {
                toEscrow += toLP - headroom;
                toLP = headroom;
            }
        }

        lpBalance += toLP;

        uint256 toIntegrity = (toEscrow * integrityEscrowShareBps) / 10_000;
        uint256 toGeneral = toEscrow - toIntegrity;

        escrowBalance += toGeneral;
        integrityEscrowBalance += toIntegrity;

        if (toGeneral > 0) {
            pendingDeposits.push(PendingDeposit({amount: toGeneral, timestamp: block.timestamp}));
        }

        _assertSolvent();
        emit Deposited(amount, toLP, toGeneral, toIntegrity);
    }

    /// @dev G-26: total the ledgers claim the vault owes (LP + general + integrity + unclaimed founder).
    function accountedLiability() public view returns (uint256) {
        return lpBalance + escrowBalance + integrityEscrowBalance + (founderBalance - founderClaimed);
    }

    /// @dev G-26 solvency invariant: the vault must hold at least what the ledgers say it owes. Called as the
    ///      last step of EVERY credit path (recordDeposit, recordSlash, seedIntegrityBucket,
    ///      recordIntegrityReturn, recordFounderDeposit) so an unreceipted credit reverts at the moment of the
    ///      bad write instead of surfacing as latent insolvency at pay time. Debits transfer real tokens and
    ///      cannot violate it; unsolicited donations only make it slack. Supersedes the old per-amount
    ///      balanceOf checks (which ignored existing liabilities).
    function _assertSolvent() internal view {
        require(token.balanceOf(address(this)) >= accountedLiability(), "Tokens not received");
    }

    // migrate REMOVED 2026-08-09 (migrate-removal-proposal, operator-decided). It was the aged-deposit
    // catch-up: money earmarked for LP that spilled back to general escrow when the cap was full at deposit
    // time got moved to LP later, once supply growth raised the cap. That job existed only because LP money
    // went on to become liquidity — DEC-38 severed that, so the catch-up served nothing while remaining
    // PERMISSIONLESS and able to shrink the payable pot at an attacker-chosen moment (PC-26). Removed: pure
    // subtraction, and PC-26's timing lever dissolves with it (no lever left to time).
    //
    // The `pendingDeposits` queue is LEFT IN PLACE this pass, deliberately. It now exists ONLY for the payout
    // walk (`_payFromBucket`) — `dep.timestamp` had exactly one reader, this function, so the timestamps are
    // now inert. Removing the queue collapses payouts to `min(amount, escrowBalance)` in O(1) and closes the
    // iteration-budget underpayment route, BUT it is storage surgery across all three payout paths,
    // `recordSlash`, `recordDeposit` AND `settleDiscovererDebt` (added 2026-08-09) — a separate proposal
    // (queue-removal), not bundled into a freeze-window evening. Its remaining harm is no longer silent:
    // an iteration-budget shortfall now flows through the debt ledger like any other (loud + owed).

    // withdrawForLP REMOVED — DEC-38 (operator, 2026-08-08): "the door is not capped (C-3's answer), not
    // narrowed — removed." C-3/G-27 is dissolved by this deletion: there is nothing left to cap. The exit
    // from the internal economy is the membrane (`satellites/AuditEthMembrane.sol`, FC-17), seeded once at
    // genesis and touched by no one.
    //
    // CONSEQUENCE, stated here because it is not obvious from the diff: this was the ONLY decrement of
    // `lpBalance` (the other two sites, :184 `+= toLP` and :240 `+= canMove`, both add). `lpBalance` is
    // therefore monotonically non-decreasing for the life of this cell — the "permanently inert locked
    // reserve" DEC-38 clause (b) describes, and the mint throttle it always actually was.
    //
    // KNOCK-ON for whoever reads IssuanceModule next: the G-22 latch at `IssuanceModule.sol`:466
    // (`effLp = lp == 0 ? lpFirstFunded : lp`) exists to stop a full LP drain from uncapping the mint.
    // With no drain lever, `lp == 0` can now only hold BEFORE first funding — where `lpFirstFunded` is also
    // 0 and the genesis bootstrap branch is taken. The post-latch arm of that ternary is unreachable by
    // construction. It is deliberately LEFT IN PLACE (cheap, conservative, and correct if any future cell
    // reintroduces a decrement) and is NOT removed here — that would be a second cell change and a separate
    // decision. Recorded so it is decided rather than inherited.
    //
    // SECOND KNOCK-ON — DONE, same session (operator decision, 2026-08-09). `lpManager` was left written and
    // never read by the deletion above: its only reader was this function's `msg.sender == lpManager` check.
    // The slot, the constructor default, the `setLPManager` setter, its `LPManagerUpdated` event and the
    // generated getter are ALL removed, and all three selectors are allowlisted in `surface-removals.txt`.
    // Reasoning kept because the reasoning is the reusable part: a public setter that configures a capability
    // which no longer exists is not merely dead weight — the call succeeds, emits, costs gas and changes
    // nothing observable, which is a name making an interface claim nothing honours (lessons 12). Documenting
    // it would not have helped; a comment does not stop the call.

    function recordSlash(uint256 amount) external onlyNetwork {
        if (amount == 0) return;
        escrowBalance += amount;
        pendingDeposits.push(PendingDeposit({amount: amount, timestamp: block.timestamp}));
        _assertSolvent();
        emit Slashed(amount);
    }

    function seedIntegrityBucket(uint256 amount) external onlyAdmin {
        integrityEscrowBalance += amount;
        _assertSolvent();
    }

    function payIntegrityReviewSubsidy(uint256 amount, uint256) external onlyNetworkOrIntegrity returns (uint256 paid) {
        paid = amount > integrityEscrowBalance ? integrityEscrowBalance : amount;
        if (paid > 0) {
            integrityEscrowBalance -= paid;
            require(token.transfer(network, paid), "Integrity pay failed");
            emit IntegrityReviewSubsidy(paid, integrityEscrowBalance);
        }
    }

    function recordIntegrityReturn(uint256 amount) external onlyNetworkOrIntegrity {
        if (amount == 0) return;
        integrityEscrowBalance += amount;
        _assertSolvent();
        emit IntegrityReturnRecorded(amount, integrityEscrowBalance);
    }

    function payFloorSupplement(address recipient, uint256 amount, uint256 maxIterations)
        external
        onlyIssuanceModule
        returns (uint256 paid)
    {
        if (amount == 0 || recipient == address(0)) return 0;
        (paid, escrowBalance, pendingDepositsHead) =
            _payFromBucket(amount, maxIterations, escrowBalance, pendingDeposits, pendingDepositsHead);
        if (paid > 0) {
            require(token.transfer(recipient, paid), "Floor pay failed");
            emit FloorSupplementPaid(recipient, paid, escrowBalance);
        }
    }

    function payStructuralUpgradeEscrow(address recipient, uint256 amount, uint256 maxIterations)
        external
        onlyStructuralUpgradeModule
        returns (uint256 paid)
    {
        if (amount == 0 || recipient == address(0)) return 0;
        (paid, escrowBalance, pendingDepositsHead) =
            _payFromBucket(amount, maxIterations, escrowBalance, pendingDeposits, pendingDepositsHead);
        if (paid > 0) {
            require(token.transfer(recipient, paid), "Structural pay failed");
            emit StructuralUpgradeEscrowPaid(recipient, paid, escrowBalance);
        }
    }

    function payDiscoverer(address recipient, uint256 amount, uint256 maxIterations)
        external
        onlyNetwork
        returns (uint256 paid)
    {
        if (amount == 0 || recipient == address(0)) return 0;
        (paid, escrowBalance, pendingDepositsHead) =
            _payFromBucket(amount, maxIterations, escrowBalance, pendingDeposits, pendingDepositsHead);
        if (paid > 0) {
            require(token.transfer(recipient, paid), "Pay failed");
            emit DiscovererPaid(recipient, paid);
        }
    }

    /// @notice Record what a shortfalled discoverer is OWED. Called (as `network`) from AuditCell's
    ///         delegatecalled DiscovererPayoutLib when the adjudicated target exceeded what the pot
    ///         could pay. Amount is bounded upstream by the M-2/G-18 target (≤ 1x bounty), and the
    ///         only route here runs through full claim adjudication — this changes WHEN qualified
    ///         claimants are paid, never WHO qualifies or HOW MUCH.
    function recordDiscovererDebt(address claimant, uint256 amount) external onlyNetwork {
        if (amount == 0 || claimant == address(0)) return;
        discovererDebt[claimant] += amount;
        totalDiscovererDebt += amount;
        emit DiscovererDebtRecorded(claimant, amount, totalDiscovererDebt);
    }

    /// @notice Pay down a claimant's recorded debt from the (refilled) pot. PERMISSIONLESS pull —
    ///         anyone may trigger a creditor's payment, normally the creditor. Pays what the pot
    ///         holds, keeps the remainder owed. First-come under scarcity, accepted for v1
    ///         (discoverer-debt-ledger-proposal §what-it-does-not-catch (b)).
    function settleDiscovererDebt(address claimant, uint256 maxIterations) external returns (uint256 paid) {
        uint256 debt = discovererDebt[claimant];
        if (debt == 0) return 0;
        (paid, escrowBalance, pendingDepositsHead) =
            _payFromBucket(debt, maxIterations, escrowBalance, pendingDeposits, pendingDepositsHead);
        if (paid > 0) {
            discovererDebt[claimant] = debt - paid;
            totalDiscovererDebt -= paid;
            require(token.transfer(claimant, paid), "Debt pay failed");
            emit DiscovererDebtSettled(claimant, paid, debt - paid);
        }
    }

    function pendingDepositCount() external view returns (uint256) {
        return pendingDeposits.length - pendingDepositsHead;
    }

    function lpCapView() external view returns (uint256) {
        return _lpCap();
    }

    function founderCapRemaining() public view returns (uint256) {
        if (founderTotalMinted >= FOUNDER_CAP_ABS) return 0;
        return FOUNDER_CAP_ABS - founderTotalMinted;
    }

    function recordFounderDeposit(uint256 amount) external onlyIssuanceOrNetwork {
        if (amount == 0) return;
        uint256 remaining = founderCapRemaining();
        uint256 toRecord = amount > remaining ? remaining : amount;
        if (toRecord == 0) return;
        founderBalance += toRecord;
        founderTotalMinted += toRecord;
        _assertSolvent();
        emit FounderDeposit(toRecord, founderTotalMinted);
    }

    function founderClaimable() public view returns (uint256) {
        if (issuanceModule == address(0) || founderBalance == 0) return 0;
        // G-24: release fraction follows distinct (auditor, protocol) pairs — de-washed, capital-anchored.
        // founderReleaseTarget is denominated in PAIRS (recalibrated at the fresh deploy).
        uint256 pairs;
        try IIssuanceDistinct(issuanceModule).totalDistinctAuditPairs() returns (uint256 p) {
            pairs = p;
        } catch {
            return 0;
        }
        uint256 fractionBps = pairs >= founderReleaseTarget
            ? 10_000
            : (pairs * 10_000) / founderReleaseTarget;
        uint256 totalReleasable = (founderBalance * fractionBps) / 10_000;
        if (totalReleasable <= founderClaimed) return 0;
        return totalReleasable - founderClaimed;
    }

    function claimFounder() external returns (uint256 amount) {
        require(msg.sender == founder, "Not founder");
        amount = founderClaimable();
        require(amount > 0, "Nothing claimable");
        founderClaimed += amount;
        require(token.transfer(founder, amount), "Transfer failed");
        emit FounderClaimed(founder, amount);
    }

    function _lpCap() internal view returns (uint256) {
        uint256 supply = token.totalSupply();
        if (supply == 0) return type(uint256).max;
        return (supply * LP_CAP_BPS) / 10_000;
    }

    function _payFromBucket(
        uint256 amount,
        uint256 maxIterations,
        uint256 bucketBalance,
        PendingDeposit[] storage queue,
        uint256 queueHead
    ) internal returns (uint256 paid, uint256 newBalance, uint256 newHead) {
        newHead = queueHead;
        if (amount == 0) return (0, bucketBalance, newHead);

        uint256 toPay = amount > bucketBalance ? bucketBalance : amount;
        if (toPay == 0) return (0, bucketBalance, newHead);

        uint256 remaining = toPay;
        uint256 iterations = 0;
        while (remaining > 0 && newHead < queue.length) {
            if (maxIterations != 0 && iterations >= maxIterations) break;
            iterations++;

            PendingDeposit storage dep = queue[newHead];
            if (dep.amount == 0) {
                newHead++;
                continue;
            }
            if (dep.amount <= remaining) {
                remaining -= dep.amount;
                dep.amount = 0;
                newHead++;
            } else {
                dep.amount -= remaining;
                remaining = 0;
            }
        }

        paid = toPay - remaining;
        if (paid == 0) return (0, bucketBalance, newHead);
        newBalance = bucketBalance - paid;
    }
}

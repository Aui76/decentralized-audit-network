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
    address public lpManager;
    address public founder;

    uint256 public escrowBalance;
    uint256 public escrowMigrated;
    uint256 public integrityEscrowBalance;
    uint256 public lpBalance;
    uint256 public integrityEscrowShareBps = 800;

    PendingDeposit[] public pendingDeposits;
    uint256 public pendingDepositsHead;

    uint256 public constant LP_BPS = 7510;
    uint256 public constant ESCROW_BPS = 2490;
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
    event MigratedToLP(uint256 amount);
    event LPWithdrawn(address indexed to, uint256 amount);
    event Slashed(uint256 amount);
    event IntegrityReviewSubsidy(uint256 amount, uint256 integrityEscrowBalanceAfter);
    event IntegrityReturnRecorded(uint256 amount, uint256 integrityEscrowBalanceAfter);
    event DiscovererPaid(address indexed recipient, uint256 amount);
    event FloorSupplementPaid(address indexed recipient, uint256 amount, uint256 escrowBalanceAfter);
    event StructuralUpgradeEscrowPaid(address indexed recipient, uint256 amount, uint256 escrowBalanceAfter);
    event IssuanceModuleUpdated(address indexed issuanceModule);
    event StructuralUpgradeModuleUpdated(address indexed structuralUpgradeModule);
    event NetworkUpdated(address indexed network);
    event LPManagerUpdated(address indexed manager);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    constructor(address _token) {
        require(_token != address(0), "Zero token");
        token = ICellTokenMin(_token);
        admin = msg.sender;
        lpManager = msg.sender;
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

    function setLPManager(address manager) external onlyAdmin {
        require(manager != address(0), "Zero manager");
        lpManager = manager;
        emit LPManagerUpdated(manager);
    }

    function setFounder(address f) external onlyAdmin {
        require(f != address(0), "Zero founder");
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

    function migrate(uint256 maxIterations) external returns (uint256 totalMigrated) {
        uint256 lpCap = _lpCap();

        for (uint256 i = 0; i < maxIterations; i++) {
            if (pendingDepositsHead >= pendingDeposits.length) break;

            PendingDeposit memory dep = pendingDeposits[pendingDepositsHead];

            if (dep.amount == 0) {
                pendingDepositsHead++;
                continue;
            }

            if (block.timestamp < dep.timestamp + TIMELOCK) break;
            if (lpBalance >= lpCap) break;

            uint256 canMove = dep.amount;
            if (lpBalance + canMove > lpCap) {
                canMove = lpCap - lpBalance;
                pendingDeposits[pendingDepositsHead].amount = dep.amount - canMove;
            } else {
                pendingDepositsHead++;
            }

            escrowBalance -= canMove;
            lpBalance += canMove;
            escrowMigrated += canMove;
            totalMigrated += canMove;

            emit MigratedToLP(canMove);
        }
    }

    function withdrawForLP(uint256 amount) external {
        require(msg.sender == lpManager, "Not LP manager");
        require(amount <= lpBalance, "Insufficient LP balance");
        lpBalance -= amount;
        require(token.transfer(lpManager, amount), "LP withdraw failed");
        emit LPWithdrawn(lpManager, amount);
    }

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

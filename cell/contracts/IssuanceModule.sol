// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

interface IMintToken {
    function mint(address to, uint256 amount) external;
    function totalSupply() external view returns (uint256);
}

interface ICellAuditorView {
    function auditors(address addr)
        external
        view
        returns (
            uint256 successful,
            uint256 failed,
            uint256 found,
            uint256 position,
            uint256 timeoutStreak,
            bool inQueue
        );
}

interface ICellEscrowFloor {
    function payFloorSupplement(address recipient, uint256 amount, uint256 maxIterations)
        external
        returns (uint256);
    function escrowBalance() external view returns (uint256);
    function lpBalance() external view returns (uint256);
    function recordDeposit(uint256 amount) external;
    function founderCapRemaining() external view returns (uint256);
    function recordFounderDeposit(uint256 amount) external;
}

/// @title IssuanceModule — replaceable monetary policy (cell-v2 pillar A.1).
/// @notice Holds the token minter role. The cell calls settlePositiveBlock after bounty payout;
///         this module mints auditor reward + treasury share, updates adaptive EMA state, and
///         pays depression-floor supplements via CellEscrow. The cell keeps the positive-block
///         provenance chain (blockHeight, events, getters).
contract IssuanceModule {
    address public admin;
    address public cell;
    address public structuralModule;
    IMintToken public token;
    address public treasuryEscrow;
    bool public wiringLocked;

    uint256 public emaToMintBps = 2500;
    uint256 public mintLpCapBps = 500;
    uint256 public treasuryShareBps = 10_000;
    uint256 public founderShareBps = 305;

    uint256 public constant PAY_FLOOR_MAX_ITERATIONS = 512;

    uint256 public emaFast;
    uint256 public emaSlow;
    uint256 public lastEmaFast;
    uint256 public emaWeightFastBps = 2000;
    uint256 public emaWeightSlowBps = 500;
    uint256 public depressionThresholdBps = 7000;
    uint256 public floorFractionBps = 4500;
    uint256 public maxEscrowDrawdownPerAudit = 30;
    uint256 public escrowMinimumThresholdBps = 36000;
    uint256 public manipulationThresholdBps = 13000;
    uint256 public manipulationMintScaleBps = 8000;
    // G-23 (M-5, 2026-07-08): the damper is a continuous TAPER, not a cliff. Full weight at parity;
    // linear to manipulationMintScaleBps at the threshold; keeps falling at the same slope past it,
    // floored here. Straddling just under the old 1.3x cliff now gains ~nothing.
    uint256 public manipulationMintFloorBps = 5000;
    uint256 public emaSlowUnprovenWeightBps = 2500;
    uint256 public emaSlowMinSuccessfulForFullWeight = 5;
    // A-1 (G-17) self-audit mint gate: payout weight for unproven auditors + per-block cap on the auditor mint
    // as a fraction of THIS audit's own bounty. See body/proposals/a1-mint-weight-and-bounty-cap-proposal.txt.
    uint256 public mintUnprovenWeightBps = 2500; // < credibilityCountThreshold distinct protocols → this weight
    uint256 public mintBountyCapBps = 2500;      // auditor mint ≤ this % of the block's own bounty; 0 = off
    // G-22 first-funding latch (2026-07-08): first nonzero lpBalance ever observed at settle. Once set, the
    // LP mint cap NEVER disables — lp==0 computes the cap against this snapshot instead of going uncapped
    // (and instead of 0: escrow deposits derive from the mint, so a zero-mint rule would brick issuance).
    // Set-once, no setter — nothing for a trusted role to retune (G-27 surface not widened).
    uint256 public lpFirstFunded;
    uint256 public maxFailedRecoveryAttempts = 25;
    uint256 public failedRecoveryAttempts;
    uint256 public recoverabilityFactorBps = 4500;
    bool public greenLightMintEnabled = true;
    uint256 public greenLightMintBps = 5000;
    // G-20 cumulative bound (2026-07-08, DEC-22 docket): lifetime green-light mint may never exceed
    // greenLightCumulativeCapBps of totalSupply (read at mint time — self-scaling, no epoch machinery).
    // Per-confirm the mint was already bounded (50% x supplement, 30 bps escrow drawdown, 4 gates, §2.6
    // wash-proof EMAs); this closes the one remaining unbounded-CUMULATIVE mint lever in the system.
    uint256 public greenLightMintedCumulative;
    uint256 public greenLightCumulativeCapBps = 200; // 2% of supply, lifetime; admin-tunable like its siblings

    mapping(address => uint256) public protocolSubmissionCount;
    mapping(address => uint256) public protocolCumulativeBounty;
    uint256 public networkCumulativeBounty;
    uint256 public networkAuditCount;
    uint256 public kProtocol = 10;

    mapping(address => mapping(address => bool)) public protocolAuditorSeen;
    mapping(address => uint256) public protocolDistinctAuditors;
    mapping(address => mapping(address => bool)) public auditorProtocolSeen;
    mapping(address => uint256) public auditorDistinctProtocols;
    uint256 public credibilityCountThreshold = 3;
    /// @dev G-24: network-wide count of first-seen (auditor, protocol) pairs — the de-washed activity signal.
    ///      A ring of k auditors x m protocols can increment this at most k*m times EVER, each requiring a
    ///      settled audit with capital at risk under the A-1 gates. Read by CellEscrow.founderClaimable so
    ///      founder vesting pace follows distinct real relationships, not the farmable raw audit count.
    uint256 public totalDistinctAuditPairs;

    enum IssuanceNetworkState {
        Stable,
        Manipulation,
        Depression,
        Recovery
    }

    event DepressionFloorPaid(address indexed auditor, uint256 supplement, uint256 depressionIntensityBps);
    event GreenLightMintPaid(address indexed auditor, uint256 minted, uint256 shortfall);
    event FailedRecoveryAttemptRecorded(uint256 attempts);
    event ParameterUpdated(string indexed name, uint256 value);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    // G-27 §B (2026-07-08, DEC-22 docket): one-way per-parameter lock for the anti-Sybil hardening knobs.
    // CAPABILITY ships in bytecode (un-addable post-freeze — the reserve rationale); it is UNARMED at this
    // deployment BY DESIGN — this cell is a calibration testnet, so the knobs stay mutable to gather tuning
    // data. Arming is a per-deployment operational call (like the founder lock, runbook §2b); a future final
    // deploy arms it to make today's hardening un-reversible. Bitmask; lock is set-once per id.
    uint256 public issuanceParamLockMask;
    uint8 public constant LOCK_CREDIBILITY = 0;      // setCredibilityCountThreshold (§2.5 gate: G-17/19/24)
    uint8 public constant LOCK_A1_GATE = 1;          // setA1MintGate (mint weight + bounty cap: G-17)
    uint8 public constant LOCK_GREENLIGHT_CAP = 2;   // setGreenLightCumulativeCapBps (G-20)
    uint8 public constant LOCK_MANIP_TAPER = 3;      // setAdaptiveIssuanceParams + setManipulationMintFloorBps (G-23)
    uint8 public constant LOCK_LP_CAP = 4;           // setMintLpCapBps (G-22 governor)

    function issuanceParamLocked(uint8 id) public view returns (bool) {
        return (issuanceParamLockMask & (uint256(1) << id)) != 0;
    }

    /// @notice G-27 §B: lock an anti-Sybil param one-way (irreversible). UNARMED at this deploy by design.
    function lockIssuanceParam(uint8 id) external onlyAdmin {
        require(id <= LOCK_LP_CAP, "Bad param id");
        issuanceParamLockMask |= (uint256(1) << id);
        emit ParameterUpdated("issuanceParamLock", id);
    }

    function _requireUnlocked(uint8 id) internal view {
        require(!issuanceParamLocked(id), "Issuance param locked");
    }

    modifier onlyCell() {
        require(msg.sender == cell, "Not cell");
        _;
    }

    modifier onlyCellOrStructural() {
        require(msg.sender == cell || msg.sender == structuralModule, "Not cell");
        _;
    }

    constructor(address _admin) {
        admin = _admin;
    }

    function wire(address _cell, address _token, address _escrow) external onlyAdmin {
        require(!wiringLocked, "Wiring locked");
        cell = _cell;
        token = IMintToken(_token);
        treasuryEscrow = _escrow;
    }

    function setStructuralModule(address m) external onlyAdmin {
        require(!wiringLocked, "Wiring locked");
        structuralModule = m;
    }

    function lockWiring() external onlyAdmin {
        require(cell != address(0) && address(token) != address(0), "Unset");
        wiringLocked = true;
    }

    function setEmaToMintBps(uint256 v) external onlyAdmin {
        emaToMintBps = v;
        emit ParameterUpdated("emaToMintBps", v);
    }

    function setMintLpCapBps(uint256 v) external onlyAdmin {
        _requireUnlocked(LOCK_LP_CAP);
        mintLpCapBps = v;
        emit ParameterUpdated("mintLpCapBps", v);
    }

    function setTreasuryShareBps(uint256 v) external onlyAdmin {
        treasuryShareBps = v;
    }

    function setFounderShareBps(uint256 v) external onlyAdmin {
        // G-27 (founder scope): once wiring locks, the founder share may only go DOWN. The founder can tighten
        // his own economics, never loosen them; free before lock for deploy-time calibration.
        require(!wiringLocked || v <= founderShareBps, "Founder share: lower-only");
        founderShareBps = v;
        emit ParameterUpdated("founderShareBps", v);
    }

    function setCredibilityCountThreshold(uint256 v) external onlyAdmin {
        _requireUnlocked(LOCK_CREDIBILITY);
        credibilityCountThreshold = v;
        emit ParameterUpdated("credibilityCountThreshold", v);
    }

    /// @dev G-20: lifetime green-light cap knob (bps of totalSupply). Same trust model as its sibling
    ///      green-light params (no IssuanceModule param-lock exists — the freeze-gate §B question).
    function setGreenLightCumulativeCapBps(uint256 v) external onlyAdmin {
        _requireUnlocked(LOCK_GREENLIGHT_CAP);
        greenLightCumulativeCapBps = v;
        emit ParameterUpdated("greenLightCumulativeCapBps", v);
    }

    /// @dev G-23: floor knob for the manipulation taper (bps). Kept OUT of setAdaptiveIssuanceParams so
    ///      that selector stays stable (surface gate: 0 removed).
    function setManipulationMintFloorBps(uint256 v) external onlyAdmin {
        _requireUnlocked(LOCK_MANIP_TAPER);
        require(v <= manipulationMintScaleBps, "Floor above scale");
        manipulationMintFloorBps = v;
        emit ParameterUpdated("manipulationMintFloorBps", v);
    }

    /// @notice G-20: remaining lifetime green-light mint headroom (supply-scaled, saturating).
    function greenLightMintHeadroom() public view returns (uint256) {
        uint256 capTotal = (token.totalSupply() * greenLightCumulativeCapBps) / 10_000;
        return capTotal > greenLightMintedCumulative ? capTotal - greenLightMintedCumulative : 0;
    }

    /// @notice credBounty that the next settle for (auditor, protocol) would use (view; no state change).
    function previewCredBountyForSettle(address auditor, address protocol, uint256 rawBounty)
        external
        view
        returns (uint256)
    {
        return _credBountyForSettle(auditor, protocol, rawBounty);
    }

    function setAdaptiveIssuanceParams(
        uint256 manipThreshBps,
        uint256 manipMintScaleBps,
        uint256 unprovenWeightBps,
        uint256 minSuccessfulFull,
        uint256 maxFailedAttempts,
        bool greenLightEnabled,
        uint256 greenLightBps
    ) external onlyAdmin {
        _requireUnlocked(LOCK_MANIP_TAPER);
        // G-23: threshold must sit strictly above parity — the taper's slope is anchored on (threshold - 10_000).
        require(manipThreshBps > 10_000 && manipThreshBps <= 20_000 && manipMintScaleBps <= 10_000, "Invalid manipulation bps");
        require(unprovenWeightBps <= 10_000 && greenLightBps <= 10_000, "Invalid weight bps");
        manipulationThresholdBps = manipThreshBps;
        manipulationMintScaleBps = manipMintScaleBps;
        emaSlowUnprovenWeightBps = unprovenWeightBps;
        emaSlowMinSuccessfulForFullWeight = minSuccessfulFull;
        maxFailedRecoveryAttempts = maxFailedAttempts;
        greenLightMintEnabled = greenLightEnabled;
        greenLightMintBps = greenLightBps;
        emit ParameterUpdated("manipulationThresholdBps", manipThreshBps);
    }

    // A-1 (G-17): set the self-audit mint gate params (pre-lock; freeze posture bundled with the IssuanceModule
    // param-lock question). unprovenWeightBps ≤ 10000; bountyCapBps ≤ 10000 (0 disables the cap).
    function setA1MintGate(uint256 unprovenWeightBps, uint256 bountyCapBps) external onlyAdmin {
        _requireUnlocked(LOCK_A1_GATE);
        require(unprovenWeightBps <= 10_000 && bountyCapBps <= 10_000, "Invalid A1 gate bps");
        mintUnprovenWeightBps = unprovenWeightBps;
        mintBountyCapBps = bountyCapBps;
        emit ParameterUpdated("mintUnprovenWeightBps", unprovenWeightBps);
        emit ParameterUpdated("mintBountyCapBps", bountyCapBps);
    }

    function nextPositiveBlockReward() public view returns (uint256) {
        return _positiveBlockRewardFromEmaSlow(emaSlow);
    }

    function depressionIntensityBps() external view returns (uint256) {
        if (emaSlow == 0) return 0;
        uint256 ratio = (emaFast * 10_000) / emaSlow;
        return ratio >= 10_000 ? 0 : 10_000 - ratio;
    }

    function floorDecayBps() public view returns (uint256) {
        if (failedRecoveryAttempts >= maxFailedRecoveryAttempts) {
            return 0;
        }
        return 10_000 - (failedRecoveryAttempts * 10_000 / maxFailedRecoveryAttempts);
    }

    function issuanceNetworkState() external view returns (IssuanceNetworkState) {
        if (emaSlow == 0) {
            return IssuanceNetworkState.Stable;
        }
        uint256 fastRatioBps = (emaFast * 10_000) / emaSlow;
        if (fastRatioBps > manipulationThresholdBps) {
            return IssuanceNetworkState.Manipulation;
        }
        if (fastRatioBps < depressionThresholdBps) {
            return IssuanceNetworkState.Depression;
        }
        if (lastEmaFast > 0 && emaFast > lastEmaFast && fastRatioBps < 10_000) {
            return IssuanceNetworkState.Recovery;
        }
        return IssuanceNetworkState.Stable;
    }

    function greenLightMintAllowed() external view returns (bool) {
        if (emaSlow == 0) return false;
        uint256 fastRatioBps = (emaFast * 10_000) / emaSlow;
        if (fastRatioBps >= depressionThresholdBps) return false;
        return _greenLightMintAllowed(lastEmaFast, fastRatioBps);
    }

    function escrowMinimumThreshold() external view returns (uint256) {
        return (emaSlow * escrowMinimumThresholdBps) / 10_000;
    }

    function _mint(address to, uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        token.mint(to, amount);
        return amount;
    }

    function settlePositiveBlock(uint256 id, address auditor, address protocol, uint256 rawBounty)
        external
        onlyCell
        returns (uint256 auditorMinted, uint256 treasuryMinted, uint256 reward)
    {
        id;
        // G-22 latch: record the first nonzero LP funding (from PRIOR settles' treasury splits). At the
        // genesis settle lp is still 0, so the latch stays unset and the bootstrap path is untouched.
        {
            uint256 lpNow = _lpBalance();
            if (lpFirstFunded == 0 && lpNow > 0) lpFirstFunded = lpNow;
        }
        uint256 slowForReward = emaSlow;
        if (emaSlow == 0 && rawBounty > 0) {
            slowForReward = _previewEmaSlowAfterBounty(auditor, protocol, rawBounty);
        }
        reward = _positiveBlockRewardFromEmaSlow(slowForReward);
        // A-1 (G-17) prong 1 — payout weight: an auditor under credibilityCountThreshold distinct protocols
        // mints at mintUnprovenWeightBps; proven auditors at full. The distinct counters update AFTER this
        // (in _updateEmaAndPayFloor → _recordCredibilityCounters), so the settling audit never counts toward
        // its own weight.
        uint256 mintWeight =
            auditorDistinctProtocols[auditor] >= credibilityCountThreshold ? 10_000 : mintUnprovenWeightBps;
        reward = (reward * mintWeight) / 10_000;
        // A-1 prong 2 — per-block bounty cap: the auditor mint is ≤ mintBountyCapBps of THIS audit's own bounty.
        // Converts a free mint into mint proportional to capital cycled at 14-day claim-risk — an anchor on
        // return-on-capital, NOT a deterrent (a capitalized ring's residual is positive-EV; see proposal §4 N1).
        // Treasury + founder shares below derive from this gated `reward`, so a wash can't inflate those buckets.
        if (mintBountyCapBps > 0) {
            uint256 mintCap = (rawBounty * mintBountyCapBps) / 10_000;
            if (reward > mintCap) reward = mintCap;
        }
        if (reward > 0) {
            auditorMinted = _mint(auditor, reward);
            if (treasuryEscrow != address(0) && treasuryShareBps > 0) {
                uint256 treasuryAmount = (reward * treasuryShareBps) / 10_000;
                treasuryMinted = _mint(treasuryEscrow, treasuryAmount);
                if (treasuryMinted > 0) {
                    ICellEscrowFloor(treasuryEscrow).recordDeposit(treasuryMinted);
                }
            }
            if (treasuryEscrow != address(0) && founderShareBps > 0) {
                uint256 founderAmount = (reward * founderShareBps) / 10_000;
                uint256 founderAllowance = ICellEscrowFloor(treasuryEscrow).founderCapRemaining();
                uint256 toMintFounder = founderAmount > founderAllowance ? founderAllowance : founderAmount;
                if (toMintFounder > 0) {
                    uint256 founderMinted = _mint(treasuryEscrow, toMintFounder);
                    if (founderMinted > 0) {
                        ICellEscrowFloor(treasuryEscrow).recordFounderDeposit(founderMinted);
                    }
                }
            }
        }
        _updateEmaAndPayFloor(auditor, protocol, rawBounty);
    }

    function _activityMint(uint256 slowEma) internal view returns (uint256) {
        return (slowEma * emaToMintBps) / 10_000;
    }

    function _lpBalance() internal view returns (uint256) {
        if (treasuryEscrow == address(0)) return 0;
        return ICellEscrowFloor(treasuryEscrow).lpBalance();
    }

    function _positiveBlockRewardFromEmaSlow(uint256 slowEma) internal view returns (uint256) {
        if (slowEma == 0) return 0;
        uint256 activityMint = _activityMint(slowEma);
        uint256 lp = _lpBalance();
        // G-22 fix: after LP is first funded the cap never disables — a full LP drain (lpManager, C-3/G-27
        // overlap) computes the cap against the first-funded snapshot instead of minting uncapped. Pre-latch
        // (genesis bootstrap) behavior is byte-identical to before.
        uint256 effLp = lp == 0 ? lpFirstFunded : lp;
        uint256 reward = effLp == 0 ? activityMint : _min(activityMint, (mintLpCapBps * effLp) / 10_000);
        if (emaFast == 0) {
            return reward;
        }
        uint256 fastRatioBps = (emaFast * 10_000) / slowEma;
        // G-23 (M-5): continuous taper replaces the cliff (the straddle dodge at threshold-epsilon is dead).
        return (reward * manipulationScaleBps(fastRatioBps)) / 10_000;
    }

    /// @notice G-23 (M-5): mint damping as a continuous function of the fast/slow ratio. 10_000 (full) at
    ///         or below parity; linear down to `manipulationMintScaleBps` at `manipulationThresholdBps`;
    ///         same slope past the threshold, floored at `manipulationMintFloorBps`. Strictly ≤ the old
    ///         cliff above the threshold, gently ≤ full weight below it — never MORE permissive.
    function manipulationScaleBps(uint256 fastRatioBps) public view returns (uint256) {
        if (fastRatioBps <= 10_000) return 10_000;
        uint256 span = manipulationThresholdBps > 10_000 ? manipulationThresholdBps - 10_000 : 0;
        if (span == 0) {
            // degenerate config (threshold at/below parity): fall back to the old cliff semantics
            return manipulationMintScaleBps;
        }
        uint256 drop = ((10_000 - manipulationMintScaleBps) * (fastRatioBps - 10_000)) / span;
        uint256 scale = drop >= 10_000 ? 0 : 10_000 - drop;
        return scale < manipulationMintFloorBps ? manipulationMintFloorBps : scale;
    }

    function _previewEmaSlowAfterBounty(address auditor, address protocol, uint256 rawBounty)
        internal
        view
        returns (uint256)
    {
        uint256 credBounty = _credBountyForSettle(auditor, protocol, rawBounty);

        uint256 slowWeight = _auditorEmaSlowWeightBps(auditor);
        uint256 slowSignal = (credBounty * slowWeight) / 10_000;
        if (emaSlow == 0) {
            return slowSignal;
        }
        return (emaSlow * (10_000 - emaWeightSlowBps) + slowSignal * emaWeightSlowBps) / 10_000;
    }

    function _recordCredibilityCounters(address auditor, address protocol) internal {
        if (!auditorProtocolSeen[auditor][protocol]) {
            auditorProtocolSeen[auditor][protocol] = true;
            auditorDistinctProtocols[auditor] += 1;
            totalDistinctAuditPairs += 1; // G-24: vesting-pace signal (see declaration)
        }
        if (!protocolAuditorSeen[protocol][auditor] && auditorDistinctProtocols[auditor] >= credibilityCountThreshold) {
            protocolAuditorSeen[protocol][auditor] = true;
            protocolDistinctAuditors[protocol] += 1;
        }
    }

    /// @dev Simulates post-settle nEff when called from a view (no mutation).
    function _effectiveDistinctAuditors(address protocol, address auditor) internal view returns (uint256) {
        uint256 nEff = protocolDistinctAuditors[protocol];
        if (protocolAuditorSeen[protocol][auditor]) {
            return nEff;
        }
        uint256 auditorDistinct = auditorDistinctProtocols[auditor];
        if (!auditorProtocolSeen[auditor][protocol]) {
            auditorDistinct += 1;
        }
        if (auditorDistinct >= credibilityCountThreshold) {
            return nEff + 1;
        }
        return nEff;
    }

    function _credBountyForSettle(address auditor, address protocol, uint256 rawBounty)
        internal
        view
        returns (uint256 credBounty)
    {
        uint256 n = protocolSubmissionCount[protocol];
        uint256 netMean =
            networkAuditCount > 0 ? networkCumulativeBounty / networkAuditCount : rawBounty;
        uint256 protoMean = n > 0 ? protocolCumulativeBounty[protocol] / n : netMean;
        uint256 nEff = _effectiveDistinctAuditors(protocol, auditor);
        credBounty = (nEff * protoMean + kProtocol * netMean) / (nEff + kProtocol);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _updateEmaAndPayFloor(address auditor, address protocol, uint256 rawBounty) internal {
        uint256 n = protocolSubmissionCount[protocol];
        uint256 netMean =
            networkAuditCount > 0 ? networkCumulativeBounty / networkAuditCount : rawBounty;
        uint256 protoMean = n > 0 ? protocolCumulativeBounty[protocol] / n : netMean;

        _recordCredibilityCounters(auditor, protocol);
        uint256 nEff = protocolDistinctAuditors[protocol];
        uint256 credBounty = (nEff * protoMean + kProtocol * netMean) / (nEff + kProtocol);

        protocolSubmissionCount[protocol] += 1;
        protocolCumulativeBounty[protocol] += rawBounty;
        networkAuditCount += 1;
        networkCumulativeBounty += credBounty;

        uint256 prevFast = emaFast;
        if (emaFast == 0) {
            emaFast = credBounty;
        } else {
            emaFast = (emaFast * (10_000 - emaWeightFastBps) + credBounty * emaWeightFastBps) / 10_000;
        }
        uint256 slowWeight = _auditorEmaSlowWeightBps(auditor);
        uint256 slowSignal = (credBounty * slowWeight) / 10_000;
        if (emaSlow == 0) {
            emaSlow = slowSignal;
        } else {
            emaSlow = (emaSlow * (10_000 - emaWeightSlowBps) + slowSignal * emaWeightSlowBps) / 10_000;
        }
        lastEmaFast = prevFast;

        if (emaSlow == 0 || treasuryEscrow == address(0)) return;

        uint256 fastRatioBps = (emaFast * 10_000) / emaSlow;
        if (fastRatioBps >= depressionThresholdBps) return;

        uint256 intensityBps = 10_000 - fastRatioBps;
        uint256 rawSupplement = (emaSlow * floorFractionBps * intensityBps) / (10_000 * 10_000);
        if (rawSupplement == 0) return;

        uint256 escrowBal = ICellEscrowFloor(treasuryEscrow).escrowBalance();
        uint256 drawdownCap = (escrowBal * maxEscrowDrawdownPerAudit) / 10_000;
        uint256 supplement = rawSupplement < drawdownCap ? rawSupplement : drawdownCap; // INTENDED bonus (unchanged)
        if (supplement == 0) return;

        // M-4 (G-21): the slump bonus may only DRAW the pool's surplus above its protective reserve (the same
        // reserve the green-light branch names, escrowMinimumThresholdBps x emaSlow); it never digs past it. The
        // intended `supplement` is left intact so the green-light mint below still covers any shortfall — that is
        // a MINT, which never touches the pool, so the reserve stays safe. Retiring green-light would be its own
        // line item, not a side effect here. See body/proposals/fix-slump-bonus-cap-proposal.txt.
        uint256 reserve = (emaSlow * escrowMinimumThresholdBps) / 10_000;
        uint256 drawable = escrowBal > reserve ? escrowBal - reserve : 0;
        uint256 poolDraw = supplement < drawable ? supplement : drawable;

        uint256 paid = poolDraw > 0
            ? ICellEscrowFloor(treasuryEscrow).payFloorSupplement(auditor, poolDraw, PAY_FLOOR_MAX_ITERATIONS)
            : 0;
        if (paid > 0) {
            emit DepressionFloorPaid(auditor, paid, intensityBps);
        }

        uint256 fastRatioAfter = (emaFast * 10_000) / emaSlow;
        if (
            fastRatioAfter < depressionThresholdBps && fastRatioAfter >= recoverabilityFactorBps
                && emaFast <= prevFast && floorDecayBps() > 0
        ) {
            failedRecoveryAttempts += 1;
            emit FailedRecoveryAttemptRecorded(failedRecoveryAttempts);
        }

        if (_greenLightMintAllowed(prevFast, fastRatioAfter) && paid < supplement) {
            uint256 threshold = (emaSlow * escrowMinimumThresholdBps) / 10_000;
            if (escrowBal < threshold) {
                uint256 shortfall = supplement - paid;
                uint256 mintCap = (shortfall * greenLightMintBps) / 10_000;
                // G-20: clamp to the lifetime cumulative headroom (supply-scaled). Partial mint at the
                // boundary; 0 once the lifetime cap is spent.
                uint256 headroom = greenLightMintHeadroom();
                if (mintCap > headroom) mintCap = headroom;
                if (mintCap > 0) {
                    uint256 minted = _mint(auditor, mintCap);
                    if (minted > 0) {
                        greenLightMintedCumulative += minted;
                        emit GreenLightMintPaid(auditor, minted, shortfall);
                    }
                }
            }
        }
    }

    function _auditorEmaSlowWeightBps(address auditor) internal view returns (uint256) {
        // A-1 (G-17) prong 3 — key the emaSlow signal weight off DISTINCT-counterparty history, not raw
        // `successful`. Five self-audits satisfied `successful >= 5` and bought full signal weight — the
        // gate's discount was bought back by the exact behavior it discounts. Distinct-protocol count can't be
        // farmed by repetition (a wash stays at 1). `_previewEmaSlowAfterBounty` uses this too, so the genesis
        // preview and the settle path stay in agreement.
        if (auditorDistinctProtocols[auditor] >= credibilityCountThreshold) {
            return 10_000;
        }
        return emaSlowUnprovenWeightBps;
    }

    function _greenLightMintAllowed(uint256 prevFast, uint256 fastRatioBps) internal view returns (bool) {
        if (!greenLightMintEnabled) return false;
        if (floorDecayBps() == 0) return false;
        if (fastRatioBps < recoverabilityFactorBps) return false;
        if (emaFast <= prevFast) return false;
        return true;
    }

    uint256 public upgradeAdoptMintBps = 10_000;

    function setUpgradeAdoptMintBps(uint256 v) external onlyAdmin {
        upgradeAdoptMintBps = v;
    }

    function upgradeAdoptMintAmount() public view returns (uint256) {
        uint256 canFloor = nextPositiveBlockReward();
        return (canFloor * upgradeAdoptMintBps) / 10_000;
    }

    function mintUpgradeAdopt(address to) external onlyCellOrStructural returns (uint256) {
        return _mint(to, upgradeAdoptMintAmount());
    }

    function mintToolCanonization(address to) external onlyCell returns (uint256) {
        return _mint(to, nextPositiveBlockReward());
    }

    /// @dev G-19 (2026-07-08): the §2.5 established-protocol signal, exposed as the canonization
    ///      eligibility gate (read by ToolUseLib). GATE-only reuse of the credibility metric — it pays
    ///      nothing here (punish/pay rule, lessons #10).
    function isEstablishedProtocol(address p) external view returns (bool) {
        return protocolDistinctAuditors[p] >= credibilityCountThreshold;
    }
}

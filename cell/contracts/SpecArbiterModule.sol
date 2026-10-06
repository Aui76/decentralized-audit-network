// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./ISpecArbiterModule.sol";
import "./IClaimSettlementMutator.sol";
import "./AuditCell.sol";
import "./CellStorage.sol";
import "./RunDigests.sol";
import "./AssignmentEntropyLib.sol";

/// @title SpecArbiterModule — Gate A spec challenge + independent arbiter (X1 / F-44).
/// @notice Settlement-touching L1 satellite; pre-mint void via cell hook, not in-cell growth.
contract SpecArbiterModule is ISpecArbiterModule {
    address public admin;
    address public cell;
    bool public wiringLocked;

    uint256 public specChallengeFee;
    uint256 public specChallengeStake = 100 ether;
    uint256 public specChallengeWindow = 2 days;
    uint256 public specChallengeRepeatSlashBps = 5000;
    uint256 public specArbiterDecisionWindow = 7 days;
    uint256 public specArbiterRewardBps = 5000;
    uint256 public specChallengerInvalidationRewardBps = 5000;
    /// VD-117(4) option (3), booked to this window on 2026-09-06 and ridden here. The unruled-expiry
    /// charge is its OWN parameter, expressed as bps of the CHALLENGER's stake, because `specChallengeFee`
    /// had two roles and two payers that VD-107 never separated: on a void it is the PROTOCOL's cancel
    /// price drawn from the bounty (`_payoutAndVoid`), and on an unruled expiry the same number was drawn
    /// from the CHALLENGER's stake. One parameter at one value forfeited the whole stake at the shipped
    /// defaults and inverted the incentive - a challenger disproven by a defend forfeits nothing, while a
    /// challenger nobody adjudicated forfeited everything. The person punished hardest was an honest
    /// challenger who met a no-arbiter failure of the system.
    ///
    /// 1000 bps is exactly the shipped behaviour after VD-117(1): a 10 ether fee against a 100 ether stake.
    /// So this separation changes no number today; it makes the two prices movable independently, which is
    /// what having one parameter for two payers prevented.
    uint256 public specChallengeExpiryChargeBps = 1000;

    uint256 internal constant MAX_SPEC_ARBITER_SCAN = 256; // gas bound; matches AssignmentModule.MAX_SCAN

    mapping(uint256 => SpecChallenge) internal _challenges;
    mapping(uint256 => mapping(address => uint256)) public specDefendedChallengeCount;

    event SpecChallengeOpened(
        uint256 indexed auditId, address indexed challenger, bytes32 indexed specToolId, bytes32 failErrorsRoot
    );
    event SpecChallengeDefended(
        uint256 indexed auditId, address indexed protocol, address indexed challenger, uint256 refundAmount, uint256 slashAmount
    );
    event SpecChallengeFinalized(uint256 indexed auditId, address indexed challenger, bool invalidated);
    event SpecArbiterAssigned(uint256 indexed auditId, address indexed arbiter);
    event SpecArbiterReassigned(uint256 indexed auditId, address indexed oldArbiter, address indexed newArbiter);
    event SpecArbiterUnavailable(uint256 indexed auditId);
    event SpecArbiterSilentExpired(uint256 indexed auditId, address indexed arbiter);
    event SpecArbitramentDeclared(
        uint256 indexed auditId,
        address indexed arbiter,
        bytes32 specErrorsRoot,
        bool passConfirmed,
        uint256 challengerSlash,
        uint256 arbiterReward
    );
    event ParameterUpdated(string indexed name, uint256 value);

    error NotAdmin();
    error WiringLocked();
    error HostUnset();
    error NoAudit();
    error NotChallengeable();
    error NoSpecTool();
    error ChallengeOpen();
    error ErrorsRootMatchesPass();
    error DisputeOpen();
    error NoChallenge();
    error NotSpecArbiter();
    error NoSpecArbiter();
    error ArbiterIneligible();
    error NotProtocol();
    error SpecRunMismatch();
    error SpecArbiterAssignedBlock();
    error ArbiterWindowOpen();
    error ChallengeWindowOpen();
    error ArbiterWindowClosed();
    error ChallengeWindowClosed();
    error ReentrantCall();
    error BadParamId();
    error ParamLocked();
    error InvalidBps();
    error WindowBelowFloor();

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus = _NOT_ENTERED;

    // Phase B1 (admin-door-residue-verdicts, VD-26): doors 4-8 lock+bound pass. Ported from
    // IssuanceModule's issuanceParamLockMask shape (A1: capability now, armed later per parameter —
    // ships UNARMED, mask = 0).
    uint256 public specArbiterParamLockMask;
    uint8 public constant LOCK_CHALLENGE_FEE = 0;                    // door 4: setSpecChallengeFee
    uint8 public constant LOCK_CHALLENGE_STAKE = 1;                  // door 5: setSpecChallengeStake
    uint8 public constant LOCK_REPEAT_SLASH = 2;                     // door 6: setSpecChallengeRepeatSlashBps
    uint8 public constant LOCK_ARBITER_REWARD = 3;                   // door 7: setSpecArbiterRewardBps
    uint8 public constant LOCK_CHALLENGER_INVALIDATION_REWARD = 4;   // door 8: setSpecChallengerInvalidationRewardBps
    // VD-115 re-booked VD-109(1)'s bare setter to "its own item in the NEXT window", which is this one -
    // and reading the file today, its SIBLING is bare in exactly the same way. Both are windows read live
    // at evaluation, so an admin write moves a deadline under a challenge already in flight; that is the
    // retroactivity class VD-96 accepted for the guarded phase.
    //
    // A LOCK ENDS THAT ACCEPTANCE ONLY ONCE IT IS ARMED, and NOTHING ARMS THESE (VD-157). No script in
    // cell/script/ calls lockSpecArbiterParam for any door - not these three, and not the five that
    // shipped before them; the only param lock a deploy arms is cell.lockParam(TOOL_WITNESS_FLAGS) in
    // phase-f/PhaseFSetup.s.sol. So what lands here is the FLOOR, which holds from deploy, plus a door
    // that exists. VD-96's guarded-phase acceptance of these two windows STANDS until doors 9 and 10 are
    // armed, which is a keyed one-shot act on the runbook's G-h page - not a deploy default, and not a
    // blocker on this window. The first writing of this comment said a lock ends the acceptance, full
    // stop; that was true of an armed lock and of no lock in this repo.
    uint8 public constant LOCK_CHALLENGE_WINDOW = 5;                 // door 9: setSpecChallengeWindow
    uint8 public constant LOCK_ARBITER_DECISION_WINDOW = 6;          // door 10: setSpecArbiterDecisionWindow
    uint8 public constant LOCK_EXPIRY_CHARGE = 7;                    // door 11: setSpecChallengeExpiryChargeBps

    // FLOORS ONLY, AND DELIBERATELY NOT CEILINGS. The cell's idiom is a MIN/MAX pair
    // (`CellLogicLib`:1368-1375), but VD-156 rules a FLOOR here and nothing else. A zero window expires a
    // challenge in the block it is filed; that is the harm. A ceiling is a bound nobody ruled, and picking
    // one would forbid a long window some future posture wants - substituting design, which non-negotiable
    // 8 forbids. Named so the asymmetry with the cell's pairs reads as a decision rather than an omission.
    uint256 internal constant MIN_SPEC_CHALLENGE_WINDOW = 1 minutes;
    uint256 internal constant MIN_SPEC_ARBITER_DECISION_WINDOW = 1 minutes;

    function specArbiterParamLocked(uint8 id) public view returns (bool) {
        return (specArbiterParamLockMask & (uint256(1) << id)) != 0;
    }

    /// @notice Lock a spec-arbiter economic param one-way (irreversible). UNARMED at this deploy by design.
    function lockSpecArbiterParam(uint8 id) external onlyAdmin {
        if (id > LOCK_EXPIRY_CHARGE) revert BadParamId();
        specArbiterParamLockMask |= (uint256(1) << id);
        emit ParameterUpdated("specArbiterParamLock", id);
    }

    function _requireUnlocked(uint8 id) internal view {
        if (specArbiterParamLocked(id)) revert ParamLocked();
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) revert ReentrantCall();
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    constructor(address _admin) {
        admin = _admin;
    }

    // ---- DR-6a (mainnet-deploy.md): admin rotatability ------------------------------------------
    // Matches AuditCell.transferAdmin (zero-address reject + AdminTransferred event). Without this
    // the deploy sequence cannot hand the module to the Timelock (Section 3 step 8 / DR-3): the
    // constructor bound admin and nothing could change it. Found 2026-08-01 by rehearsing the
    // sequence on paper -- on an immutable mainnet cell it would have been permanent.
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    error ZeroAdmin();

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (!(newAdmin != address(0))) revert ZeroAdmin();
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    function wire(address _cell) external onlyAdmin {
        if (wiringLocked) revert WiringLocked();
        cell = _cell;
    }

    function lockWiring() external onlyAdmin {
        if (cell == address(0)) revert HostUnset();
        wiringLocked = true;
    }

    function setSpecChallengeFee(uint256 v) external onlyAdmin {
        _requireUnlocked(LOCK_CHALLENGE_FEE);
        specChallengeFee = v;
        emit ParameterUpdated("specChallengeFee", v);
    }

    function setSpecChallengeStake(uint256 v) external onlyAdmin {
        _requireUnlocked(LOCK_CHALLENGE_STAKE);
        specChallengeStake = v;
        emit ParameterUpdated("specChallengeStake", v);
    }

    function setSpecChallengeWindow(uint256 v) external onlyAdmin {
        _requireUnlocked(LOCK_CHALLENGE_WINDOW);
        if (v < MIN_SPEC_CHALLENGE_WINDOW) revert WindowBelowFloor();
        specChallengeWindow = v;
        emit ParameterUpdated("specChallengeWindow", v);
    }

    function setSpecChallengeRepeatSlashBps(uint256 v) external onlyAdmin {
        _requireUnlocked(LOCK_REPEAT_SLASH);
        if (v > 10_000) revert InvalidBps();
        specChallengeRepeatSlashBps = v;
        emit ParameterUpdated("specChallengeRepeatSlashBps", v);
    }

    function setSpecArbiterDecisionWindow(uint256 v) external onlyAdmin {
        _requireUnlocked(LOCK_ARBITER_DECISION_WINDOW);
        if (v < MIN_SPEC_ARBITER_DECISION_WINDOW) revert WindowBelowFloor();
        specArbiterDecisionWindow = v;
        emit ParameterUpdated("specArbiterDecisionWindow", v);
    }

    /// VD-117(4). `v` is STRICTLY below 10_000, so `charge < stake` holds by construction rather than by a
    /// deploy-time read-back. VD-156 asked for the assert "the way it asserts fee < stake"; expressed as
    /// bps of the stake the invariant is structural, which is the stronger form of the same guarantee -
    /// a deploy assert can be skipped by a path nobody ran, and this cannot be reached at all.
    function setSpecChallengeExpiryChargeBps(uint256 v) external onlyAdmin {
        _requireUnlocked(LOCK_EXPIRY_CHARGE);
        if (v >= 10_000) revert InvalidBps();
        specChallengeExpiryChargeBps = v;
        emit ParameterUpdated("specChallengeExpiryChargeBps", v);
    }

    function setSpecArbiterRewardBps(uint256 v) external onlyAdmin {
        _requireUnlocked(LOCK_ARBITER_REWARD);
        if (v > 10_000) revert InvalidBps();
        specArbiterRewardBps = v;
        emit ParameterUpdated("specArbiterRewardBps", v);
    }

    function setSpecChallengerInvalidationRewardBps(uint256 v) external onlyAdmin {
        _requireUnlocked(LOCK_CHALLENGER_INVALIDATION_REWARD);
        if (v > 10_000) revert InvalidBps();
        specChallengerInvalidationRewardBps = v;
        emit ParameterUpdated("specChallengerInvalidationRewardBps", v);
    }

    function _settlement() internal view returns (IClaimSettlementMutator s) {
        if (cell == address(0)) revert HostUnset();
        s = IClaimSettlementMutator(cell);
    }

    function _ac() internal view returns (AuditCell c) {
        c = AuditCell(cell);
    }

    function _specArbiterSeed(uint256 auditId, address challenger, address exclude) internal view returns (bytes32) {
        AuditCell ac = _ac();
        bytes32 entropyWord = blockhash(block.number - 1);
        address provider = ac.entropyProvider();
        if (provider != address(0)) {
            bytes32 salt = keccak256(
                abi.encode(
                    "SPEC_ARBITER_V1",
                    auditId,
                    challenger,
                    exclude,
                    ac.queueLength(),
                    ac.totalSuccessfulAudits()
                )
            );
            entropyWord = AssignmentEntropyLib.providerSeed(provider, salt);
        }
        return keccak256(
            abi.encode(
                "SPEC_ARBITER_V1",
                auditId,
                challenger,
                exclude,
                entropyWord,
                ac.queueLength(),
                ac.totalSuccessfulAudits()
            )
        );
    }

    function _findSpecArbiter(uint256 auditId, address challenger, address exclude) internal view returns (address) {
        AuditCell ac = _ac();
        CellTypeDefs.Audit memory a = ac.getAudit(auditId);
        address protocol = a.protocol;
        address auditor = a.auditor;
        bytes32 seed = _specArbiterSeed(auditId, challenger, exclude);
        address chosen = address(0);
        uint256 eligibleCount = 0;
        address cursor = ac.queueHead();
        uint256 scanned = 0;
        uint256 maxScan = ac.queueLength();
        if (maxScan > MAX_SPEC_ARBITER_SCAN) maxScan = MAX_SPEC_ARBITER_SCAN;
        while (cursor != address(0) && scanned < maxScan) {
            address next = ac.queueNext(cursor);
            if (cursor != protocol && cursor != auditor && cursor != challenger && cursor != exclude && ac.isEligible(cursor)) {
                eligibleCount += 1;
                if (uint256(keccak256(abi.encode(seed, eligibleCount))) % eligibleCount == eligibleCount - 1) {
                    chosen = cursor;
                }
            }
            cursor = next;
            scanned += 1;
        }
        return chosen;
    }

    function _isSpecArbiterEligible(uint256 auditId, address candidate, address challenger) internal view returns (bool) {
        if (candidate == address(0)) return false;
        AuditCell ac = _ac();
        CellTypeDefs.Audit memory a = ac.getAudit(auditId);
        address protocol = a.protocol;
        address auditor = a.auditor;
        if (candidate == protocol || candidate == auditor || candidate == challenger) return false;
        return ac.isEligible(candidate);
    }

    function _payoutAndVoid(uint256 auditId, address challenger, address arbiter)
        internal
        returns (uint256 arbiterReward)
    {
        AuditCell ac = _ac();
        IClaimSettlementMutator s = _settlement();
        CellTypeDefs.Audit memory a = ac.getAudit(auditId);
        // G1: a DISPUTE row's escrowed bounty is its funder's (`lastDiscoverer`), not the disputed protocol's - reachable
        // only since G1 escrows dispute rows (VD-199), and the same payee `SubmitAuditLib._voidAuditRow` now uses.
        address protocol = a.isClaimDispute ? a.lastDiscoverer : a.protocol;
        uint256 lockedBounty = a.bounty;

        if (lockedBounty > 0 && ac.auditBountyEscrowed(auditId)) {
            uint256 fee = specChallengeFee;
            if (fee > lockedBounty) fee = lockedBounty;
            uint256 toProtocol = lockedBounty - fee;
            if (fee > 0) {
                if (arbiter != address(0)) {
                    arbiterReward = fee * specArbiterRewardBps / 10_000;
                    uint256 toChallengerReward = fee * specChallengerInvalidationRewardBps / 10_000;
                    if (arbiterReward + toChallengerReward > fee) {
                        toChallengerReward = fee - arbiterReward;
                    }
                    uint256 toAdmin = fee - arbiterReward - toChallengerReward;
                    if (arbiterReward > 0) s.settlementToken(1, address(0), arbiter, arbiterReward);
                    if (toChallengerReward > 0) s.settlementToken(1, address(0), challenger, toChallengerReward);
                    if (toAdmin > 0) s.settlementToken(1, address(0), ac.admin(), toAdmin);
                } else {
                    s.settlementToken(1, address(0), ac.admin(), fee);
                }
            }
            if (toProtocol > 0) s.settlementToken(1, address(0), protocol, toProtocol);
        }
        s.settlementOverlay(0, 2, auditId, challenger);
    }

    function challengeActive(uint256 auditId) external view returns (bool) {
        return _challenges[auditId].active;
    }

    function specChallenges(uint256 auditId)
        external
        view
        returns (
            address challenger,
            bytes32 failErrorsRoot,
            uint256 stakeAmount,
            uint256 openedAt,
            bool active,
            address specArbiter
        )
    {
        SpecChallenge storage ch = _challenges[auditId];
        return (ch.challenger, ch.failErrorsRoot, ch.stakeAmount, ch.openedAt, ch.active, ch.specArbiter);
    }

    function _challengeableState(CellTypeDefs.AuditState s) internal pure returns (bool) {
        return s == CellTypeDefs.AuditState.Submitted || s == CellTypeDefs.AuditState.Assigned
            || s == CellTypeDefs.AuditState.InAudit || s == CellTypeDefs.AuditState.AwaitingWindow;
    }

    function _resolutionDeadline(SpecChallenge storage ch) internal view returns (uint256) {
        uint256 window = ch.specArbiter != address(0) ? specArbiterDecisionWindow : specChallengeWindow;
        return ch.openedAt + window;
    }

    function challengeSpecInvalid(uint256 auditId, bytes32 failErrorsRoot) external nonReentrant {
        AuditCell ac = _ac();
        IClaimSettlementMutator s = _settlement();

        if (!ac.auditExists(auditId)) revert NoAudit();
        if (ac.activeDisputeAuditId(auditId) != 0) revert DisputeOpen();
        CellTypeDefs.Audit memory a = ac.getAudit(auditId);
        CellTypeDefs.AuditState state = a.state;
        bytes32 specHash = a.specHash;
        bytes32 specToolId = a.specToolId;
        bytes32 specPassDigest = a.specPassDigest;
        if (!_challengeableState(state)) revert NotChallengeable();
        if (specToolId == bytes32(0)) revert NoSpecTool();
        if (_challenges[auditId].active) revert ChallengeOpen();
        if (RunDigests.specRunDigest(specHash, specToolId, true, failErrorsRoot) == specPassDigest) revert ErrorsRootMatchesPass();

        uint256 stake = specChallengeStake;
        if (stake > 0) {
            s.settlementToken(0, msg.sender, address(0), stake);
        }

        address arbiter = _findSpecArbiter(auditId, msg.sender, address(0));

        _challenges[auditId] = SpecChallenge({
            challenger: msg.sender,
            failErrorsRoot: failErrorsRoot,
            stakeAmount: stake,
            openedAt: block.timestamp,
            active: true,
            specArbiter: arbiter,
            frozenAt: block.timestamp
        });

        if (arbiter != address(0)) {
            emit SpecArbiterAssigned(auditId, arbiter);
        } else {
            emit SpecArbiterUnavailable(auditId);
        }
        emit SpecChallengeOpened(auditId, msg.sender, specToolId, failErrorsRoot);
    }

    function reassignSpecArbiter(uint256 auditId) external {
        SpecChallenge storage ch = _challenges[auditId];
        if (!ch.active) revert NoChallenge();
        if (ch.specArbiter == address(0)) revert NoSpecArbiter();
        if (_isSpecArbiterEligible(auditId, ch.specArbiter, ch.challenger)) revert ArbiterIneligible();

        address oldArbiter = ch.specArbiter;
        address next = _findSpecArbiter(auditId, ch.challenger, oldArbiter);
        ch.specArbiter = next;
        ch.openedAt = block.timestamp;

        if (next != address(0)) {
            emit SpecArbiterReassigned(auditId, oldArbiter, next);
        } else {
            emit SpecArbiterUnavailable(auditId);
        }
    }

    function declareSpecArbitrament(uint256 auditId, bytes32 specErrorsRoot) external nonReentrant {
        AuditCell ac = _ac();
        SpecChallenge storage ch = _challenges[auditId];
        if (!ch.active) revert NoChallenge();
        if (msg.sender != ch.specArbiter) revert NotSpecArbiter();
        if (ch.specArbiter == address(0)) revert NoSpecArbiter();
        // PC-93 bug_013 (G3, I2): the ruling closes where `expireSilentSpecArbiter` opens, so a silent arbiter who wakes
        // late cannot race its own expiry.
        if (block.timestamp >= ch.openedAt + specArbiterDecisionWindow) revert ArbiterWindowClosed();
        if (!_isSpecArbiterEligible(auditId, ch.specArbiter, ch.challenger)) revert ArbiterIneligible();

        CellTypeDefs.Audit memory a = ac.getAudit(auditId);
        bool passConfirmed = RunDigests.specRunDigest(a.specHash, a.specToolId, true, specErrorsRoot) == a.specPassDigest;

        address challenger = ch.challenger;
        address arbiter = ch.specArbiter;
        uint256 stake = ch.stakeAmount;
        uint256 frozenAt = ch.frozenAt;
        delete _challenges[auditId];
        IClaimSettlementMutator s = _settlement();

        if (passConfirmed) {
            s.settlementResumeClock(auditId, frozenAt); // G4(a): the row survives, so does its clock
            // DEC-47 (2026-09-30): the arbiter is paid the same on either ruling. Before this the PASS
            // branch forfeited the whole stake to the treasury escrow and paid the arbiter nothing, while
            // the FAIL branch paid them `specArbiterRewardBps` of the fee out of the bounty, so one ruling
            // was priced above the other: the tilt DEC-46 took out of the spec-gap contest, found again
            // here by the payout-family review. The PASS reward comes out of the challenger's forfeited
            // stake and is sized exactly as `_payoutAndVoid` sizes the FAIL reward (the fee, clamped to
            // what is actually there), so the challenger who lost funds the ruling against them and the
            // protocol whose row survived pays nothing. At the shipped `specChallengeFee` of 0 both
            // branches pay 0: parity, not a change in what the live cell would do.
            uint256 passFee = specChallengeFee;
            if (passFee > stake) passFee = stake;
            uint256 passReward = passFee * specArbiterRewardBps / 10_000;
            uint256 forfeited = stake - passReward;
            if (passReward > 0) s.settlementToken(1, address(0), arbiter, passReward);
            if (forfeited > 0) s.settlementToken(2, address(0), address(0), forfeited);
            emit SpecArbitramentDeclared(auditId, arbiter, specErrorsRoot, true, forfeited, passReward);
            emit SpecChallengeFinalized(auditId, challenger, false);
            return;
        }

        uint256 arbiterReward = _payoutAndVoid(auditId, challenger, arbiter);
        if (stake > 0) {
            s.settlementToken(1, address(0), challenger, stake);
        }
        emit SpecArbitramentDeclared(auditId, arbiter, specErrorsRoot, false, 0, arbiterReward);
        emit SpecChallengeFinalized(auditId, challenger, true);
    }

    function defendSpecChallenge(uint256 auditId, bytes32 passErrorsRoot) external nonReentrant {
        AuditCell ac = _ac();
        SpecChallenge storage ch = _challenges[auditId];
        if (!ch.active) revert NoChallenge();
        if (ch.specArbiter != address(0)) revert SpecArbiterAssignedBlock();
        // PC-93 bug_014 (G3, I2): the defend closes where `finalizeSpecChallenge` opens, so a protocol watching for
        // finalisation can no longer always defend first.
        if (block.timestamp >= _resolutionDeadline(ch)) revert ChallengeWindowClosed();

        CellTypeDefs.Audit memory a = ac.getAudit(auditId);
        if (msg.sender != a.protocol) revert NotProtocol();
        if (RunDigests.specRunDigest(a.specHash, a.specToolId, true, passErrorsRoot) != a.specPassDigest) revert SpecRunMismatch();

        address challenger = ch.challenger;
        uint256 stake = ch.stakeAmount;
        uint256 frozenAt = ch.frozenAt;
        delete _challenges[auditId];

        uint256 priorDefends = specDefendedChallengeCount[auditId][challenger];
        uint256 slashBps = priorDefends == 0
            ? 0
            : (specChallengeRepeatSlashBps * priorDefends > 10_000 ? 10_000 : specChallengeRepeatSlashBps * priorDefends);
        uint256 slashAmount = stake * slashBps / 10_000;
        uint256 refundAmount = stake - slashAmount;

        IClaimSettlementMutator s = _settlement();
        s.settlementResumeClock(auditId, frozenAt); // G4(a): the row survives, so does its clock
        if (refundAmount > 0) {
            s.settlementToken(1, address(0), challenger, refundAmount);
        }
        if (slashAmount > 0) {
            s.settlementToken(2, address(0), address(0), slashAmount);
        }

        specDefendedChallengeCount[auditId][challenger] = priorDefends + 1;
        emit SpecChallengeDefended(auditId, msg.sender, challenger, refundAmount, slashAmount);
    }

    function expireSilentSpecArbiter(uint256 auditId) external {
        SpecChallenge storage ch = _challenges[auditId];
        if (!ch.active) revert NoChallenge();
        address arbiter = ch.specArbiter;
        if (arbiter == address(0)) revert NoSpecArbiter();
        if (!_isSpecArbiterEligible(auditId, arbiter, ch.challenger)) revert ArbiterIneligible();
        if (block.timestamp < ch.openedAt + specArbiterDecisionWindow) revert ArbiterWindowOpen();

        ch.specArbiter = address(0);
        ch.openedAt = block.timestamp;
        emit SpecArbiterSilentExpired(auditId, arbiter);
    }

    function finalizeSpecChallenge(uint256 auditId) external nonReentrant {
        SpecChallenge storage ch = _challenges[auditId];
        if (!ch.active) revert NoChallenge();
        if (ch.specArbiter != address(0)) {
            if (!_isSpecArbiterEligible(auditId, ch.specArbiter, ch.challenger)) revert ArbiterIneligible();
            revert SpecArbiterAssignedBlock();
        }
        if (block.timestamp < _resolutionDeadline(ch)) revert ChallengeWindowOpen();

        address challenger = ch.challenger;
        uint256 stake = ch.stakeAmount;
        uint256 frozenAt = ch.frozenAt;
        delete _challenges[auditId];

        // VD-107: a challenge nobody RULED on may void a row ONLY when no auditor is assigned.
        // With an auditor on the row, a default void is assignment steering: the protocol - or a
        // second address it funds, which is why `msg.sender != protocol` is not the fix - dodges
        // the auditor it drew, takes the whole bounty back, and the auditor is paid nothing. That
        // walks around INV-6.2's reject cap, which counts rejections and never sees this one.
        // Withdrawal stays allowed, priced, and PRE-ASSIGNMENT; after assignment a spec dispute
        // needs an arbiter's ruling (`declareSpecArbitrament`), which this branch leaves untouched.
        IClaimSettlementMutator s = _settlement();
        if (_ac().getAudit(auditId).auditor != address(0)) {
            s.settlementResumeClock(auditId, frozenAt); // G4(a): the row survives, so does its clock
            // Unresolved expiry: the row is untouched, and deleting the challenge above already
            // unlocked the lane (the cell reads `challengeActive` live - there is no lock flag).
            // The fee is charged to the CHALLENGER's stake, never to the bounty: the row survives,
            // so drawing a fee out of an escrowed bounty would leave `a.bounty` overstating what
            // actually backs it. Same clamp shape as `_payoutAndVoid`. A repeat challenge costs
            // the fee again, so grinding this lever is bounded by the challenger's own money.
            // VD-117(4): its OWN parameter now, not `specChallengeFee`. The clamp that used to sit here
            // (`if (fee > stake) fee = stake`) is gone because it cannot bind: the setter refuses any value
            // at or above 10_000 bps, so the charge is strictly below the stake by construction and a
            // refund of zero is unreachable. That clamp biting at parity is exactly what VD-117 found.
            uint256 charge = stake * specChallengeExpiryChargeBps / 10_000;
            uint256 refund = stake - charge;
            if (refund > 0) s.settlementToken(1, address(0), challenger, refund);
            if (charge > 0) s.settlementToken(2, address(0), address(0), charge);
            emit SpecChallengeFinalized(auditId, challenger, false);
            return;
        }

        _payoutAndVoid(auditId, challenger, address(0));
        if (stake > 0) {
            s.settlementToken(1, address(0), challenger, stake);
        }
        emit SpecChallengeFinalized(auditId, challenger, true);
    }
}

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
    error ReentrantCall();

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus = _NOT_ENTERED;

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

    function wire(address _cell) external onlyAdmin {
        if (wiringLocked) revert WiringLocked();
        cell = _cell;
    }

    function lockWiring() external onlyAdmin {
        if (cell == address(0)) revert HostUnset();
        wiringLocked = true;
    }

    function setSpecChallengeFee(uint256 v) external onlyAdmin {
        specChallengeFee = v;
        emit ParameterUpdated("specChallengeFee", v);
    }

    function setSpecChallengeStake(uint256 v) external onlyAdmin {
        specChallengeStake = v;
        emit ParameterUpdated("specChallengeStake", v);
    }

    function setSpecChallengeWindow(uint256 v) external onlyAdmin {
        specChallengeWindow = v;
        emit ParameterUpdated("specChallengeWindow", v);
    }

    function setSpecChallengeRepeatSlashBps(uint256 v) external onlyAdmin {
        specChallengeRepeatSlashBps = v;
        emit ParameterUpdated("specChallengeRepeatSlashBps", v);
    }

    function setSpecArbiterDecisionWindow(uint256 v) external onlyAdmin {
        specArbiterDecisionWindow = v;
        emit ParameterUpdated("specArbiterDecisionWindow", v);
    }

    function setSpecArbiterRewardBps(uint256 v) external onlyAdmin {
        specArbiterRewardBps = v;
        emit ParameterUpdated("specArbiterRewardBps", v);
    }

    function setSpecChallengerInvalidationRewardBps(uint256 v) external onlyAdmin {
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
        (address protocol, address auditor, , , , , , , , , , , , , , , , , , ) = ac.audits(auditId);
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
        (address protocol, address auditor, , , , , , , , , , , , , , , , , , ) = ac.audits(auditId);
        if (candidate == protocol || candidate == auditor || candidate == challenger) return false;
        return ac.isEligible(candidate);
    }

    function _payoutAndVoid(uint256 auditId, address challenger, address arbiter)
        internal
        returns (uint256 arbiterReward)
    {
        AuditCell ac = _ac();
        IClaimSettlementMutator s = _settlement();
        (address protocol, , , uint256 lockedBounty, , , , , , , , , , , , , , , , ) = ac.audits(auditId);

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
        (, , , , , CellTypeDefs.AuditState state, bytes32 specHash, , bytes32 specToolId, bytes32 specPassDigest, , , , , , , , , , ) =
            ac.audits(auditId);
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
            specArbiter: arbiter
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
        if (!_isSpecArbiterEligible(auditId, ch.specArbiter, ch.challenger)) revert ArbiterIneligible();

        (, , , , , , bytes32 specHash, , bytes32 specToolId, bytes32 specPassDigest, , , , , , , , , , ) =
            ac.audits(auditId);
        bool passConfirmed = RunDigests.specRunDigest(specHash, specToolId, true, specErrorsRoot) == specPassDigest;

        address challenger = ch.challenger;
        address arbiter = ch.specArbiter;
        uint256 stake = ch.stakeAmount;
        delete _challenges[auditId];
        IClaimSettlementMutator s = _settlement();

        if (passConfirmed) {
            if (stake > 0) {
                s.settlementToken(2, address(0), address(0), stake);
            }
            emit SpecArbitramentDeclared(auditId, arbiter, specErrorsRoot, true, stake, 0);
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

        (address protocol, , , , , , bytes32 specHash, , bytes32 specToolId, bytes32 specPassDigest, , , , , , , , , , ) =
            ac.audits(auditId);
        if (msg.sender != protocol) revert NotProtocol();
        if (RunDigests.specRunDigest(specHash, specToolId, true, passErrorsRoot) != specPassDigest) revert SpecRunMismatch();

        address challenger = ch.challenger;
        uint256 stake = ch.stakeAmount;
        delete _challenges[auditId];

        uint256 priorDefends = specDefendedChallengeCount[auditId][challenger];
        uint256 slashBps = priorDefends == 0
            ? 0
            : (specChallengeRepeatSlashBps * priorDefends > 10_000 ? 10_000 : specChallengeRepeatSlashBps * priorDefends);
        uint256 slashAmount = stake * slashBps / 10_000;
        uint256 refundAmount = stake - slashAmount;

        IClaimSettlementMutator s = _settlement();
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
        delete _challenges[auditId];

        _payoutAndVoid(auditId, challenger, address(0));
        if (stake > 0) {
            _settlement().settlementToken(1, address(0), challenger, stake);
        }
        emit SpecChallengeFinalized(auditId, challenger, true);
    }
}

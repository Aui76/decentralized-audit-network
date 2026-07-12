// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./ISpecGapModule.sol";
import "./SpecGapLib.sol";
import "./AuditCell.sol";
import "./CellStorage.sol";

/// @title SpecGapModule — F-83 Part B spec-gap overlay (cell-v2 P2 / C12).
contract SpecGapModule is ISpecGapModule {
    uint256 internal constant DISPUTE_BOUNTY_MIN_BPS = 5000;
    uint256 internal constant INTEGRITY_CONTEST_STAKE = 500 ether;

    address public admin;
    address public cell;
    bool public wiringLocked;

    mapping(bytes32 => bool) public vulnerabilityClassRegistered;
    mapping(bytes32 => bytes32[]) internal _toolKnownGaps;
    mapping(bytes32 => mapping(bytes32 => bool)) public toolHasGap;

    mapping(uint256 => mapping(bytes32 => SpecGapLib.Record)) public specGaps;
    mapping(uint256 => mapping(bytes32 => uint256)) public activeSpecGapDisputeAuditId;
    mapping(uint256 => bytes32) public disputeSpecGapClassId;

    event SpecGapOpened(
        uint256 indexed auditId, bytes32 indexed classId, address indexed filer, bytes32 evaluatorToolId, uint256 stake
    );
    event SpecGapConfirmed(uint256 indexed auditId, bytes32 indexed classId, address indexed filer);
    event SpecGapFalse(uint256 indexed auditId, bytes32 indexed classId, address indexed filer);
    event SpecGapDeclined(uint256 indexed auditId, bytes32 indexed classId, address indexed filer);
    event SpecGapAdopted(uint256 indexed auditId, bytes32 indexed classId, address indexed filer, uint256 reward);
    event SpecGapExpired(uint256 indexed auditId, bytes32 indexed classId, address indexed filer);
    event SpecGapContested(uint256 indexed auditId, bytes32 indexed classId, uint256 contestStake);
    event SpecGapDisputeOpened(uint256 indexed originalAuditId, bytes32 indexed classId, uint256 disputeAuditId);
    event SpecGapDisputeExpired(uint256 indexed originalAuditId, bytes32 indexed classId, uint256 disputeAuditId);

    error NotAdmin();
    error NotCell();
    error WiringLocked();
    error HostUnset();
    error InvalidAuditId();
    error AuditNotGapEligible();
    error GapExists();
    error ClassNotRegistered();
    error FilerNotRegistered();
    error FilerCannotBeProtocol();
    error FilerCannotBeOriginalAuditor();
    error MisrouteWithinS();
    error WitnessRequired();
    error InvariantRequired();
    error BadFinderTool();
    error BadEvaluator();
    error EvaluatorNotCanonical();
    error WitnessResultRootMismatch();
    error NotOpen();
    error ContestOpen();
    error OnlyProtocol();
    error ContestAlreadyOpen();
    error BountyLow();
    error BytecodeDrift();
    error ProtocolWindowOpen();
    error NoGap();
    error NotConfirmable();
    error RewardRequired();
    error ResolutionWindowOpen();
    error NoOpenContest();
    error ContestVerdicted();
    error ContestWindowActive();
    error GapNotOpen();
    error ContestMismatch();
    error ContestWitnessMismatch();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyCell() {
        if (msg.sender != cell) revert NotCell();
        _;
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

    function registerClass(bytes32 classId) external {
        if (msg.sender != admin && msg.sender != cell) revert NotAdmin();
        vulnerabilityClassRegistered[classId] = true;
    }

    function toolKnownGapCount(bytes32 toolId) external view returns (uint256) {
        return _toolKnownGaps[toolId].length;
    }

    function toolKnownGapAt(bytes32 toolId, uint256 i) external view returns (bytes32) {
        return _toolKnownGaps[toolId][i];
    }

    function _ac() internal view returns (AuditCell c) {
        if (cell == address(0)) revert HostUnset();
        c = AuditCell(cell);
    }

    function _claimEligible(CellTypeDefs.AuditState s) internal pure returns (bool) {
        return s == CellTypeDefs.AuditState.AwaitingWindow || s == CellTypeDefs.AuditState.Audited
            || s == CellTypeDefs.AuditState.InBlock;
    }

    function specGapStatusOf(uint256 auditId, bytes32 classId) external view returns (SpecGapLib.Status) {
        return specGaps[auditId][classId].status;
    }

    function evaluatorForDispute(uint256 disputeId) external view returns (bytes32) {
        AuditCell c = _ac();
        uint256 linked = c.auditLinkedOf(disputeId);
        bytes32 classId = disputeSpecGapClassId[disputeId];
        return specGaps[linked][classId].evaluatorToolId;
    }

    function openSpecGap(
        uint256 originalAuditId,
        bytes32 classId,
        bytes32 finderToolId,
        bytes32 resultRoot,
        bytes32 evaluatorToolId,
        bytes32 invariantId,
        bytes32 locationCommitment,
        bytes32 witnessCommitment,
        bytes32 contextRoot
    ) external {
        AuditCell ac = _ac();
        if (originalAuditId >= ac.nextAuditId()) revert InvalidAuditId();

        CellTypeDefs.Audit memory a = ac.getAudit(originalAuditId);
        CellTypeDefs.AuditState state = a.state;
        bytes32 specHash = a.specHash;
        bytes32 artifactHash = a.artifactHash;
        bytes32 specToolId = a.specToolId;
        if (!_claimEligible(state)) revert AuditNotGapEligible();
        if (specGaps[originalAuditId][classId].exists) revert GapExists();
        if (!vulnerabilityClassRegistered[classId]) revert ClassNotRegistered();

        address protocol = a.protocol;
        address auditor = a.auditor;
        (,,, uint256 filerPosition,,) = ac.auditors(msg.sender);
        if (filerPosition == 0) revert FilerNotRegistered();
        if (msg.sender == protocol) revert FilerCannotBeProtocol();
        if (msg.sender == auditor) revert FilerCannotBeOriginalAuditor();
        if (evaluatorToolId == specToolId) revert MisrouteWithinS();
        if (witnessCommitment == bytes32(0)) revert WitnessRequired();
        if (invariantId == bytes32(0)) revert InvariantRequired();

        (address finderProposer, bool finderIsSpec, , , bool finderExists, , ) = ac.tools(finderToolId);
        finderProposer;
        if (!finderExists || finderIsSpec) revert BadFinderTool();

        (address evalProposer, bool evalIsSpec, bool evalIsEval, bool evalCanon, bool evalExists, , ) =
            ac.tools(evaluatorToolId);
        evalProposer;
        if (!evalExists || evalIsSpec) revert BadEvaluator();
        if (!evalIsEval || !evalCanon) revert EvaluatorNotCanonical();

        SpecGapLib.Record memory draft = SpecGapLib.Record({
            filer: msg.sender,
            classId: classId,
            finderToolId: finderToolId,
            proofHash: resultRoot,
            evaluatorToolId: evaluatorToolId,
            invariantId: invariantId,
            locationCommitment: locationCommitment,
            witnessCommitment: witnessCommitment,
            contextRoot: contextRoot,
            filedAt: block.timestamp,
            filingStake: 0,
            contestStake: 0,
            status: SpecGapLib.Status.Filed,
            exists: true
        });
        if (!SpecGapLib.witnessFailAtOpenMemory(resultRoot, draft, artifactHash, specHash)) {
            revert WitnessResultRootMismatch();
        }

        uint256 stakeDue = ac.requiredClaimStake(originalAuditId);
        if (stakeDue > 0) {
            ac.settlementToken(0, msg.sender, address(0), stakeDue);
        }
        draft.filingStake = stakeDue;
        specGaps[originalAuditId][classId] = draft;

        emit SpecGapOpened(originalAuditId, classId, msg.sender, evaluatorToolId, stakeDue);
    }

    function protocolConcedeSpecGap(uint256 auditId, bytes32 classId) external {
        AuditCell ac = _ac();
        if (msg.sender != ac.auditProtocolOf(auditId)) revert OnlyProtocol();
        SpecGapLib.Record storage g = specGaps[auditId][classId];
        if (!g.exists || g.status != SpecGapLib.Status.Filed) revert NotOpen();
        if (activeSpecGapDisputeAuditId[auditId][classId] != 0) revert ContestOpen();
        _confirmSpecGapFact(auditId, classId, g, SpecGapLib.Status.Confirmed);
    }

    function protocolDeclineSpecGapRelevance(uint256 auditId, bytes32 classId) external {
        AuditCell ac = _ac();
        if (msg.sender != ac.auditProtocolOf(auditId)) revert OnlyProtocol();
        SpecGapLib.Record storage g = specGaps[auditId][classId];
        if (!g.exists || g.status != SpecGapLib.Status.Filed) revert NotOpen();
        if (activeSpecGapDisputeAuditId[auditId][classId] != 0) revert ContestOpen();
        _confirmSpecGapFact(auditId, classId, g, SpecGapLib.Status.Declined);
    }

    function protocolContestSpecGap(uint256 auditId, bytes32 classId, uint256 disputeBounty)
        external
        returns (uint256 disputeId)
    {
        AuditCell ac = _ac();
        if (msg.sender != ac.auditProtocolOf(auditId)) revert OnlyProtocol();
        SpecGapLib.Record storage g = specGaps[auditId][classId];
        if (!g.exists || g.status != SpecGapLib.Status.Filed) revert NotOpen();
        if (activeSpecGapDisputeAuditId[auditId][classId] != 0) revert ContestAlreadyOpen();

        CellTypeDefs.Audit memory a = ac.getAudit(auditId);
        uint256 minBounty = (a.bounty * DISPUTE_BOUNTY_MIN_BPS) / 10_000;
        if (disputeBounty < minBounty || disputeBounty == 0) revert BountyLow();
        address deployed = a.deployedAddress;
        if (deployed != address(0) && deployed.codehash != a.artifactHash) revert BytecodeDrift();
        ac.settlementToken(0, msg.sender, address(0), disputeBounty + INTEGRITY_CONTEST_STAKE);
        g.contestStake = INTEGRITY_CONTEST_STAKE;
        emit SpecGapContested(auditId, classId, INTEGRITY_CONTEST_STAKE);

        disputeId = ac.spawnDisputeReaudit(
            auditId, disputeBounty, msg.sender, g.filer, g.evaluatorToolId, address(this)
        );
        activeSpecGapDisputeAuditId[auditId][classId] = disputeId;
        disputeSpecGapClassId[disputeId] = classId;
        emit SpecGapDisputeOpened(auditId, classId, disputeId);
    }

    function confirmSpecGapSilence(uint256 auditId, bytes32 classId) external {
        AuditCell ac = _ac();
        SpecGapLib.Record storage g = specGaps[auditId][classId];
        if (!g.exists || g.status != SpecGapLib.Status.Filed) revert NotOpen();
        if (activeSpecGapDisputeAuditId[auditId][classId] != 0) revert ContestOpen();
        if (block.timestamp < g.filedAt + ac.protocolDecisionWindow()) revert ProtocolWindowOpen();
        _confirmSpecGapFact(auditId, classId, g, SpecGapLib.Status.Confirmed);
    }

    function adoptSpecGap(uint256 auditId, bytes32 classId, uint256 discoveryReward) external {
        AuditCell ac = _ac();
        if (msg.sender != ac.auditProtocolOf(auditId)) revert OnlyProtocol();
        SpecGapLib.Record storage g = specGaps[auditId][classId];
        if (!g.exists) revert NoGap();
        if (g.status != SpecGapLib.Status.Confirmed && g.status != SpecGapLib.Status.Declined) revert NotConfirmable();
        if (discoveryReward == 0) revert RewardRequired();
        ac.settlementToken(0, msg.sender, address(0), discoveryReward);
        ac.settlementToken(1, address(0), g.filer, discoveryReward);
        g.status = SpecGapLib.Status.Adopted;
        emit SpecGapAdopted(auditId, classId, g.filer, discoveryReward);
    }

    function expireSpecGap(uint256 auditId, bytes32 classId) external {
        AuditCell ac = _ac();
        SpecGapLib.Record storage g = specGaps[auditId][classId];
        if (!g.exists || g.status != SpecGapLib.Status.Filed) revert NotOpen();
        if (activeSpecGapDisputeAuditId[auditId][classId] != 0) revert ContestOpen();
        if (block.timestamp < g.filedAt + ac.claimResolutionWindow()) revert ResolutionWindowOpen();
        if (g.filingStake > 0) {
            ac.settlementToken(2, address(0), address(0), g.filingStake);
            g.filingStake = 0;
        }
        g.status = SpecGapLib.Status.Expired;
        emit SpecGapExpired(auditId, classId, g.filer);
    }

    function expireSpecGapDispute(uint256 auditId, bytes32 classId) external {
        AuditCell ac = _ac();
        uint256 disputeId = activeSpecGapDisputeAuditId[auditId][classId];
        if (disputeId == 0) revert NoOpenContest();
        if (ac.auditStateOf(disputeId) == CellTypeDefs.AuditState.AwaitingWindow) revert ContestVerdicted();
        CellTypeDefs.Audit memory ad = ac.getAudit(disputeId);
        uint256 refund = ad.bounty;
        uint256 windowStart = ad.windowStart;
        address funder = ad.lastDiscoverer;
        if (block.timestamp < windowStart + ac.claimResolutionWindow()) revert ContestWindowActive();

        SpecGapLib.Record storage g = specGaps[auditId][classId];
        activeSpecGapDisputeAuditId[auditId][classId] = 0;
        if (refund > 0) {
            ac.settlementToken(1, address(0), funder, refund);
        }
        if (g.contestStake > 0) {
            ac.settlementToken(1, address(0), funder, g.contestStake);
            g.contestStake = 0;
        }
        emit SpecGapDisputeExpired(auditId, classId, disputeId);
    }

    function resolveFromDispute(uint256 originalAuditId, uint256 disputeId) external onlyCell {
        AuditCell ac = _ac();
        bytes32 classId = disputeSpecGapClassId[disputeId];
        SpecGapLib.Record storage g = specGaps[originalAuditId][classId];
        if (!g.exists || g.status != SpecGapLib.Status.Filed) revert GapNotOpen();
        if (activeSpecGapDisputeAuditId[originalAuditId][classId] != disputeId) revert ContestMismatch();

        CellTypeDefs.Audit memory a = ac.getAudit(originalAuditId);
        bytes32 specHash = a.specHash;
        bytes32 artifactHash = a.artifactHash;
        bytes32 rDisp = ac.auditProofHash(disputeId);
        bool passVerdict = ac.auditVerdictPass(disputeId);
        bool passReplay = SpecGapLib.disputePassReplay(rDisp, passVerdict, g, artifactHash, specHash);
        bool failReplay = SpecGapLib.disputeFailReplay(rDisp, passVerdict, g, artifactHash, specHash);
        if (!passReplay && !failReplay) revert ContestWitnessMismatch();

        activeSpecGapDisputeAuditId[originalAuditId][classId] = 0;
        address reRunner = ac.auditAuditorOf(disputeId);

        if (failReplay) {
            if (g.contestStake > 0 && reRunner != address(0)) {
                uint256 toRunner = g.contestStake;
                g.contestStake = 0;
                ac.settlementToken(1, address(0), reRunner, toRunner);
            }
            _confirmSpecGapFact(originalAuditId, classId, g, SpecGapLib.Status.Confirmed);
            return;
        }

        if (g.filingStake > 0) {
            ac.settlementToken(2, address(0), address(0), g.filingStake);
            g.filingStake = 0;
        }
        if (g.contestStake > 0) {
            address protocol = ac.auditProtocolOf(originalAuditId);
            uint256 returned = g.contestStake;
            g.contestStake = 0;
            ac.settlementToken(1, address(0), protocol, returned);
        }
        g.status = SpecGapLib.Status.False;
        emit SpecGapFalse(originalAuditId, classId, g.filer);
    }

    function _confirmSpecGapFact(
        uint256 auditId,
        bytes32 classId,
        SpecGapLib.Record storage g,
        SpecGapLib.Status finalStatus
    ) internal {
        AuditCell ac = _ac();
        CellTypeDefs.Audit memory a = ac.getAudit(auditId);
        bytes32 specHash = a.specHash;
        bytes32 artifactHash = a.artifactHash;
        bytes32 specToolId = a.specToolId;
        if (!SpecGapLib.witnessFailAtOpen(g.proofHash, g, artifactHash, specHash)) revert WitnessResultRootMismatch();
        if (g.filingStake > 0) {
            uint256 refund = g.filingStake;
            g.filingStake = 0;
            ac.settlementToken(1, address(0), g.filer, refund);
        }
        g.status = finalStatus;
        if (specToolId != bytes32(0) && !toolHasGap[specToolId][classId]) {
            toolHasGap[specToolId][classId] = true;
            _toolKnownGaps[specToolId].push(classId);
        }
        if (finalStatus == SpecGapLib.Status.Confirmed) {
            emit SpecGapConfirmed(auditId, classId, g.filer);
        } else {
            emit SpecGapDeclined(auditId, classId, g.filer);
        }
    }
}

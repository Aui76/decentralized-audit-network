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
    /// G3 (VD-186(a), I2): the protocol CONTESTED this gap. A latch, never cleared: a contest that expired unaudited is
    /// still a protocol that spoke, so silence-confirm stays refused, a second contest is refused (one per gap), and the
    /// gap's one exit is `expireSpecGap` with the filer refunded. Its own mapping rather than a field on `Record`, so the
    /// public `specGaps` getter's return shape does not change.
    mapping(uint256 => mapping(bytes32 => bool)) public specGapContested;
    /// PK-4 tier 3, built (spec-gap-funded-demonstration-proposal, 2026-09-30): a FUNDED DEMONSTRATION's discovery
    /// reward, keyed on its dispute row. Non-zero means the row is a demonstration and not a contest, which is how
    /// `resolveFromDispute` and `expireSpecGapDispute` tell the two apart. The reward sits in the cell from funding to
    /// settlement and leaves it exactly once: to the filer on a FAIL replay, back to the funder on anything else.
    /// Keyed on the dispute id rather than on the gap so several demonstrations can be funded in turn.
    mapping(uint256 => uint256) public demonstrationReward;

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
    event SpecGapDemonstrationFunded(
        uint256 indexed originalAuditId,
        bytes32 indexed classId,
        address indexed funder,
        uint256 disputeAuditId,
        uint256 reRunBounty,
        uint256 discoveryReward
    );
    /// `demonstrated` true: the drawn re-runner's FAIL replayed the filer's witness and `paidTo` is the filer.
    /// false: a PASS, a verdict that replayed neither side, or an expiry, and `paidTo` is the funder, refunded.
    event SpecGapDemonstrationSettled(
        uint256 indexed originalAuditId,
        bytes32 indexed classId,
        uint256 disputeAuditId,
        bool demonstrated,
        address paidTo,
        uint256 amount
    );

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
    error SilenceHasConfirmed();
    error GapContested();
    error FunderCannotBeFiler();
    error NotDemonstrable();

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
        // G3: one contest per gap. Re-contesting after an unaudited expiry would restart the stall at no cost.
        if (specGapContested[auditId][classId]) revert ContestAlreadyOpen();
        specGapContested[auditId][classId] = true;

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
        // VD-186(a): a protocol that contested has spoken - its expired contest is not silence.
        if (specGapContested[auditId][classId]) revert GapContested();
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

    /// @notice PK-4 tier 3 (dan-core F-83 Part B B6, parked 2026-06-16, built 2026-09-30): ANYONE BUT THE FILER pays to
    ///         have a recorded gap demonstrated, and pays the filer if it holds. Before this the overlay had ONE payout,
    ///         `adoptSpecGap`, and only the protocol could call it: a gap the protocol conceded, or let silence confirm,
    ///         and then declined to adopt, paid its discoverer nothing, ever. This is the market path the proposal named
    ///         and never built. The funder puts up a re-run bounty (the same floor as a contest, so a re-runner is paid
    ///         for the same work) and a discovery reward; the cell draws a re-runner the same way it draws for a contest,
    ///         with the filer AND the funder excluded from the draw; the re-runner's FAIL replay of the filer's witness
    ///         pays the reward to the filer, and anything else returns it to the funder. No S-escrow draw, no mint, no
    ///         treasury pull: the reward is capital someone chose to put behind this gap (PC-8's constraint).
    ///         Only a gap the protocol has already answered (Confirmed or Declined) is demonstrable: a Filed gap is the
    ///         protocol's to concede, decline or contest inside its window, and this must not pre-empt that.
    function fundSpecGapDemonstration(uint256 auditId, bytes32 classId, uint256 reRunBounty, uint256 discoveryReward)
        external
        returns (uint256 disputeId)
    {
        AuditCell ac = _ac();
        SpecGapLib.Record storage g = specGaps[auditId][classId];
        if (!g.exists) revert NoGap();
        if (g.status != SpecGapLib.Status.Confirmed && g.status != SpecGapLib.Status.Declined) revert NotDemonstrable();
        if (msg.sender == g.filer) revert FunderCannotBeFiler();
        if (activeSpecGapDisputeAuditId[auditId][classId] != 0) revert ContestOpen();
        if (discoveryReward == 0) revert RewardRequired();

        CellTypeDefs.Audit memory a = ac.getAudit(auditId);
        uint256 minBounty = (a.bounty * DISPUTE_BOUNTY_MIN_BPS) / 10_000;
        if (reRunBounty < minBounty || reRunBounty == 0) revert BountyLow();
        address deployed = a.deployedAddress;
        if (deployed != address(0) && deployed.codehash != a.artifactHash) revert BytecodeDrift();
        ac.settlementToken(0, msg.sender, address(0), reRunBounty + discoveryReward);

        // The funder is the second exclusion (PC-99's hook): a funder who is also a queued auditor must not draw the row
        // they funded and settle their own reward. The filer is the first, as on a contest.
        ac.settlementSetDisputeExclude2(auditId, msg.sender);
        disputeId = ac.spawnDisputeReaudit(auditId, reRunBounty, msg.sender, g.filer, g.evaluatorToolId, address(this));
        activeSpecGapDisputeAuditId[auditId][classId] = disputeId;
        disputeSpecGapClassId[disputeId] = classId;
        demonstrationReward[disputeId] = discoveryReward;
        emit SpecGapDemonstrationFunded(auditId, classId, msg.sender, disputeId, reRunBounty, discoveryReward);
    }

    function expireSpecGap(uint256 auditId, bytes32 classId) external {
        AuditCell ac = _ac();
        SpecGapLib.Record storage g = specGaps[auditId][classId];
        if (!g.exists || g.status != SpecGapLib.Status.Filed) revert NotOpen();
        if (activeSpecGapDisputeAuditId[auditId][classId] != 0) revert ContestOpen();
        if (block.timestamp < g.filedAt + ac.claimResolutionWindow()) revert ResolutionWindowOpen();
        // G3 (PC-49's note, VD-172(4)(a), I2): `confirmSpecGapSilence` and this were two permissionless exits from one
        // Filed state with opposite economics. Precedence, written in code: on an UNCONTESTED gap, once the protocol's
        // window has passed silence has won and Confirmed is the only exit; on a CONTESTED gap whose contest expired
        // unaudited, this is the only exit (silence-confirm is refused) and, with no adjudicated outcome, the filer is
        // REFUNDED rather than slashed (VD-117).
        bool contested = specGapContested[auditId][classId];
        if (!contested && block.timestamp >= g.filedAt + ac.protocolDecisionWindow()) revert SilenceHasConfirmed();
        if (g.filingStake > 0) {
            uint256 stake = g.filingStake;
            g.filingStake = 0;
            if (contested) {
                ac.settlementToken(1, address(0), g.filer, stake);
            } else {
                ac.settlementToken(2, address(0), address(0), stake);
            }
        }
        g.status = SpecGapLib.Status.Expired;
        emit SpecGapExpired(auditId, classId, g.filer);
    }

    function expireSpecGapDispute(uint256 auditId, bytes32 classId) external {
        AuditCell ac = _ac();
        uint256 disputeId = activeSpecGapDisputeAuditId[auditId][classId];
        if (disputeId == 0) revert NoOpenContest();
        CellTypeDefs.Audit memory ad = ac.getAudit(disputeId);
        address funder = ad.lastDiscoverer;
        // VD-218(4) F1 (PC-98's shape on this lane): a VERDICTED contest row is no longer refused outright. Nobody confirming
        // it for one resolution window past its audit window releases it here; confirm closes at that same instant (I2).
        uint256 due = ad.windowStart + ac.claimResolutionWindow();
        if (ad.state == CellTypeDefs.AuditState.AwaitingWindow) due += ad.auditWindow;
        if (block.timestamp < due) revert ContestWindowActive();

        SpecGapLib.Record storage g = specGaps[auditId][classId];
        activeSpecGapDisputeAuditId[auditId][classId] = 0;
        // G1 (PC-87's expiry half, PC-95(2)): the CELL ends the dispute row - refunds its bounty to the funder, zeroes
        // the field, clears the escrow flag and makes the row terminal. This module used to refund the bounty itself
        // and leave the row live with the field set, which G1's escrow would have made payable a second time.
        ac.settlementOverlay(2, 2, disputeId, address(0));
        uint256 reward = demonstrationReward[disputeId];
        if (reward > 0) {
            // A demonstration nobody ran: the reward goes back where it came from, beside the re-run bounty the cell
            // just refunded. The gap's status was never touched by funding, so there is nothing to restore.
            demonstrationReward[disputeId] = 0;
            ac.settlementToken(1, address(0), funder, reward);
            emit SpecGapDemonstrationSettled(auditId, classId, disputeId, false, funder, reward);
            return;
        }
        if (g.contestStake > 0) {
            ac.settlementToken(1, address(0), funder, g.contestStake);
            g.contestStake = 0;
        }
        emit SpecGapDisputeExpired(auditId, classId, disputeId);
    }

    /// @dev The demonstration half of `resolveFromDispute`. The row's verdict was paid at confirm (the re-run bounty to
    ///      the drawn re-runner, by the cell, G1). What is settled here is the reward only, and the gap's STATUS IS NOT
    ///      REWRITTEN in any branch: it was fixed by the protocol's own answer or by its silence, and one re-run funded by
    ///      a third party is evidence about the payout, not a second adjudication of the fact.
    function _settleDemonstration(
        AuditCell ac,
        uint256 originalAuditId,
        bytes32 classId,
        uint256 disputeId,
        SpecGapLib.Record storage g,
        uint256 reward
    ) internal {
        demonstrationReward[disputeId] = 0;
        CellTypeDefs.Audit memory a = ac.getAudit(originalAuditId);
        bool failReplay = SpecGapLib.disputeFailReplay(
            ac.auditProofHash(disputeId), ac.auditVerdictPass(disputeId), g, a.artifactHash, a.specHash
        );
        address paidTo = failReplay ? g.filer : ac.getAudit(disputeId).lastDiscoverer;
        ac.settlementToken(1, address(0), paidTo, reward);
        emit SpecGapDemonstrationSettled(originalAuditId, classId, disputeId, failReplay, paidTo, reward);
    }

    function resolveFromDispute(uint256 originalAuditId, uint256 disputeId) external onlyCell {
        AuditCell ac = _ac();
        bytes32 classId = disputeSpecGapClassId[disputeId];
        SpecGapLib.Record storage g = specGaps[originalAuditId][classId];
        if (activeSpecGapDisputeAuditId[originalAuditId][classId] != disputeId) revert ContestMismatch();
        uint256 reward = demonstrationReward[disputeId];
        if (reward != 0) {
            activeSpecGapDisputeAuditId[originalAuditId][classId] = 0;
            _settleDemonstration(ac, originalAuditId, classId, disputeId, g, reward);
            return;
        }
        if (!g.exists || g.status != SpecGapLib.Status.Filed) revert GapNotOpen();

        CellTypeDefs.Audit memory a = ac.getAudit(originalAuditId);
        bytes32 specHash = a.specHash;
        bytes32 artifactHash = a.artifactHash;
        bytes32 rDisp = ac.auditProofHash(disputeId);
        bool passVerdict = ac.auditVerdictPass(disputeId);
        bool passReplay = SpecGapLib.disputePassReplay(rDisp, passVerdict, g, artifactHash, specHash);
        bool failReplay = SpecGapLib.disputeFailReplay(rDisp, passVerdict, g, artifactHash, specHash);
        activeSpecGapDisputeAuditId[originalAuditId][classId] = 0;
        // VD-218(4) F1: a contest verdict that replays NEITHER side is an OUTCOME, not a revert - the revert froze the gap and
        // both stakes, and the drawn re-auditor chose it by choosing the root. The contest ends UNADJUDICATED: its stake
        // back to its funder (VD-117), the gap left Filed with its latch set, so its one exit stays `expireSpecGap` with the
        // filer refunded (G3). The verdict stands and was paid at confirm, as on the claim lane (PC-98).
        if (!passReplay && !failReplay) {
            if (g.contestStake > 0) {
                uint256 back = g.contestStake;
                g.contestStake = 0;
                ac.settlementToken(1, address(0), ac.getAudit(disputeId).lastDiscoverer, back);
            }
            emit SpecGapDisputeExpired(originalAuditId, classId, disputeId);
            return;
        }
        if (failReplay) {
            // The contest stake goes to the FILER whose witness held, not to the re-runner (changed 2026-09-30,
            // spec-gap-funded-demonstration-proposal). The re-runner is paid the dispute bounty by the cell whichever
            // way the replay goes; paying them 500 more on FAIL only priced one verdict above the other.
            if (g.contestStake > 0) {
                uint256 toFiler = g.contestStake;
                g.contestStake = 0;
                ac.settlementToken(1, address(0), g.filer, toFiler);
            }
            _confirmSpecGapFact(originalAuditId, classId, g, SpecGapLib.Status.Confirmed);
            return;
        }

        if (g.filingStake > 0) {
            ac.settlementToken(2, address(0), address(0), g.filingStake);
            g.filingStake = 0;
        }
        if (g.contestStake > 0) {
            // Back to whoever funded the contest: the row's `lastDiscoverer`, which is the protocol today and stays the
            // right identity if the contest is ever opened to others.
            address contester = ac.getAudit(disputeId).lastDiscoverer;
            uint256 returned = g.contestStake;
            g.contestStake = 0;
            ac.settlementToken(1, address(0), contester, returned);
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

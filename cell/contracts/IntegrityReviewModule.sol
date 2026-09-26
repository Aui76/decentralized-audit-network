// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./IClaimSettlementMutator.sol";
import "./AuditCell.sol";
import "./CellStorage.sol";
import "./SpecArbiterModule.sol";

/// @title IntegrityReviewModule — F-52 overlay (X4): wash/collusion review on audit row O.
/// @notice Settlement-touching L1 satellite; lock + sustained void via cell hook (same seam as X1).
///
/// ADJUDICATED SINCE 2026-09-04 (VD-89 + VD-90). Before that date the contest right belonged EXCLUSIVELY to
/// the party a verdict PAYS: only the protocol could contest, a SUSTAINED verdict returns the bounty to the
/// protocol and slashes the auditor, and a contest simply OVERWROTE the verdict
/// (`finalPass = contested ? contestPass : pass`) with both stakes refunded outside any outcome branch. The
/// attack cost gas: the protocol opened through one sock puppet, a second sock puppet submitted FAIL, nobody
/// contested because the only party with standing was winning, and the honest auditor was slashed. Three
/// things changed, and they only work together:
///   (1) STANDING FOLLOWS HARM - the auditor may contest SUSTAINED, the protocol may contest CLEARED, and
///       nobody may contest a verdict in their own favour;
///   (2) A CONTEST ESCALATES, IT DOES NOT DECIDE - it opens a re-audit whose auditor is DRAWN by the cell
///       (`spawnDisputeReaudit` -> `_assignNext`), and THAT verdict is `finalPass`, delivered back through
///       `resolveFromDispute`. A second SELF-APPOINTED reviewer would be infinite regress: the puppeteer
///       appoints that one too;
///   (3) THE STAKES SETTLE AGAINST THE ADJUDICATED OUTCOME WITH A REAL LOSER - see `resolveFromDispute`.
/// The `Contested` latch that holds confirm across the re-audit has THREE releases, and all three are driven
/// in `cell/test/IntegrityLaneAdjudication.t.sol`: the two adjudicated outcomes, and
/// `expireContestedIntegrityReview` for the re-audit that never returns.
contract IntegrityReviewModule {
    enum IntegrityReviewStatus {
        None,
        Open,
        VerdictSubmitted,
        Cleared,
        Sustained,
        Expired,
        // APPENDED so every existing member keeps its value. `Contested` is a LATCH: it holds the confirm
        // block for the WHOLE re-audit (VD-89(3) - releasing early recreates settle-then-unwind) and it
        // proves its own release on all three exits: `resolveFromDispute` (both outcomes) and
        // `expireContestedIntegrityReview` (the re-audit that never returns).
        Contested,
        // Terminal disposal for a contest whose re-audit never resolved: no adjudicated outcome, therefore
        // no adjudicated loser. Distinct from `Expired`, which means "no reviewer ever showed up".
        Void
    }

    struct IntegrityReview {
        address opener;
        address reviewer;
        bytes32 integrityToolId;
        bytes32 resultRoot;
        bool pass;
        uint256 bountyAmount;
        uint256 filingStake;
        uint256 openedAt;
        uint256 verdictSubmittedAt;
        IntegrityReviewStatus status;
        bool contested;
        bool contestPass;
        bytes32 contestResultRoot;
        uint256 contestStake;
        address contester;
        uint256 contestedAt;
    }

    address public admin;
    address public cell;
    address public specArbiterModule;
    bool public wiringLocked;

    uint256 public integrityFilingStake = 100 ether;
    uint256 public integrityReviewWindow = 7 days;
    uint256 public integrityContestWindow = 2 days;
    uint256 public integrityContestStake = 500 ether;

    mapping(uint256 => IntegrityReview) internal _reviews;

    /// @notice The re-audit row currently adjudicating a contested review; 0 when none is open.
    mapping(uint256 => uint256) public activeIntegrityDisputeId;

    event IntegrityReviewOpened(
        uint256 indexed auditId,
        address indexed opener,
        bytes32 indexed integrityToolId,
        uint256 bountyAmount,
        uint256 treasuryMatch
    );
    event IntegrityVerdictSubmitted(uint256 indexed auditId, address indexed reviewer, bool pass, bytes32 resultRoot);
    /// @dev `contester` is the AUDITOR on a sustained verdict and the PROTOCOL on a cleared one (VD-89(2)).
    ///      The parameter was named `protocol` while the protocol was the only party with standing; the
    ///      signature - and therefore topic0 - is unchanged.
    event IntegrityReviewContested(
        uint256 indexed auditId, address indexed contester, bool pass, bytes32 resultRoot, uint256 stake
    );
    event IntegrityContestEscalated(
        uint256 indexed auditId, address indexed contester, uint256 indexed disputeAuditId, uint256 stake
    );
    event IntegrityReviewAdjudicated(
        uint256 indexed auditId, uint256 indexed disputeAuditId, bool finalPass, bool contestUpheld
    );
    event IntegrityContestVoided(
        uint256 indexed auditId, uint256 indexed disputeAuditId, address indexed contester
    );
    event IntegrityReviewFinalized(uint256 indexed auditId, address indexed reviewer, bool pass, uint256 paid);
    event IntegrityReviewExpired(uint256 indexed auditId, address indexed opener, uint256 stakeSlashed);
    event ParameterUpdated(string indexed name, uint256 value);

    error NotAdmin();
    error WiringLocked();
    error HostUnset();
    error NoAudit();
    error NotEligible();
    error ReviewExists();
    error SpecChallengeActive();
    error DisputeOpen();
    error ToolNotRegistered();
    error SpecToolNotForIntegrity();
    error BountyRequired();
    error OpenerCannotBeProtocol();
    error OpenerCannotBeAuditor();
    error OpenerNotRegistered();
    error ReviewNotOpen();
    error ReviewWindowClosed();
    error ReviewWindowOpen();
    error ReviewerNotRegistered();
    error ReviewerCannotBeProtocol();
    error ReviewerCannotBeAuditor();
    error ReviewerCannotBeOpener();
    error ResultRootRequired();
    error NoVerdict();
    error ContestWindowOpen();
    error ContestWindowClosed();
    error NoStanding();
    error AlreadyContested();
    error ContestMustOppose();
    error StakeTransferFailed();
    error TransferFailed();
    error ReentrantCall();
    error BadParamId();
    error ParamLocked();
    error NotCell();
    error NotContested();
    error DisputeMismatch();
    error ContestVerdicted();
    error ContestResolutionWindowOpen();

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus = _NOT_ENTERED;

    // Phase B1 (admin-door-residue-verdicts, VD-26): doors 9-11 lock+bound pass. Ported from
    // IssuanceModule's issuanceParamLockMask shape (A1: capability now, armed later per parameter —
    // ships UNARMED, mask = 0).
    uint256 public integrityParamLockMask;
    uint8 public constant LOCK_FILING_STAKE = 0;   // door 9: setIntegrityFilingStake
    uint8 public constant LOCK_CONTEST_STAKE = 1;  // door 10: setIntegrityContestStake
    // Door 11 (LOCK_MATCH_BPS = 2) IS GONE with the `integrityMatchBps` limb it guarded (section B-2, VD-89(4)).
    // The bit is not reused: `lockIntegrityParam` now rejects id 2, so a stale caller fails loudly instead of
    // arming a door onto nothing. Removed selectors are entered in `cell/surface-removals.txt` with reasons.

    function integrityParamLocked(uint8 id) public view returns (bool) {
        return (integrityParamLockMask & (uint256(1) << id)) != 0;
    }

    /// @notice Lock an integrity-review economic param one-way (irreversible). UNARMED at this deploy by design.
    function lockIntegrityParam(uint8 id) external onlyAdmin {
        if (id > LOCK_CONTEST_STAKE) revert BadParamId();
        integrityParamLockMask |= (uint256(1) << id);
        emit ParameterUpdated("integrityParamLock", id);
    }

    function _requireUnlocked(uint8 id) internal view {
        if (integrityParamLocked(id)) revert ParamLocked();
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

    function wire(address _cell, address _specArbiter) external onlyAdmin {
        if (wiringLocked) revert WiringLocked();
        cell = _cell;
        specArbiterModule = _specArbiter;
    }

    function lockWiring() external onlyAdmin {
        if (cell == address(0)) revert HostUnset();
        wiringLocked = true;
    }

    function setIntegrityFilingStake(uint256 v) external onlyAdmin {
        _requireUnlocked(LOCK_FILING_STAKE);
        integrityFilingStake = v;
        emit ParameterUpdated("integrityFilingStake", v);
    }

    function setIntegrityReviewWindow(uint256 v) external onlyAdmin {
        integrityReviewWindow = v;
        emit ParameterUpdated("integrityReviewWindow", v);
    }

    function setIntegrityContestWindow(uint256 v) external onlyAdmin {
        integrityContestWindow = v;
        emit ParameterUpdated("integrityContestWindow", v);
    }

    function setIntegrityContestStake(uint256 v) external onlyAdmin {
        _requireUnlocked(LOCK_CONTEST_STAKE);
        integrityContestStake = v;
        emit ParameterUpdated("integrityContestStake", v);
    }

    function integrityReviewStatusOf(uint256 auditId) external view returns (IntegrityReviewStatus) {
        return _reviews[auditId].status;
    }

    /// @notice Confirm stays blocked for the WHOLE proceeding, re-audit included (VD-89(3)): releasing the
    ///         block once the re-audit is merely SPAWNED would let the row settle and then need unwinding.
    ///         `Cleared`, `Sustained`, `Expired` and `Void` are terminal and do not block.
    function confirmBlocked(uint256 auditId) external view returns (bool) {
        IntegrityReviewStatus s = _reviews[auditId].status;
        return s == IntegrityReviewStatus.Open || s == IntegrityReviewStatus.VerdictSubmitted
            || s == IntegrityReviewStatus.Contested;
    }

    function integrityRunDigest(uint256 auditId, bytes32 toolId, bool pass, bytes32 resultRoot)
        public
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "AUDIT_INTEGRITY_RUN_V1", auditId, toolId, pass ? bytes1(0x01) : bytes1(0x00), resultRoot
            )
        );
    }

    function _settlement() internal view returns (IClaimSettlementMutator s) {
        s = IClaimSettlementMutator(cell);
    }

    function _eligibleState(CellTypeDefs.AuditState s) internal pure returns (bool) {
        return s == CellTypeDefs.AuditState.AwaitingWindow || s == CellTypeDefs.AuditState.InBlock;
    }

    function openIntegrityReview(uint256 auditId, bytes32 integrityToolId, uint256 bountyAmount) external nonReentrant {
        AuditCell host = AuditCell(cell);
        if (!host.auditExists(auditId)) revert NoAudit();
        CellTypeDefs.AuditState st = host.auditStateOf(auditId);
        if (!_eligibleState(st)) revert NotEligible();
        if (_reviews[auditId].status != IntegrityReviewStatus.None) revert ReviewExists();
        if (specArbiterModule != address(0) && SpecArbiterModule(specArbiterModule).challengeActive(auditId)) {
            revert SpecChallengeActive();
        }

        address protocol = host.auditProtocolOf(auditId);
        address auditor = host.auditAuditorOf(auditId);
        if (msg.sender == protocol) revert OpenerCannotBeProtocol();
        if (msg.sender == auditor) revert OpenerCannotBeAuditor();
        (, , , uint256 position, , ) = host.auditors(msg.sender);
        if (position == 0) revert OpenerNotRegistered();

        ( , bool isSpec, , , bool exists, , ) = host.tools(integrityToolId);
        if (!exists) revert ToolNotRegistered();
        if (isSpec) revert SpecToolNotForIntegrity();
        if (bountyAmount == 0) revert BountyRequired();

        uint256 filing = integrityFilingStake;
        IClaimSettlementMutator s = _settlement();
        s.settlementToken(0, msg.sender, address(this), filing + bountyAmount);
        if (AuditCell(cell).specChallengeActive(auditId)) revert SpecChallengeActive();

        _reviews[auditId] = IntegrityReview({
            opener: msg.sender,
            reviewer: address(0),
            integrityToolId: integrityToolId,
            resultRoot: bytes32(0),
            pass: false,
            bountyAmount: bountyAmount,
            filingStake: filing,
            openedAt: block.timestamp,
            verdictSubmittedAt: 0,
            status: IntegrityReviewStatus.Open,
            contested: false,
            contestPass: false,
            contestResultRoot: bytes32(0),
            contestStake: 0,
            contester: address(0),
            contestedAt: 0
        });

        // The 5th argument is the retired treasury match (section B-2). It is emitted as a literal 0 - which
        // is TRUE, no match is paid any more - rather than dropped, because dropping it changes the event
        // signature and therefore its topic0, a surface removal this brief does not authorise.
        emit IntegrityReviewOpened(auditId, msg.sender, integrityToolId, bountyAmount, 0);
    }

    function submitIntegrityVerdict(uint256 auditId, bool pass, bytes32 resultRoot) external nonReentrant {
        IntegrityReview storage r = _reviews[auditId];
        if (r.status != IntegrityReviewStatus.Open) revert ReviewNotOpen();
        if (block.timestamp > r.openedAt + integrityReviewWindow) revert ReviewWindowClosed();
        if (resultRoot == bytes32(0)) revert ResultRootRequired();

        AuditCell host = AuditCell(cell);
        address protocol = host.auditProtocolOf(auditId);
        address auditor = host.auditAuditorOf(auditId);
        (, , , uint256 position, , ) = host.auditors(msg.sender);
        if (position == 0) revert ReviewerNotRegistered();
        if (msg.sender == protocol) revert ReviewerCannotBeProtocol();
        if (msg.sender == auditor) revert ReviewerCannotBeAuditor();
        if (msg.sender == r.opener) revert ReviewerCannotBeOpener();

        r.reviewer = msg.sender;
        r.pass = pass;
        r.resultRoot = resultRoot;
        r.verdictSubmittedAt = block.timestamp;
        r.status = IntegrityReviewStatus.VerdictSubmitted;

        emit IntegrityVerdictSubmitted(auditId, msg.sender, pass, resultRoot);
    }

    /// @notice Contest a submitted verdict. THIS ESCALATES; IT DOES NOT DECIDE (VD-89(1)).
    /// @dev The caller must be the party the verdict HARMS (VD-89(2)) and the contest opens a re-audit whose
    ///      auditor the cell DRAWS. Contesting is therefore never free and never self-serving.
    function contestIntegrityVerdict(uint256 auditId, bool pass, bytes32 resultRoot) external nonReentrant {
        IntegrityReview storage r = _reviews[auditId];
        // Checked BEFORE the status test so a SECOND contest names itself. Once a contest lands the status is
        // `Contested`, which the status test would otherwise report as `NoVerdict` - true but unhelpful.
        if (r.contested) revert AlreadyContested();
        if (r.status != IntegrityReviewStatus.VerdictSubmitted) revert NoVerdict();
        if (block.timestamp >= r.verdictSubmittedAt + integrityContestWindow) revert ContestWindowClosed();
        if (pass == r.pass) revert ContestMustOppose();
        if (resultRoot == bytes32(0)) revert ResultRootRequired();

        // STANDING FOLLOWS HARM. A SUSTAINED verdict (pass == false) returns the bounty to the protocol and
        // increments the AUDITOR's `failed`, so the auditor is the harmed party; a CLEARED verdict lets the
        // audit stand, so the protocol is. NOBODY MAY CONTEST A VERDICT IN THEIR OWN FAVOUR - which deletes
        // the stall lane STRUCTURALLY rather than policing it: the auditor cannot stall a clearing verdict
        // because a clearing verdict is not theirs to contest.
        AuditCell host = AuditCell(cell);
        address entitled = r.pass ? host.auditProtocolOf(auditId) : host.auditAuditorOf(auditId);
        if (msg.sender != entitled) revert NoStanding();

        uint256 stake = integrityContestStake;
        // G1 (VD-199(2)): TWO AMOUNTS. The stake, which this module disposes of against the adjudicated outcome, and the
        // re-audit bounty, which the cell escrows on the dispute row and pays the DRAWN adjudicator at confirm (or
        // refunds the contester on expiry). Priced at the review's own bounty: the adjudicator re-does the review the
        // opener priced, and a funder-chosen amount would need a new ABI and a floor this lane has never had.
        uint256 reauditBounty = r.bountyAmount;
        if (stake + reauditBounty > 0) {
            _settlement().settlementToken(0, msg.sender, address(this), stake + reauditBounty);
        }

        r.contested = true;
        r.contestPass = pass;
        r.contestResultRoot = resultRoot;
        r.contestStake = stake;
        r.contester = msg.sender;
        r.contestedAt = block.timestamp;
        // The latch is set BEFORE the spawn: the spawn skips THIS module's own block by construction
        // (CellLogicLib._requireNoForeignSettlementBlock) and enforces every foreign one, so there is no
        // window in which the row looks unblocked.
        r.status = IntegrityReviewStatus.Contested;

        emit IntegrityReviewContested(auditId, msg.sender, pass, resultRoot, stake);

        // The adjudicator is DRAWN by `_assignNext`, not appointed. That single property is what defeats the
        // sock-puppet attack, and it is the property no number of extra self-appointed reviewers can buy.
        // The re-audit row carries `reauditBounty`, escrowed by the cell and paid by `confirmAudit` (PC-87, G1). The
        // contest STAKE never reaches the row, so this module is the only disposer of it by construction - the comment
        // here used to assert that on the premise the cell never pays a dispute row, which funded the row WITH the stake.
        // PC-99 (G5, I5): TWO parties are excluded, not one. The reviewer's verdict is what is contested; the OPENER
        // recovers the bounty and gets the auditor a `failed` when a FAIL stands, so an opener drawn to adjudicate decides
        // their own review. The draw is the whole defence against sock puppets (see the note above), and a draw that can
        // land on an interested party only holds while the queue is large.
        _settlement().settlementSetDisputeExclude2(auditId, r.opener);
        uint256 disputeId =
            host.spawnDisputeReaudit(auditId, reauditBounty, msg.sender, r.reviewer, r.integrityToolId, address(this));
        activeIntegrityDisputeId[auditId] = disputeId;
        emit IntegrityContestEscalated(auditId, msg.sender, disputeId, stake);
    }

    /// @notice The DRAWN re-auditor's verdict arrives here, from the cell, when the re-audit row confirms.
    ///         ITS verdict is `finalPass` - the contester's assertion never decides anything by itself.
    function resolveFromDispute(uint256 originalId, uint256 disputeId) external {
        if (msg.sender != cell) revert NotCell();
        IntegrityReview storage r = _reviews[originalId];
        if (r.status != IntegrityReviewStatus.Contested) revert NotContested();
        if (activeIntegrityDisputeId[originalId] != disputeId) revert DisputeMismatch();
        activeIntegrityDisputeId[originalId] = 0;

        bool finalPass = AuditCell(cell).auditVerdictPass(disputeId);
        bool upheld = finalPass == r.contestPass;
        r.status = finalPass ? IntegrityReviewStatus.Cleared : IntegrityReviewStatus.Sustained;

        IClaimSettlementMutator s = _settlement();
        // The reviewer is paid the opener's bounty for the review that was RUN; the settlement's shape
        // follows the ADJUDICATED outcome, not the reviewer's own verdict.
        if (r.bountyAmount > 0) {
            s.settlementToken(1, address(this), r.reviewer, r.bountyAmount);
        }
        // STAKES SETTLE AGAINST THE ADJUDICATED VERDICT, WITH A REAL LOSER. Before this change BOTH the
        // opener's filing stake and the contest stake were refunded outside any outcome branch, so nothing
        // was at risk from a false verdict in either direction.
        if (upheld) {
            if (r.contestStake > 0) s.settlementToken(1, address(this), r.contester, r.contestStake);
            if (r.filingStake > 0) s.settlementToken(2, address(this), address(0), r.filingStake);
        } else {
            if (r.contestStake > 0) s.settlementToken(2, address(this), address(0), r.contestStake);
            if (r.filingStake > 0) s.settlementToken(1, address(this), r.opener, r.filingStake);
        }
        if (!finalPass) {
            s.settlementOverlay(1, 2, originalId, address(0));
        }

        emit IntegrityReviewAdjudicated(originalId, disputeId, finalPass, upheld);
        emit IntegrityReviewFinalized(originalId, r.reviewer, finalPass, r.bountyAmount);
    }

    /// @notice THE UNSTICK PATH: a contest whose re-audit never returns a verdict (nobody drawable, the drawn
    ///         auditor silent, the re-audit abandoned) must not hold the row forever. `Contested` is a latch,
    ///         and a latch with no release re-imports the class this whole change is closing.
    /// @dev Permissionless, and refuses to fire while the re-audit still HAS a usable verdict
    ///      (`AwaitingWindow`), so it can never be used to dodge an adjudication that is about to land.
    ///      NO ADJUDICATED OUTCOME MEANS NO ADJUDICATED LOSER: every escrowed amount returns to whoever put
    ///      it in, the audit row is NOT voided, and the confirm block releases because `Void` is terminal.
    function expireContestedIntegrityReview(uint256 auditId) external nonReentrant {
        IntegrityReview storage r = _reviews[auditId];
        if (r.status != IntegrityReviewStatus.Contested) revert NotContested();
        AuditCell host = AuditCell(cell);
        uint256 disputeId = activeIntegrityDisputeId[auditId];
        if (host.auditStateOf(disputeId) == CellTypeDefs.AuditState.AwaitingWindow) revert ContestVerdicted();
        if (block.timestamp < r.contestedAt + host.claimResolutionWindow()) revert ContestResolutionWindowOpen();

        activeIntegrityDisputeId[auditId] = 0;
        r.status = IntegrityReviewStatus.Void;

        IClaimSettlementMutator s = _settlement();
        // G1: the cell ends the re-audit row - the re-audit bounty back to the contester who funded it, the field zeroed,
        // the flag cleared, the row terminal so the drawn adjudicator's late verdict cannot land (PC-95(2)).
        s.settlementOverlay(2, 2, disputeId, address(0));
        if (r.contestStake > 0) s.settlementToken(1, address(this), r.contester, r.contestStake);
        if (r.filingStake > 0) s.settlementToken(1, address(this), r.opener, r.filingStake);
        if (r.bountyAmount > 0) s.settlementToken(1, address(this), r.opener, r.bountyAmount);

        emit IntegrityContestVoided(auditId, disputeId, r.contester);
    }

    function finalizeIntegrityReview(uint256 auditId) external nonReentrant {
        IntegrityReview storage r = _reviews[auditId];
        if (r.status != IntegrityReviewStatus.VerdictSubmitted) revert NoVerdict();
        if (block.timestamp < r.verdictSubmittedAt + integrityContestWindow) revert ContestWindowOpen();

        address reviewer = r.reviewer;
        uint256 openerBounty = r.bountyAmount;
        uint256 filing = r.filingStake;
        // UNCONTESTED ONLY. A contest moves the review to `Contested`, which this function's status test
        // rejects, so the deleted `finalPass = r.contested ? r.contestPass : r.pass` has no remaining case:
        // a contested review is settled by the DRAWN adjudicator in `resolveFromDispute`, never here.
        bool finalPass = r.pass;

        r.status = finalPass ? IntegrityReviewStatus.Cleared : IntegrityReviewStatus.Sustained;

        IClaimSettlementMutator s = _settlement();
        s.settlementToken(1, address(this), reviewer, openerBounty);
        if (filing > 0) {
            s.settlementToken(1, address(this), r.opener, filing);
        }
        if (!finalPass) {
            s.settlementOverlay(1, 2, auditId, address(0));
        }

        emit IntegrityReviewFinalized(auditId, reviewer, finalPass, openerBounty);
    }

    function expireIntegrityReview(uint256 auditId) external nonReentrant {
        IntegrityReview storage r = _reviews[auditId];
        if (r.status != IntegrityReviewStatus.Open) revert ReviewNotOpen();
        if (block.timestamp <= r.openedAt + integrityReviewWindow) revert ReviewWindowOpen();

        address opener = r.opener;
        uint256 filing = r.filingStake;
        uint256 bounty = r.bountyAmount;

        r.status = IntegrityReviewStatus.Expired;

        IClaimSettlementMutator s = _settlement();
        if (filing > 0) {
            s.settlementToken(2, address(this), address(0), filing);
        }
        if (bounty > 0) {
            s.settlementToken(1, address(this), opener, bounty);
        }

        emit IntegrityReviewExpired(auditId, opener, filing);
    }
}

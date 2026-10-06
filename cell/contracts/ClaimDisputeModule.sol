// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./IClaimDisputeModule.sol";
import "./IClaimSettlementMutator.sol";
import "./WitnessClaimLib.sol";
import "genesis-tools/AuditResultV1.sol";
import "./IRunProofVerifier.sol";
import "./AuditCell.sol";
import "./CellStorage.sol";
import "./FmeaRegistry.sol";

/// @title ClaimDisputeModule — F-83 witness + legacy digest dispute settlement (cell-v2 P1).
/// @notice Replaceable settlement organ; reads cell via public getters, mutates via IClaimSettlementMutator.
contract ClaimDisputeModule is IClaimDisputeModule {
    uint8 internal constant STATE_IN_AUDIT = 3;
    uint8 internal constant STATE_AWAITING_WINDOW = 4;
    uint8 internal constant STATE_CLAIMED = 7;

    address public admin;
    address public cell;
    address public fmeaRegistry;
    bool public wiringLocked;

    error NotAdmin();
    error NotCell();
    error WiringLocked();
    error HostUnset();
    error OriginalNotEligibleForClaim();
    error ClaimAlreadyFiled();
    error ClaimantNotRegistered();
    error ClaimantCannotBeProtocol();
    error ClaimantCannotBeOriginalAuditor();
    error ToolNotRegistered();
    error SpecToolNotForClaim();
    error ResultRootRequired();
    error ToolNotDeclared();
    error ClaimProofRejected();
    error InvariantRequired();
    error EvaluatorRequired();
    error SpecToolNotForVerdict();
    error NotInvariantEvaluator();
    error EvaluatorNotCanonical();
    error WitnessResultRootMismatch();
    error NotClaimed();
    error ClaimAlreadyResolved();
    error DisputeMismatch();
    error DisputeWitnessMismatch();
    error DisputeNoReproduce();
    error InvalidOriginalId();
    error OriginalNotClaimed();
    error NoOpenClaim();
    error DisputeOpen();
    error OnlyProtocol();
    error BytecodeDrift();
    error BountyLow();
    error NoOpenDispute();
    error DisputeVerdicted();
    error DisputeWindowActive();
    error OnlyClaimant();
    error ClaimantLaneNotOpen();
    error AlreadyDeclined();
    error DisputeAlreadySpent();
    error AskNotAllowedHere();
    error AskNotOpen();
    error AskNotLower();
    error AskAlreadyFunded();
    error NothingToReclaim();
    error ReviewClaimNeedsWitness();
    error ReviewWindowPassed();
    error ReviewAuditorNotEligible();

    uint256 internal constant DISPUTE_BOUNTY_MIN_BPS = 5000;
    /// @dev DEC-48: the network's bonus on a post-confirm finding never exceeds this share of the re-run bounty. The re-run
    ///      bounty is the one payment a claimant-and-funder circle cannot get back (it goes to the drawn re-auditor), so a
    ///      bonus below half of it makes the circle lose money by construction, whatever the farmed reputation says.
    uint256 internal constant BONUS_RERUN_CAP_BPS = 5000;

    /// @dev DEC-48 (2026-10-01): THE FINDER'S PRICE. On a row whose bounty already went to the auditor at confirm, the cell
    ///      names no price for a hole found afterwards: the finder names one before filing (`pendingAsk`), it binds to the
    ///      claim at filing (`claimAsk`), and whoever funds the re-run puts that price beside the re-run bounty
    ///      (`claimAskFunded`, `claimAskFunder`). A FAIL that reproduces pays the price to the finder from the funder's money;
    ///      every other exit returns it to the funder. The pool then adds only a reputation bonus, best-effort, no debt.
    ///      Pre-confirm claims (the pot still escrowed) carry no ask: the posted bounty is their price.
    mapping(uint256 => mapping(address => uint256)) public pendingAsk;
    mapping(uint256 => uint256) public claimAsk;
    mapping(uint256 => uint256) public claimAskFunded;
    mapping(uint256 => address) public claimAskFunder;
    mapping(uint256 => uint256) public claimAskPaid;

    /// @dev F-80: protocol decline + claimant-funded dispute lane.
    mapping(uint256 => bool) public disputeFundingDeclined;
    mapping(uint256 => uint256) public claimProtocolDecisionDue;
    /// @dev PC-116 (G4, VD-216(3) Edge 2): ONE FUNDED DISPUTE PER FUNDER PER ORIGINAL. Set for the funder whenever a dispute
    ///      on this original ends through `expireDispute` - unverdicted, or verdicted and released unconfirmed - and read
    ///      where a dispute is funded. Since G2 a resolved claim no longer blocks a new filing, and since G3/PC-115 such an
    ///      end refunds everyone, so without this a funder (or a protocol with a colluding claimant) re-filed and re-funded
    ///      for the cost of time alone. Per FUNDER, not per claim: a party who has not spent a dispute here still may. A
    ///      CLAIMANT who has spent one is refused at FILING (VD-218(1)), the protocol at funding. NOT
    ///      set by a verdict that reproduces neither side (PC-98): the funder does not choose the drawn re-auditor.
    mapping(uint256 => mapping(address => bool)) public disputeSpent;
    uint256 public protocolClaimDecisionWindow;

    /// @dev F-79: claimant↔auditor + triangle dispute assignment exclusions (R8/R9).
    mapping(address => mapping(address => uint256)) public claimantAuditorCompleted;
    mapping(address => mapping(address => mapping(address => uint256))) public claimantProtocolAuditorTriangle;

    uint256 public maxClaimantDyadRepeats;
    uint256 public maxTriangleRepeats;
    bool public claimantDyadExclusionEnabled = true;
    uint256 public claimantDyadExclusionMinQueue = 100;

    event ParameterUpdated(string indexed name, uint256 value);
    event ProtocolDeclinedDisputeFunding(uint256 indexed originalId);
    event DisputeReauditOpened(uint256 indexed originalId, uint256 indexed disputeId);
    event DisputeReauditOpenedByClaimant(uint256 indexed originalId, uint256 indexed disputeId);
    /// @dev DEC-48: the finder's price, on the row for anyone to read. `reason` on a return: 1 the re-run reproduced the
    ///      PASS, 2 it reproduced neither side, 3 the drawn re-auditor stayed silent, 4 reclaimed after the row or the
    ///      re-run was ended by another lane (void) or superseded.
    event ClaimAskNamed(uint256 indexed originalId, address indexed claimant, uint256 ask);
    event ClaimAskFunded(uint256 indexed originalId, address indexed funder, uint256 ask, uint256 indexed disputeId);
    event ClaimAskPaid(uint256 indexed originalId, address indexed claimant, address indexed funder, uint256 ask);
    event ClaimAskReturned(uint256 indexed originalId, address indexed funder, uint256 ask, uint8 reason);
    event ClaimAskUnfunded(uint256 indexed originalId, address indexed claimant, uint256 ask);

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

    function wireFmeaRegistry(address _fmeaRegistry) external onlyAdmin {
        if (wiringLocked) revert WiringLocked();
        fmeaRegistry = _fmeaRegistry;
    }

    function lockWiring() external onlyAdmin {
        if (cell == address(0)) revert HostUnset();
        wiringLocked = true;
    }

    function _mutator() internal view returns (IClaimSettlementMutator m) {
        if (cell == address(0)) revert HostUnset();
        m = IClaimSettlementMutator(cell);
    }

    function _ac() internal view returns (AuditCell c) {
        c = AuditCell(cell);
    }

    function claimVulnerability(
        address claimant,
        uint256 originalAuditId,
        bytes32 toolId,
        bytes32 resultRoot,
        bytes calldata proof,
        bytes32 evaluatorToolId,
        bytes32 invariantId,
        bytes32 locationCommitment,
        bytes32 witnessCommitment,
        bytes32 contextRoot,
        bytes32 vulnerabilityClassId
    ) external onlyCell {
        IClaimSettlementMutator m = _mutator();
        AuditCell ac = _ac();

        CellTypeDefs.Audit memory a = ac.getAudit(originalAuditId);
        // THE AUDITOR'S WITNESS IN REVIEW. The row's own auditor, while the row is InAudit, files the witness claim a
        // stranger files after the PASS. Without it a finding the declared spec does not carry had no lane from that
        // seat: `proveFail` takes a declared tool's root and writes no witness, the gap lane refuses the row's auditor,
        // and the spec arbiter reproduces a well-formed spec's PASS. The hull settles it as it settles `proveFail`'s own
        // claim (`stateBeforeClaim == InAudit`): the pot pays, nobody is blamed, an unadjudicated exit gives the clock back.
        bool inReview = uint8(a.state) == STATE_IN_AUDIT;
        if (inReview) {
            _requireReviewClaim(ac, a, claimant, originalAuditId, witnessCommitment);
        } else if (!_claimEligible(a.state)) {
            revert OriginalNotEligibleForClaim();
        }
        bytes32 specHash = a.specHash;
        bytes32 artifactHash = a.artifactHash;

        (address priorClaimant, , , , , bool resolved, bool exists, , , , , , ) = ac.vulnerabilityClaims(originalAuditId);
        // VD-218(3), the hull's own test on the same record: one claim of its own per auditor per row in review, whichever
        // of the two lanes filed the first one. The clock comes back on an unadjudicated exit, so a second would stall.
        if (inReview && exists && priorClaimant == claimant) revert ClaimAlreadyFiled();
        // PC-81 (G2, I1): REFUSE ONLY WHILE A CLAIM IS OPEN. This refused on `exists`, which no exit ever cleared - every
        // terminal exit writes only `resolved` - so ONE lapsed or settled claim immunised the audit for good, and a
        // protocol shielding an exploitable contract paid one stake for it. The record is not deleted: the resolved claim
        // stays readable until the next filing overwrites it (`settlementApplyClaimFiled` writes every field).
        if (exists && !resolved) revert ClaimAlreadyFiled();
        // PC-116 as ruled by VD-218(1): a claimant whose dispute on this original ended without adjudication may not FILE
        // on it again - refused here, before any stake moves. Refused only at the funding site (G4 as first built), the
        // re-filed claim's one exit was the lapse, which slashes: an honest second claim stranded. One voice per original
        // per claimant; any other registrant can still report the finding.
        if (disputeSpent[originalAuditId][claimant]) revert DisputeAlreadySpent();
        // A decision about the LAST claim is not a decision about this one: `claimProtocolDecisionDue` is re-armed below,
        // and a funding refusal left set would open the claimant's dispute lane on the new claim at once.
        disputeFundingDeclined[originalAuditId] = false;

        address protocol = a.protocol;
        address auditor = a.auditor;
        (,,, uint256 claimantPosition,,) = ac.auditors(claimant);
        if (claimantPosition == 0) revert ClaimantNotRegistered();
        if (claimant == protocol) revert ClaimantCannotBeProtocol();
        if (claimant == auditor && !inReview) revert ClaimantCannotBeOriginalAuditor();

        (address toolProposer, bool isSpec, bool isEvaluator, bool canonical, bool toolExists) =
            _toolFlags(ac, toolId);
        toolProposer;
        if (!toolExists) revert ToolNotRegistered();
        if (isSpec) revert SpecToolNotForClaim();
        if (resultRoot == bytes32(0)) revert ResultRootRequired();
        if (!m.isDeclaredVerdictTool(originalAuditId, toolId)) revert ToolNotDeclared();

        if (fmeaRegistry != address(0)) {
            FmeaRegistry(fmeaRegistry).noteClaimClass(originalAuditId, vulnerabilityClassId);
        }

        bool witnessPath = witnessCommitment != bytes32(0);
        if (witnessPath) {
            if (invariantId == bytes32(0)) revert InvariantRequired();
            if (evaluatorToolId == bytes32(0)) revert EvaluatorRequired();
            (,, bool evalIsEval, bool evalCanon, bool evalExists) = _toolFlags(ac, evaluatorToolId);
            if (!evalExists) revert ToolNotRegistered();
            if (_toolIsSpec(ac, evaluatorToolId)) revert SpecToolNotForVerdict();
            if (!evalIsEval) revert NotInvariantEvaluator();
            if (!evalCanon) revert EvaluatorNotCanonical();
            WitnessClaimLib.Binding memory binding = WitnessClaimLib.Binding({
                evaluatorToolId: evaluatorToolId,
                invariantId: invariantId,
                locationCommitment: locationCommitment,
                witnessCommitment: witnessCommitment,
                contextRoot: contextRoot
            });
            if (!WitnessClaimLib.matchesResultRoot(
                    resultRoot, binding, artifactHash, specHash, AuditResultV1.VERDICT_FAIL
                )) revert WitnessResultRootMismatch();
        } else {
            address verifier = ac.claimVerifier();
            if (verifier != address(0)) {
                bytes32 statement = ac.claimProofStatement(originalAuditId, toolId, resultRoot);
                if (!IRunProofVerifier(verifier).verify(statement, proof)) revert ClaimProofRejected();
            }
        }

        uint256 bounty = ac.getAudit(originalAuditId).bounty;
        uint256 stakeDue = ac.requiredClaimStake(originalAuditId);
        if (stakeDue > 0) {
            m.settlementToken(0, claimant, address(0), stakeDue);
        }

        m.settlementApplyClaimFiled(
            originalAuditId,
            IClaimSettlementMutator.ClaimInput({
                claimant: claimant,
                toolId: toolId,
                proofHash: resultRoot,
                stake: stakeDue,
                witnessPath: witnessPath,
                evaluatorToolId: witnessPath ? evaluatorToolId : bytes32(0),
                invariantId: witnessPath ? invariantId : bytes32(0),
                locationCommitment: witnessPath ? locationCommitment : bytes32(0),
                witnessCommitment: witnessPath ? witnessCommitment : bytes32(0),
                contextRoot: witnessPath ? contextRoot : bytes32(0)
            })
        );
        claimProtocolDecisionDue[originalAuditId] =
            block.timestamp + _effectiveProtocolClaimDecisionWindow(ac);
        _bindAsk(m, originalAuditId, claimant, a.bountyEscrowed);
    }

    /// @dev The guards the hull's verdict path applies to the auditor in review (`submitVerdictAfterProof`), applied here
    ///      because this claim does not pass through it: the seat, the hold, the in-audit deadline, the attestation. A
    ///      declared tool's FAIL stays the verdict's (`proveFail`), so the witness is required. A re-run row is judged by
    ///      its verdict and the genesis row keeps its latch, so both are refused.
    function _requireReviewClaim(
        AuditCell ac,
        CellTypeDefs.Audit memory a,
        address claimant,
        uint256 originalAuditId,
        bytes32 witnessCommitment
    ) internal view {
        if (claimant != a.auditor || a.isClaimDispute) revert OriginalNotEligibleForClaim();
        if (ac.genesisAuditOpen() && ac.genesisAuditId() == originalAuditId) revert OriginalNotEligibleForClaim();
        if (witnessCommitment == bytes32(0)) revert ReviewClaimNeedsWitness();
        if (block.timestamp > a.pickupTime + ac.inAuditWindow()) revert ReviewWindowPassed();
        if (!a.specAuditorAttested || !ac.isEligible(claimant)) revert ReviewAuditorNotEligible();
    }

    function resolveFromDispute(uint256 originalId, uint256 disputeId) external onlyCell {
        IClaimSettlementMutator m = _mutator();
        AuditCell ac = _ac();

        CellTypeDefs.Audit memory ao = ac.getAudit(originalId);
        address origProtocol = ao.protocol;
        CellTypeDefs.AuditState state = ao.state;
        bytes32 specHash = ao.specHash;
        bytes32 artifactHash = ao.artifactHash;
        (
            address claimant,
            ,
            ,
            ,
            uint256 stake,
            bool resolved,
            bool exists,
            bool witnessPath,
            bytes32 evaluatorToolId,
            bytes32 invariantId,
            bytes32 locationCommitment,
            bytes32 witnessCommitment,
            bytes32 contextRoot
        ) = ac.vulnerabilityClaims(originalId);
        if (uint8(state) != STATE_CLAIMED) revert NotClaimed();
        if (resolved) revert ClaimAlreadyResolved();
        if (ac.activeDisputeAuditId(originalId) != disputeId) revert DisputeMismatch();

        address disputeAuditor = ac.auditAuditorOf(disputeId);
        _recordSensitiveAssignmentCompletion(claimant, origProtocol, disputeAuditor);

        m.settlementClearDispute(originalId);

        if (witnessPath) {
            _resolveWitnessDispute(
                m,
                ac,
                originalId,
                artifactHash,
                specHash,
                disputeId,
                evaluatorToolId,
                invariantId,
                locationCommitment,
                witnessCommitment,
                contextRoot
            );
            return;
        }

        (, , bytes32 proofHash, , , , , , , , , , ) = ac.vulnerabilityClaims(originalId);
        bytes32 rOrig = ac.auditProofHash(originalId);
        bytes32 rDisp = ac.auditProofHash(disputeId);
        bool passReproduces = ac.auditVerdictPass(disputeId) && rDisp == rOrig;
        bool failReproduces = !ac.auditVerdictPass(disputeId) && rDisp == proofHash;
        // PC-98 (G4(c), I4): a verdict that reproduces NEITHER side is an OUTCOME, not a revert. The revert froze the claim
        // lane for good - confirm is the only exit of a verdicted row - and the drawn re-auditor chose it by choosing the
        // root. The claim resolves unadjudicated. The verdict itself stands and its auditor was paid at confirm, exactly as
        // any unreviewed verdict is: an integrity review of the dispute row during its audit window is the check on it.
        if (!passReproduces && !failReproduces) {
            _returnAsk(m, originalId, 2);
            m.settlementResolveUnadjudicated(originalId);
            return;
        }

        if (passReproduces) {
            _returnAsk(m, originalId, 1);
            m.settlementResolveClaim(originalId, claimant, stake, true, false);
            return;
        }

        m.settlementResolveClaim(originalId, claimant, _payFinder(m, ac, originalId, disputeId, claimant), false, true);
        _recordFmeaGap(ac, originalId);
    }

    function _resolveWitnessDispute(
        IClaimSettlementMutator m,
        AuditCell ac,
        uint256 originalId,
        bytes32 artifactHash,
        bytes32 specHash,
        uint256 disputeId,
        bytes32 evaluatorToolId,
        bytes32 invariantId,
        bytes32 locationCommitment,
        bytes32 witnessCommitment,
        bytes32 contextRoot
    ) internal {
        WitnessClaimLib.Binding memory binding = WitnessClaimLib.Binding({
            evaluatorToolId: evaluatorToolId,
            invariantId: invariantId,
            locationCommitment: locationCommitment,
            witnessCommitment: witnessCommitment,
            contextRoot: contextRoot
        });
        bytes32 rDispWitness = ac.auditProofHash(disputeId);
        bool passReplay = ac.auditVerdictPass(disputeId)
            && WitnessClaimLib.matchesResultRoot(
                rDispWitness, binding, artifactHash, specHash, AuditResultV1.VERDICT_PASS
            );
        bool failReplay = !ac.auditVerdictPass(disputeId)
            && WitnessClaimLib.matchesResultRoot(
                rDispWitness, binding, artifactHash, specHash, AuditResultV1.VERDICT_FAIL
            );
        if (!passReplay && !failReplay) {
            _returnAsk(m, originalId, 2);
            m.settlementResolveUnadjudicated(originalId); // PC-98 (G4(c)), the witness path's same outcome
            return;
        }

        (address claimant, , , , uint256 stake, , , , , , , , ) = ac.vulnerabilityClaims(originalId);

        if (failReplay) {
            m.settlementResolveClaim(
                originalId, claimant, _payFinder(m, ac, originalId, disputeId, claimant), false, false
            );
            _recordFmeaGap(ac, originalId);
            return;
        }

        _returnAsk(m, originalId, 1);
        m.settlementResolveClaim(originalId, claimant, stake, true, false);
    }

    /// @inheritdoc IClaimDisputeModule
    function openDisputeReaudit(uint256 originalId, uint256 disputeBounty) external returns (uint256 disputeId) {
        AuditCell ac = _ac();
        address protocol = ac.getAudit(originalId).protocol;
        if (msg.sender != protocol) revert OnlyProtocol();
        return _openDisputeReaudit(originalId, disputeBounty, msg.sender, false);
    }

    /// @inheritdoc IClaimDisputeModule
    function protocolDeclineDisputeFunding(uint256 originalId) external {
        AuditCell ac = _ac();
        if (originalId >= ac.nextAuditId()) revert InvalidOriginalId();
        CellTypeDefs.Audit memory a = ac.getAudit(originalId);
        address protocol = a.protocol;
        CellTypeDefs.AuditState state = a.state;
        (,,,,, bool resolved, bool exists,,,,,,) = ac.vulnerabilityClaims(originalId);
        if (msg.sender != protocol) revert OnlyProtocol();
        if (uint8(state) != STATE_CLAIMED) revert OriginalNotClaimed();
        if (!exists || resolved) revert NoOpenClaim();
        if (ac.activeDisputeAuditId(originalId) != 0) revert DisputeOpen();
        if (disputeFundingDeclined[originalId]) revert AlreadyDeclined();
        disputeFundingDeclined[originalId] = true;
        emit ProtocolDeclinedDisputeFunding(originalId);
    }

    /// @inheritdoc IClaimDisputeModule
    function claimantOpenDisputeReaudit(uint256 originalId, uint256 disputeBounty)
        external
        returns (uint256 disputeId)
    {
        AuditCell ac = _ac();
        if (originalId >= ac.nextAuditId()) revert InvalidOriginalId();
        (address claimant, , , , , , , , , , , , ) = ac.vulnerabilityClaims(originalId);
        if (msg.sender != claimant) revert OnlyClaimant();
        if (!claimantDisputeLaneOpen(originalId)) revert ClaimantLaneNotOpen();
        return _openDisputeReaudit(originalId, disputeBounty, msg.sender, true);
    }

    /// @inheritdoc IClaimDisputeModule
    function claimantDisputeLaneOpen(uint256 originalId) public view returns (bool) {
        return disputeFundingDeclined[originalId]
            || block.timestamp >= claimProtocolDecisionDue[originalId];
    }

    function _openDisputeReaudit(
        uint256 originalId,
        uint256 disputeBounty,
        address funder,
        bool byClaimant
    ) internal returns (uint256 disputeId) {
        AuditCell ac = _ac();
        IClaimSettlementMutator m = _mutator();
        if (originalId >= ac.nextAuditId()) revert InvalidOriginalId();
        CellTypeDefs.Audit memory a = ac.getAudit(originalId);
        address deployed = a.deployedAddress;
        uint256 origBounty = a.bounty;
        bytes32 artifactHash = a.artifactHash;
        if (uint8(a.state) != STATE_CLAIMED) revert OriginalNotClaimed();
        (,,,,, bool resolved, bool exists,,,,,,) = ac.vulnerabilityClaims(originalId);
        if (!exists || resolved) revert NoOpenClaim();
        if (ac.activeDisputeAuditId(originalId) != 0) revert DisputeOpen();
        if (disputeSpent[originalId][funder]) revert DisputeAlreadySpent(); // PC-116
        if (deployed != address(0) && deployed.codehash != artifactHash) revert BytecodeDrift();
        uint256 minBounty = (origBounty * DISPUTE_BOUNTY_MIN_BPS) / 10_000;
        if (disputeBounty < minBounty || disputeBounty == 0) revert BountyLow();
        (, bytes32 toolId, , , , , , bool witnessPath, bytes32 evaluatorToolId, , , , ) =
            ac.vulnerabilityClaims(originalId);
        bytes32 requiredTool = witnessPath ? evaluatorToolId : toolId;
        // DEC-48: a priced claim is re-run with the finder's price on the table beside the re-run bounty; the finder's own
        // lane buys the re-run alone (`_takeAsk`).
        m.settlementToken(0, funder, address(0), disputeBounty + _takeAsk(m, ac, originalId, funder, byClaimant));
        disputeId = m.spawnDisputeReaudit(
            originalId, disputeBounty, funder, address(0), requiredTool, address(0)
        );
        if (claimAskFunded[originalId] > 0) {
            emit ClaimAskFunded(originalId, funder, claimAskFunded[originalId], disputeId);
        }
        if (byClaimant) {
            emit DisputeReauditOpenedByClaimant(originalId, disputeId);
        } else {
            emit DisputeReauditOpened(originalId, disputeId);
        }
    }

    function _effectiveProtocolClaimDecisionWindow(AuditCell ac) internal view returns (uint256) {
        if (protocolClaimDecisionWindow > 0) return protocolClaimDecisionWindow;
        return ac.protocolDecisionWindow();
    }

    /// @inheritdoc IClaimDisputeModule
    function expireDispute(uint256 originalId) external {
        IClaimSettlementMutator m = _mutator();
        AuditCell ac = _ac();
        address funder = ac.getAudit(ac.activeDisputeAuditId(originalId)).lastDiscoverer;
        m.settlementExpireClaimDispute(originalId); // reverts on no open dispute, so the mark below always has a funder
        disputeSpent[originalId][funder] = true; // PC-116
        _returnAsk(m, originalId, 3); // DEC-48: nobody adjudicated, the price goes home with the re-run bounty
    }

    /// @dev DEC-48: a FAIL that reproduces pays the finder the funded price first (the market's money, held in the cell
    ///      since the re-run was funded), then the pool's bonus. Returns the total, which the cell emits on the row.
    function _payFinder(
        IClaimSettlementMutator m,
        AuditCell ac,
        uint256 originalAuditId,
        uint256 disputeId,
        address claimant
    ) internal returns (uint256 paid) {
        uint256 ask = claimAskFunded[originalAuditId];
        if (ask > 0) {
            address funder = claimAskFunder[originalAuditId];
            claimAskFunded[originalAuditId] = 0;
            claimAskFunder[originalAuditId] = address(0);
            claimAskPaid[originalAuditId] = ask;
            m.settlementToken(1, address(0), claimant, ask);
            emit ClaimAskPaid(originalAuditId, claimant, funder, ask);
        }
        paid = ask + _payoutDiscoverer(m, ac, originalAuditId, disputeId, claimant);
    }

    function _payoutDiscoverer(
        IClaimSettlementMutator m,
        AuditCell ac,
        uint256 originalAuditId,
        uint256 disputeId,
        address claimant
    ) internal returns (uint256 paid) {
        CellTypeDefs.Audit memory a = ac.getAudit(originalAuditId);
        address auditor = a.auditor;
        uint256 bounty = a.bounty;
        CellTypeDefs.AuditState stateBeforeClaim = a.stateBeforeClaim;
        address lastDiscoverer = a.lastDiscoverer;
        uint256 boostBps = stateBeforeClaim == CellTypeDefs.AuditState.InAudit
            ? 10_000
            : ac.auditorReputationBoostBps(
                lastDiscoverer != address(0) ? lastDiscoverer : auditor
            );
        bool bountyPotLocked = stateBeforeClaim == CellTypeDefs.AuditState.AwaitingWindow
            || stateBeforeClaim == CellTypeDefs.AuditState.InAudit;
        uint256 escrowDraw;
        if (bountyPotLocked) {
            // The pot is still in the cell: the posted bounty prices the finding and the boost draws on the pool as before.
            escrowDraw = (bounty * boostBps) / 10_000;
        } else {
            // DEC-48: the bounty went to the auditor at confirm and the market (the ask, `_payFinder`) prices the finding.
            // The pool adds the reputation boost alone: keyed to the posted bounty and never to the ask, never above half
            // the re-run bounty (`BONUS_RERUN_CAP_BPS`), and never above what the pool holds now. Best-effort, no debt.
            escrowDraw = (bounty * (boostBps - 10_000)) / 10_000;
            uint256 rerunCap = (ac.getAudit(disputeId).bounty * BONUS_RERUN_CAP_BPS) / 10_000;
            if (escrowDraw > rerunCap) escrowDraw = rerunCap;
            address pool = ac.treasuryEscrow();
            uint256 held = pool == address(0) ? 0 : IPayoutEscrow(pool).escrowBalance();
            if (escrowDraw > held) escrowDraw = held;
        }
        if (escrowDraw > 0) {
            paid = m.settlementPayDiscoverer(originalAuditId, claimant, escrowDraw, bountyPotLocked, bounty);
        }
    }

    // ---- DEC-48: the finder's price ---------------------------------------------------------------------------------

    /// @notice Name the price you will ask for a hole in `originalId`, before you file the claim. Binds at your filing.
    ///         Only on a row whose bounty already left the cell (confirmed); a pre-confirm claim is priced by the bounty.
    ///         Naming 0 clears a pending price.
    function nameClaimAsk(uint256 originalId, uint256 ask) external {
        AuditCell ac = _ac();
        if (originalId >= ac.nextAuditId()) revert InvalidOriginalId();
        CellTypeDefs.Audit memory a = ac.getAudit(originalId);
        if (!_claimEligible(a.state) || a.bountyEscrowed) revert AskNotAllowedHere();
        pendingAsk[originalId][msg.sender] = ask;
    }

    /// @notice Lower the bound price of your open claim while nobody has funded it. Never raise it: a price that came
    ///         down is a signal, a price that went up after a bid would be a trap.
    function lowerClaimAsk(uint256 originalId, uint256 newAsk) external {
        AuditCell ac = _ac();
        if (originalId >= ac.nextAuditId()) revert InvalidOriginalId();
        (address claimant, , , , , bool resolved, bool exists, , , , , , ) = ac.vulnerabilityClaims(originalId);
        if (!exists || resolved) revert NoOpenClaim();
        if (msg.sender != claimant) revert OnlyClaimant();
        uint256 ask = claimAsk[originalId];
        if (ask == 0) revert AskNotOpen();
        if (claimAskFunded[originalId] != 0) revert AskAlreadyFunded();
        if (ac.activeDisputeAuditId(originalId) != 0) revert DisputeOpen();
        if (newAsk >= ask) revert AskNotLower();
        claimAsk[originalId] = newAsk;
        emit ClaimAskNamed(originalId, claimant, newAsk);
    }

    /// @notice Anyone funds the re-run and puts the finder's price beside it, once the protocol has declined or its window
    ///         has closed. The protocol may use it too, late. On a FAIL that reproduces the price goes to the finder; on
    ///         every other exit it comes back. PC-116 applies to the funder.
    function fundClaimAsk(uint256 originalId, uint256 disputeBounty) external returns (uint256 disputeId) {
        if (claimAsk[originalId] == 0 || !claimantDisputeLaneOpen(originalId)) revert AskNotOpen();
        return _openDisputeReaudit(originalId, disputeBounty, msg.sender, false);
    }

    /// @notice Return a funded price that no exit of this module moved: the row or its re-run was ended by another lane
    ///         (a void through the integrity overlay or the spec arbiter), or the claim lapsed. Permissionless; pays the
    ///         recorded funder only. Refused while the funded re-run is still running.
    function reclaimClaimAsk(uint256 originalId) external {
        IClaimSettlementMutator m = _mutator();
        AuditCell ac = _ac();
        if (claimAskFunded[originalId] == 0) revert NothingToReclaim();
        (, , , , , bool resolved, bool exists, , , , , , ) = ac.vulnerabilityClaims(originalId);
        if (exists && !resolved && ac.activeDisputeAuditId(originalId) != 0) revert DisputeOpen();
        _returnAsk(m, originalId, 4);
    }

    /// @notice The row's price, for anyone: what was asked, who funded it, what is held, what the last FAIL paid.
    function claimAskStatus(uint256 originalId)
        external
        view
        returns (uint256 ask, address funder, uint256 funded, uint256 paid)
    {
        return (claimAsk[originalId], claimAskFunder[originalId], claimAskFunded[originalId], claimAskPaid[originalId]);
    }

    /// @dev At filing: a price left behind by a previous claim on the row goes home, the pending price binds when the
    ///      bounty is no longer escrowed, and a pending price on an escrowed row is dropped (the filing goes through
    ///      unpriced; `nameClaimAsk` refuses such a row, this guards the window between naming and filing).
    function _bindAsk(IClaimSettlementMutator m, uint256 originalId, address claimant, bool potEscrowed) internal {
        if (claimAskFunded[originalId] > 0) _returnAsk(m, originalId, 4);
        claimAsk[originalId] = 0;
        claimAskPaid[originalId] = 0;
        uint256 ask = pendingAsk[originalId][claimant];
        if (ask == 0) return;
        delete pendingAsk[originalId][claimant];
        if (potEscrowed) return;
        claimAsk[originalId] = ask;
        emit ClaimAskNamed(originalId, claimant, ask);
    }

    /// @dev At funding: the extra the funder puts in beside the re-run bounty. A stale funded price goes home first
    ///      (its re-run was ended by another lane). The finder's own lane funds nothing beyond the re-run and kills
    ///      the price for this claim, on the row for anyone to read.
    function _takeAsk(IClaimSettlementMutator m, AuditCell ac, uint256 originalId, address funder, bool byClaimant)
        internal
        returns (uint256 extra)
    {
        if (claimAskFunded[originalId] > 0) _returnAsk(m, originalId, 4);
        uint256 ask = claimAsk[originalId];
        if (ask == 0) return 0;
        if (byClaimant) {
            (address claimant, , , , , , , , , , , , ) = ac.vulnerabilityClaims(originalId);
            claimAsk[originalId] = 0;
            emit ClaimAskUnfunded(originalId, claimant, ask);
            return 0;
        }
        claimAskFunded[originalId] = ask;
        claimAskFunder[originalId] = funder;
        return ask;
    }

    function _returnAsk(IClaimSettlementMutator m, uint256 originalId, uint8 reason) internal {
        uint256 ask = claimAskFunded[originalId];
        if (ask == 0) return;
        address funder = claimAskFunder[originalId];
        claimAskFunded[originalId] = 0;
        claimAskFunder[originalId] = address(0);
        m.settlementToken(1, address(0), funder, ask);
        emit ClaimAskReturned(originalId, funder, ask, reason);
    }

    function _claimEligible(CellTypeDefs.AuditState s) internal pure returns (bool) {
        return s == CellTypeDefs.AuditState.AwaitingWindow || s == CellTypeDefs.AuditState.Audited
            || s == CellTypeDefs.AuditState.InBlock;
    }

    function _toolFlags(AuditCell ac, bytes32 toolId)
        internal
        view
        returns (address proposer, bool isSpec, bool isEvaluator, bool canonical, bool exists)
    {
        (proposer, isSpec, isEvaluator, canonical, exists, , ) = ac.tools(toolId);
    }

    function _toolIsSpec(AuditCell ac, bytes32 toolId) internal view returns (bool) {
        (, bool isSpec, , , , , ) = ac.tools(toolId);
        return isSpec;
    }

    function claimantDyadExclusionActive(uint256 queueLength) public view returns (bool) {
        return claimantDyadExclusionEnabled && queueLength >= claimantDyadExclusionMinQueue;
    }

    function disputeCandidateBlocked(
        address claimant,
        address protocol,
        address auditor,
        uint256 queueLength
    ) external view returns (bool blocked) {
        if (!claimantDyadExclusionActive(queueLength)) return false;
        if (_isClaimantDyadBlocked(claimant, auditor)) return true;
        return _isTriangleBlocked(claimant, protocol, auditor);
    }

    function _recordSensitiveAssignmentCompletion(address claimant, address protocol, address auditor)
        internal
    {
        claimantAuditorCompleted[claimant][auditor] += 1;
        claimantProtocolAuditorTriangle[claimant][protocol][auditor] += 1;
    }

    function _isClaimantDyadBlocked(address claimant, address auditor) internal view returns (bool) {
        uint256 completed = claimantAuditorCompleted[claimant][auditor];
        if (completed == 0) return false;
        if (maxClaimantDyadRepeats == 0) return true;
        return completed > maxClaimantDyadRepeats;
    }

    function _isTriangleBlocked(address claimant, address protocol, address auditor) internal view returns (bool) {
        uint256 completed = claimantProtocolAuditorTriangle[claimant][protocol][auditor];
        if (completed == 0) return false;
        if (maxTriangleRepeats == 0) return true;
        return completed > maxTriangleRepeats;
    }

    function setClaimantDyadExclusionEnabled(bool v) external onlyAdmin {
        claimantDyadExclusionEnabled = v;
        emit ParameterUpdated("claimantDyadExclusionEnabled", v ? 1 : 0);
    }

    function setClaimantDyadExclusionMinQueue(uint256 v) external onlyAdmin {
        claimantDyadExclusionMinQueue = v;
        emit ParameterUpdated("claimantDyadExclusionMinQueue", v);
    }

    function setMaxClaimantDyadRepeats(uint256 v) external onlyAdmin {
        maxClaimantDyadRepeats = v;
        emit ParameterUpdated("maxClaimantDyadRepeats", v);
    }

    function setMaxTriangleRepeats(uint256 v) external onlyAdmin {
        maxTriangleRepeats = v;
        emit ParameterUpdated("maxTriangleRepeats", v);
    }

    function setProtocolClaimDecisionWindow(uint256 v) external onlyAdmin {
        protocolClaimDecisionWindow = v;
        emit ParameterUpdated("protocolClaimDecisionWindow", v);
    }

    function _recordFmeaGap(AuditCell ac, uint256 originalId) internal {
        if (fmeaRegistry == address(0)) return;
        bytes32 specToolId = ac.getAudit(originalId).specToolId;
        FmeaRegistry(fmeaRegistry).recordClaimGap(originalId, specToolId);
    }
}

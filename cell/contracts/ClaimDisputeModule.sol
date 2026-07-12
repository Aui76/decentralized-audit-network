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

    uint256 internal constant DISPUTE_BOUNTY_MIN_BPS = 5000;

    /// @dev F-80: protocol decline + claimant-funded dispute lane.
    mapping(uint256 => bool) public disputeFundingDeclined;
    mapping(uint256 => uint256) public claimProtocolDecisionDue;
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
        if (!_claimEligible(a.state)) revert OriginalNotEligibleForClaim();
        bytes32 specHash = a.specHash;
        bytes32 artifactHash = a.artifactHash;

        (, , , , , bool resolved, bool exists, , , , , , ) = ac.vulnerabilityClaims(originalAuditId);
        if (exists) revert ClaimAlreadyFiled();

        address protocol = a.protocol;
        address auditor = a.auditor;
        (,,, uint256 claimantPosition,,) = ac.auditors(claimant);
        if (claimantPosition == 0) revert ClaimantNotRegistered();
        if (claimant == protocol) revert ClaimantCannotBeProtocol();
        if (claimant == auditor) revert ClaimantCannotBeOriginalAuditor();

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
        if (!passReproduces && !failReproduces) revert DisputeNoReproduce();

        if (passReproduces) {
            m.settlementResolveClaim(originalId, claimant, stake, true, false);
            return;
        }

        m.settlementResolveClaim(originalId, claimant, _payoutDiscoverer(m, ac, originalId, claimant), false, true);
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
        if (!passReplay && !failReplay) revert DisputeWitnessMismatch();

        (address claimant, , , , uint256 stake, , , , , , , , ) = ac.vulnerabilityClaims(originalId);

        if (failReplay) {
            m.settlementResolveClaim(originalId, claimant, _payoutDiscoverer(m, ac, originalId, claimant), false, false);
            _recordFmeaGap(ac, originalId);
            return;
        }

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
        if (deployed != address(0) && deployed.codehash != artifactHash) revert BytecodeDrift();
        uint256 minBounty = (origBounty * DISPUTE_BOUNTY_MIN_BPS) / 10_000;
        if (disputeBounty < minBounty || disputeBounty == 0) revert BountyLow();
        (, bytes32 toolId, , , , , , bool witnessPath, bytes32 evaluatorToolId, , , , ) =
            ac.vulnerabilityClaims(originalId);
        bytes32 requiredTool = witnessPath ? evaluatorToolId : toolId;
        m.settlementToken(0, funder, address(0), disputeBounty);
        disputeId = m.spawnDisputeReaudit(
            originalId, disputeBounty, funder, address(0), requiredTool, address(0)
        );
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
        _mutator().settlementExpireClaimDispute(originalId);
    }

    function _payoutDiscoverer(
        IClaimSettlementMutator m,
        AuditCell ac,
        uint256 originalAuditId,
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
        uint256 escrowDraw = (bounty * boostBps) / 10_000;
        bool bountyPotLocked = stateBeforeClaim == CellTypeDefs.AuditState.AwaitingWindow
            || stateBeforeClaim == CellTypeDefs.AuditState.InAudit;
        if (escrowDraw > 0) {
            paid = m.settlementPayDiscoverer(originalAuditId, claimant, escrowDraw, bountyPotLocked, bounty);
        }
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

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./CellStorage.sol";
import "./CellLogicLib.sol";
import "./IClaimSettlementMutator.sol";
import "./IClaimDisputeModule.sol";
import "./IDisputeResolver.sol";
import "./DiscovererPayoutLib.sol";
import "./SubmitAuditLib.sol";

interface IIntegrityReviewGate {
    function confirmBlocked(uint256 auditId) external view returns (bool);
}

interface ISpecChallengeGate {
    function challengeActive(uint256 auditId) external view returns (bool);
}

interface IStructuralCellHook {
    /// @param phase 1 = provePass gate, 2 = proveFail gate.
    function onStructuralCellHook(uint8 phase, uint256 id, bytes32 tool) external;
}

interface IStructuralKind {
    function isStructuralAudit(uint256 auditId) external view returns (bool);
}

/// @title AuditCell — minimal settlement core (puzzle bench).

interface IAuditToken {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface ITreasuryEscrow {
    function recordDeposit(uint256 amount) external;
    function recordSlash(uint256 amount) external;
    function escrowBalance() external view returns (uint256);
    function payDiscoverer(address recipient, uint256 amount, uint256 maxIterations) external returns (uint256);
}

interface IIssuanceModule {
    function settlePositiveBlock(uint256 id, address auditor)
        external
        returns (uint256 auditorMinted, uint256 treasuryMinted, uint256 reward);
    function mintUpgradeAdopt(address to) external returns (uint256);
}

/// @dev G-01: mutual bind with CellEscrow.network().
interface ICellEscrowNetworkBinding {
    function network() external view returns (address);
}

contract AuditCell is CellTypeDefs, IClaimSettlementMutator {
    uint256 public constant MIN_AUDIT_WINDOW = 10 minutes;
    uint256 public constant MAX_AUDIT_WINDOW = 30 days;
    uint256 public constant MIN_CLAIM_RESOLUTION_WINDOW = 10 minutes;
    uint256 public constant MAX_CLAIM_RESOLUTION_WINDOW = 90 days;
    uint256 public constant MAX_CLAIM_FILING_STAKE = 10_000 ether;
    uint256 public constant PAY_DISCOVERER_MAX_ITERATIONS = 512;
    uint256 public constant MAX_DECLARED_VERDICT_TOOLS = 4;

    event AuditorRegistered(address indexed auditor, uint256 position);
    event AuditorRejoined(address indexed auditor);
    event ToolRegistered(bytes32 indexed toolId, address indexed proposer, bool isSpecValidationTool);
    event AuditSubmitted(
        uint256 indexed id,
        address indexed protocol,
        address indexed deployedAddress,
        uint256 bounty,
        bytes32 artifactHash,
        bytes32 specToolId,
        bytes32 specPassDigest
    );
    event AuditCasePinned(
        uint256 indexed auditId,
        bytes32 indexed caseRoot,
        bytes32 specHash,
        bytes32 artifactHash,
        uint256 linkedAuditId,
        bool isVulnerabilityReport,
        bool isClaimDispute,
        uint256 supersedesAuditId
    );
    event AuditStateChanged(
        uint256 indexed auditId,
        bytes32 indexed caseRoot,
        AuditState from,
        AuditState to
    );
    event AuditAssigned(uint256 indexed id, address indexed auditor);
    event AuditAwaitingAssignment(uint256 indexed id);
    event ProtocolAuditorAccepted(uint256 indexed id, address indexed auditor);
    event ProtocolAuditorRejected(uint256 indexed id, address indexed auditor);
    event ProtocolDecisionTimedOut(uint256 indexed id, address indexed auditor);
    event AuditAccepted(uint256 indexed id, address indexed auditor);
    event AuditDeclined(uint256 indexed id, address indexed auditor);
    event AuditTimedOut(uint256 indexed id, address indexed auditor, uint256 timeoutStreak);
    event AuditorPushedOut(address indexed auditor);
    event VerdictSubmitted(uint256 indexed id, bool pass, bytes32 indexed toolId, bytes32 proofHash);
    event VulnerabilityClaimed(
        uint256 indexed id, address indexed claimant, bytes32 indexed toolId, bytes32 proofHash, uint256 stake
    );
    event AuditConfirmed(uint256 indexed id);
    event PositiveBlockMinted(uint256 indexed height, uint256 indexed auditId, uint256 reward, bytes32 blockHash);
    event DiscovererPayoutResolved(
        uint256 indexed originalAuditId, address indexed claimant, address indexed boostSubject, uint256 paid
    );
    event OriginalAuditExploited(
        uint256 indexed originalAuditId, address indexed discoverer, uint256 amountPaid, address fixSubmitter
    );
    event ClaimExpired(uint256 indexed originalAuditId, address indexed claimant, uint256 amountPaid);
    event ClaimVindicated(uint256 indexed originalAuditId, address indexed claimant, uint256 stakeSlashed);
    event DisputeReauditOpened(uint256 indexed originalAuditId, uint256 indexed disputeAuditId);
    event DisputeExpired(uint256 indexed originalAuditId, uint256 indexed disputeAuditId);
    event PositiveBlockSupplyExhausted(uint256 indexed height, uint256 indexed auditId);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event ParameterUpdated(string indexed name, uint256 value);
    event DisputeModuleSet(uint8 indexed which, address indexed module);
    event AssignmentModuleSet(address indexed module);
    event EntropyProviderSet(address indexed provider);
    event EntropyProviderLocked();
    event IncrementLocked();
    event MaxBountyPerSubmitLocked();
    event SpecInvalidated(uint256 indexed auditId, address indexed challenger, bytes32 indexed specToolId);

    error ArtifactAlreadyAudited(uint256 existingAuditId);
    error CaseAlreadyAudited(uint256 existingAuditId);
    error DeclaredToolInvalid();
    error ToolNotDeclared();
    error TransferFailed();
    error NotClaimed();
    error NoClaimRecord();
    error ClaimAlreadyResolved();
    error DisputeOpen();
    error ResolutionWindowActive();
    error NoOpenDispute();
    error DisputeVerdicted();
    error DisputeWindowActive();
    error DisputeMismatch();
    error InvalidOriginalId();
    error OriginalNotClaimed();
    error NoOpenClaim();
    error OnlyProtocol();
    error BytecodeDrift();
    error BountyLow();
    error DisputeBountyEscrowFailed();
    error NotAwaiting();
    error AuditWindowOpen();
    error AlreadyAccepted();
    error AlreadyInQueue();
    error AlreadyLocked();
    error AuditWindowOutOfBounds();
    error BountyEscrowFailed();
    error BountyPayoutFailed();
    error BountyRequired();
    error GenesisAuditOpen();
    error GenesisNotPending();
    error BountyExceedsCap();
    error IncrementLockedErr();
    error MaxBountyLocked();
    error ParamLockedErr();
    error ClaimAlreadyExists();
    error ClaimVerifierLocked();
    error ClaimStakeTooLarge();
    error ClaimWindowOutOfBounds();
    error DecisionWindowNotPassed();
    error DecisionWindowPassed();
    error DeployedAddressRequired();
    error DisputeToolMismatch();
    error EmptyBytecode();
    error ArtifactHashMismatch();
    error EscrowBoundElsewhere();
    error FixAuditAlreadyOpen();
    error InAuditWindowActive();
    error InsufficientHold();
    error InvalidLinkedAuditId();
    error IssuanceLocked();
    error IssuanceUnset();
    error LinkedClaimResolved();
    error LinkedNotClaimed();
    error NoAudit();
    error NoClaimOnLinked();
    error NoContractAtAddress();
    error NotAdmin();
    error NotAssigned();
    error NotAssignedAuditor();
    error NotAuditor();
    error NotAwaitingAcceptance();
    error NotInAudit();
    error NotInDecisionWindow();
    error NotSpecValidationTool();
    error ProtocolNotAcceptedAssignment();
    error ProtocolWindowActive();
    error ReentrantCall();
    error ResultRootRequired();
    error SelfAuditDisallowed();
    error SingleToolPerVerdict();
    error SkipsProtocolGate();
    error SpecNotAttested();
    error SpecRunMismatch();
    error SpecToolNotForVerdict();
    error SpecToolNotRegistered();
    error SpecToolRequired();
    error SupersedesMustBeNewCaseRoot();
    error SupersedesPriorMustBeOrdinary();
    error SupersedesSameORequired();
    error SupersedesSameProtocolOnly();
    error InvalidSupersedesAuditId();
    error StakeTransferFailed();
    error ToolAlreadyRegistered();
    error ToolNotRegistered();
    error TreasuryAlreadySet();
    error VerifierUnset();
    error WrongState();
    error ZeroAdmin();
    error ZeroCodeHash();
    error ZeroEscrow();
    error ZeroSpecHash();
    error ZeroToken();
    error SpecChallengeActive();
    error IntegrityReviewActive();
    error NotStructuralModule();

    error ProtocolDisputeDecisionPending();

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus = _NOT_ENTERED;

    modifier onlyAdmin() {
        if (!(msg.sender == CellStorage.layout().admin)) revert NotAdmin();
        _;
    }

    modifier nonReentrant() {
        if (!(_reentrancyStatus != _ENTERED)) revert ReentrantCall();
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    modifier onlyStructuralModule() {
        if (msg.sender != CellStorage.layout().structuralUpgradeModule) revert NotStructuralModule();
        _;
    }

    constructor(address _token) {
        if (!(_token != address(0))) revert ZeroToken();
        CellStorage.Layout storage L = CellStorage.layout();
        L.token = IAuditTokenStorage(_token);
        L.admin = msg.sender;
        L.increment = 0;
        L.maxBountyPerSubmit = 10_000_000 ether;
        L.currentBlockSize = 1;
        L.canonicalThreshold = 10;
        L.minAuditWindow = 14 days;
        L.decisionWindow = 1 days;
        L.protocolDecisionWindow = 2 days;
        L.claimResolutionWindow = 30 days;
        L.claimFilingStake = 100 ether;
        L.claimStakeBps = 2000;
        L.inAuditWindow = 7 days;
        L.pushOutThreshold = 3;
        L.maxBoostFactor = 4;
        L.discoveryCapBps = 500;
        L.discoveryFloorBps = 5000;
        L.genesisPending = true;
    }

    // --------------------------------------------------------- public getters

    function token() external view returns (IAuditToken) {
        return IAuditToken(address(CellStorage.layout().token));
    }

    function admin() external view returns (address) {
        return CellStorage.layout().admin;
    }

    function treasuryEscrow() external view returns (address) {
        return CellStorage.layout().treasuryEscrow;
    }

    function claimVerifier() external view returns (address) {
        return CellStorage.layout().claimVerifier;
    }

    function claimVerifierLocked() external view returns (bool) {
        return CellStorage.layout().claimVerifierLocked;
    }

    function issuanceModule() external view returns (address) {
        return CellStorage.layout().issuanceModule;
    }

    function assignmentModule() external view returns (address) {
        return CellStorage.layout().assignmentModule;
    }

    function entropyProvider() external view returns (address) {
        return CellStorage.layout().entropyProvider;
    }

    function entropyProviderLocked() external view returns (bool) {
        return CellStorage.layout().entropyProviderLocked;
    }

    function nextAuditId() external view returns (uint256) {
        return CellStorage.layout().nextAuditId;
    }

    function auditorCount() external view returns (uint256) {
        return CellStorage.layout().auditorCount;
    }

    function activeFixAuditId(uint256 id) external view returns (uint256) {
        return CellStorage.layout().activeFixAuditId[id];
    }

    function activeDisputeAuditId(uint256 id) external view returns (uint256) {
        return CellStorage.layout().activeDisputeAuditId[id];
    }

    function auditVerdictPass(uint256 id) external view returns (bool) {
        return CellStorage.layout().auditVerdictPass[id];
    }

    function artifactRegistered(bytes32 h) external view returns (bool) {
        return CellStorage.layout().artifactRegistered[h];
    }

    function artifactToAuditId(bytes32 h) external view returns (uint256) {
        return CellStorage.layout().artifactToAuditId[h];
    }

    function caseRootRegistered(bytes32 h) external view returns (bool) {
        return CellStorage.layout().caseRootRegistered[h];
    }

    function caseRootToAuditId(bytes32 h) external view returns (uint256) {
        return CellStorage.layout().caseRootToAuditId[h];
    }

    function queueHead() external view returns (address) {
        return CellStorage.layout().queueHead;
    }

    function queueLength() external view returns (uint256) {
        return CellStorage.layout().queueLength;
    }

    function queueNext(address a) external view returns (address) {
        return CellStorage.layout().queueNext[a];
    }

    function blockHeight() external view returns (uint256) {
        return CellStorage.layout().blockHeight;
    }

    function totalSuccessfulAudits() external view returns (uint256) {
        return CellStorage.layout().totalSuccessfulAudits;
    }

    function genesisPending() external view returns (bool) {
        return CellStorage.layout().genesisPending;
    }

    function genesisAuditOpen() external view returns (bool) {
        return CellStorage.layout().genesisAuditOpen;
    }

    function genesisAuditId() external view returns (uint256) {
        return CellStorage.layout().genesisAuditId;
    }

    function latestBlockHash() external view returns (bytes32) {
        return CellStorage.layout().latestBlockHash;
    }

    function auditBlockRewardMinted(uint256 id) external view returns (uint256) {
        return CellStorage.layout().auditBlockRewardMinted[id];
    }

    function auditPositiveBlock(uint256 id) external view returns (uint256) {
        return CellStorage.layout().auditPositiveBlock[id];
    }

    function auditProofHash(uint256 id) external view returns (bytes32) {
        return CellStorage.layout().auditProofHash[id];
    }

    function auditVerdictToolId(uint256 id) external view returns (bytes32) {
        return CellStorage.layout().auditVerdictToolId[id];
    }

    function increment() external view returns (uint256) {
        return CellStorage.layout().increment;
    }

    function incrementLocked() external view returns (bool) {
        return CellStorage.layout().incrementLocked;
    }

    function maxBountyPerSubmit() external view returns (uint256) {
        return CellStorage.layout().maxBountyPerSubmit;
    }

    function maxBountyPerSubmitLocked() external view returns (bool) {
        return CellStorage.layout().maxBountyPerSubmitLocked;
    }

    function currentBlockSize() external view returns (uint256) {
        return CellStorage.layout().currentBlockSize;
    }

    function canonicalThreshold() external view returns (uint256) {
        return CellStorage.layout().canonicalThreshold;
    }

    function minAuditWindow() external view returns (uint256) {
        return CellStorage.layout().minAuditWindow;
    }

    function auditWindowOf(uint256 id) external view returns (uint256) {
        return CellStorage.layout().audits[id].auditWindow;
    }

    function decisionWindow() external view returns (uint256) {
        return CellStorage.layout().decisionWindow;
    }

    function protocolDecisionWindow() external view returns (uint256) {
        return CellStorage.layout().protocolDecisionWindow;
    }

    function claimResolutionWindow() external view returns (uint256) {
        return CellStorage.layout().claimResolutionWindow;
    }

    function claimFilingStake() external view returns (uint256) {
        return CellStorage.layout().claimFilingStake;
    }

    function claimStakeBps() external view returns (uint256) {
        return CellStorage.layout().claimStakeBps;
    }

    function auditBountyEscrowed(uint256 auditId) external view returns (bool) {
        return CellStorage.layout().audits[auditId].bountyEscrowed;
    }

    function requiredClaimStake(uint256 auditId) external view returns (uint256) {
        return CellLogicLib.requiredClaimStakeView(auditId);
    }

    function inAuditWindow() external view returns (uint256) {
        return CellStorage.layout().inAuditWindow;
    }

    function pushOutThreshold() external view returns (uint256) {
        return CellStorage.layout().pushOutThreshold;
    }

    function maxBoostFactor() external view returns (uint256) {
        return CellStorage.layout().maxBoostFactor;
    }

    function discoveryCapBps() external view returns (uint256) {
        return CellStorage.layout().discoveryCapBps;
    }

    function discoveryFloorBps() external view returns (uint256) {
        return CellStorage.layout().discoveryFloorBps;
    }

    function audits(uint256 id)
        external
        view
        returns (
            address protocol,
            address auditor,
            address deployedAddress,
            uint256 bounty,
            uint256 windowStart,
            AuditState state,
            bytes32 specHash,
            bytes32 artifactHash,
            bytes32 specToolId,
            bytes32 specPassDigest,
            bool specAuditorAttested,
            uint256 pickupTime,
            bool isVulnerabilityReport,
            bool isClaimDispute,
            uint256 linkedAuditId,
            AuditState stateBeforeClaim,
            address lastDiscoverer,
            bool protocolApprovedAssignment,
            bytes32 caseRoot,
            uint256 supersedesAuditId
        )
    {
        Audit storage a = CellStorage.layout().audits[id];
        return (
            a.protocol,
            a.auditor,
            a.deployedAddress,
            a.bounty,
            a.windowStart,
            a.state,
            a.specHash,
            a.artifactHash,
            a.specToolId,
            a.specPassDigest,
            a.specAuditorAttested,
            a.pickupTime,
            a.isVulnerabilityReport,
            a.isClaimDispute,
            a.linkedAuditId,
            a.stateBeforeClaim,
            a.lastDiscoverer,
            a.protocolApprovedAssignment,
            a.caseRoot,
            a.supersedesAuditId
        );
    }

    function auditors(address addr)
        external
        view
        returns (uint256 successful, uint256 failed, uint256 found, uint256 position, uint256 timeoutStreak, bool inQueue)
    {
        AuditorRecord storage r = CellStorage.layout().auditors[addr];
        return (r.successful, r.failed, r.found, r.position, r.timeoutStreak, r.inQueue);
    }

    function tools(bytes32 toolId)
        external
        view
        returns (
            address proposer,
            bool isSpecValidationTool,
            bool isInvariantEvaluator,
            bool canonical,
            bool exists,
            uint256 successfulUses,
            uint256 failedUses
        )
    {
        Tool storage t = CellStorage.layout().tools[toolId];
        return (
            t.proposer,
            t.isSpecValidationTool,
            t.isInvariantEvaluator,
            t.canonical,
            t.exists,
            t.successfulUses,
            t.failedUses
        );
    }

    function vulnerabilityClaims(uint256 id)
        external
        view
        returns (
            address claimant,
            bytes32 toolId,
            bytes32 proofHash,
            uint256 claimTimestamp,
            uint256 stake,
            bool resolved,
            bool exists,
            bool witnessPath,
            bytes32 evaluatorToolId,
            bytes32 invariantId,
            bytes32 locationCommitment,
            bytes32 witnessCommitment,
            bytes32 contextRoot
        )
    {
        VulnerabilityClaim storage c = CellStorage.layout().vulnerabilityClaims[id];
        return (
            c.claimant,
            c.toolId,
            c.proofHash,
            c.claimTimestamp,
            c.stake,
            c.resolved,
            c.exists,
            c.witnessPath,
            c.evaluatorToolId,
            c.invariantId,
            c.locationCommitment,
            c.witnessCommitment,
            c.contextRoot
        );
    }

    // -------------------------------------------------------------- admin

    function paramLocked(uint8 id) external view returns (bool) {
        return CellLogicLib.paramLockedExt(id);
    }

    function lockParam(uint8 id) external {
        CellLogicLib.lockParamExt(id);
    }

    function setParam(uint8 id, uint256 v) external {
        CellLogicLib.setParamExt(id, v);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(newAdmin != address(0))) revert ZeroAdmin();
        emit AdminTransferred(L.admin, newAdmin);
        L.admin = newAdmin;
    }

    function setTreasuryEscrow(address _escrow) external onlyAdmin {
        CellStorage.Layout storage L = CellStorage.layout();
        if ((L.paramLocked & (uint256(1) << 7)) != 0) revert ParamLockedErr();
        if (!(L.treasuryEscrow == address(0))) revert TreasuryAlreadySet();
        if (!(_escrow != address(0))) revert ZeroEscrow();
        address bound = ICellEscrowNetworkBinding(_escrow).network();
        if (!(bound == address(0) || bound == address(this))) revert EscrowBoundElsewhere();
        L.treasuryEscrow = _escrow;
        emit ParameterUpdated("treasuryEscrow", uint256(uint160(_escrow)));
    }

    function setClaimVerifier(address v) external onlyAdmin {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(!L.claimVerifierLocked)) revert ClaimVerifierLocked();
        L.claimVerifier = v;
        emit ParameterUpdated("claimVerifier", uint256(uint160(v)));
    }

    function lockClaimVerifier() external onlyAdmin {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(L.claimVerifier != address(0))) revert VerifierUnset();
        if (!(!L.claimVerifierLocked)) revert AlreadyLocked();
        L.claimVerifierLocked = true;
    }

    function setIssuanceModule(address m) external onlyAdmin {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(!L.issuanceModuleLocked)) revert IssuanceLocked();
        L.issuanceModule = m;
        emit ParameterUpdated("issuanceModule", uint256(uint160(m)));
    }

    function lockIssuanceModule() external onlyAdmin {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(L.issuanceModule != address(0))) revert IssuanceUnset();
        if (!(!L.issuanceModuleLocked)) revert AlreadyLocked();
        L.issuanceModuleLocked = true;
    }

    function setDisputeModule(uint8 which, address m) external onlyAdmin {
        CellStorage.Layout storage L = CellStorage.layout();
        if ((L.paramLocked & (uint256(1) << 6)) != 0) revert ParamLockedErr();
        if (which == 0) L.claimDisputeModule = m;
        else if (which == 1) L.specGapModule = m;
        else if (which == 2) L.specArbiterModule = m;
        else if (which == 3) L.integrityReviewModule = m;
        else if (which == 4) L.structuralUpgradeModule = m;
        else revert NotAdmin();
        emit DisputeModuleSet(which, m);
    }

    function setAssignmentModule(address m) external onlyAdmin {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(!L.assignmentModuleLocked)) revert IssuanceLocked();
        L.assignmentModule = m;
        emit ParameterUpdated("assignmentModule", uint256(uint160(m)));
        emit AssignmentModuleSet(m);
    }

    function lockAssignmentModule() external onlyAdmin {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(L.assignmentModule != address(0))) revert IssuanceUnset();
        if (!(!L.assignmentModuleLocked)) revert AlreadyLocked();
        L.assignmentModuleLocked = true;
    }

    function setEntropyProvider(address provider) external onlyAdmin {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(!L.entropyProviderLocked)) revert AlreadyLocked();
        L.entropyProvider = provider;
        emit EntropyProviderSet(provider);
    }

    function lockEntropyProvider() external onlyAdmin {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(!L.entropyProviderLocked)) revert AlreadyLocked();
        L.entropyProviderLocked = true;
        emit EntropyProviderLocked();
    }

    function setIncrement(uint256 v) external onlyAdmin {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(!L.incrementLocked)) revert IncrementLockedErr();
        L.increment = v;
        emit ParameterUpdated("increment", v);
    }

    function lockIncrement() external onlyAdmin {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(!L.incrementLocked)) revert AlreadyLocked();
        L.incrementLocked = true;
        emit IncrementLocked();
    }

    function setMaxBountyPerSubmit(uint256 v) external onlyAdmin {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(!L.maxBountyPerSubmitLocked)) revert MaxBountyLocked();
        if (!(v > 0)) revert BountyRequired();
        L.maxBountyPerSubmit = v;
        emit ParameterUpdated("maxBountyPerSubmit", v);
    }

    function lockMaxBountyPerSubmit() external onlyAdmin {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(!L.maxBountyPerSubmitLocked)) revert AlreadyLocked();
        L.maxBountyPerSubmitLocked = true;
        emit MaxBountyPerSubmitLocked();
    }

    function setToolWitnessFlags(bytes32 toolId, bool isEvaluator, bool canonical) external onlyAdmin {
        CellStorage.Layout storage L = CellStorage.layout();
        Tool storage t = L.tools[toolId];
        if (!(t.exists)) revert ToolNotRegistered();
        if (t.isSpecValidationTool) revert SpecToolNotForVerdict();
        t.isInvariantEvaluator = isEvaluator;
        t.canonical = canonical;
    }

    // ------------------------------------------------------------ eligibility / named audit views

    function auditExists(uint256 id) public view returns (bool) {
        return id < CellStorage.layout().nextAuditId;
    }

    function requiredHold(address auditor) public view returns (uint256) {
        return CellLogicLib.requiredHoldView(auditor);
    }

    function isEligible(address auditor) public view returns (bool) {
        return CellLogicLib.isEligibleView(auditor);
    }

    function auditorReputationBoostBps(address auditor) public view returns (uint256) {
        return CellLogicLib.auditorReputationBoostBpsView(auditor);
    }

    function claimProofStatement(uint256 originalAuditId, bytes32 toolId, bytes32 resultRoot)
        public
        view
        returns (bytes32)
    {
        return CellLogicLib.claimProofStatementView(originalAuditId, toolId, resultRoot);
    }

    function specChallengeActive(uint256 id) external view returns (bool) {
        return CellLogicLib.specChallengeActiveView(id);
    }

    function auditStateOf(uint256 id) external view returns (AuditState) {
        if (!(auditExists(id))) revert NoAudit();
        return CellStorage.layout().audits[id].state;
    }

    function caseRootOf(uint256 id) external view returns (bytes32) {
        if (!(auditExists(id))) revert NoAudit();
        return CellStorage.layout().audits[id].caseRoot;
    }

    function auditAuditorOf(uint256 id) external view returns (address) {
        return CellStorage.layout().audits[id].auditor;
    }

    function auditProtocolOf(uint256 id) external view returns (address) {
        return CellStorage.layout().audits[id].protocol;
    }

    function auditDeployedOf(uint256 id) external view returns (address) {
        return CellStorage.layout().audits[id].deployedAddress;
    }

    function auditLinkedOf(uint256 id) external view returns (uint256) {
        return CellStorage.layout().audits[id].linkedAuditId;
    }

    function auditSupersedesOf(uint256 id) external view returns (uint256) {
        return CellStorage.layout().audits[id].supersedesAuditId;
    }

    // ------------------------------------------------ registration & queue

    function register() external {
        CellLogicLib.registerExt();
    }

    function submitGenesisAudit(
        address deployedAddress,
        bytes32 expectedCodehash,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        uint256 bounty,
        bytes32[] calldata declaredVerdictTools,
        uint256 supersedesAuditId,
        uint256 auditWindow
    ) external returns (uint256 id) {
        return SubmitAuditLib.submitGenesisAuditExt(
            deployedAddress,
            expectedCodehash,
            specHash,
            specToolId,
            specErrorsRoot,
            bounty,
            declaredVerdictTools,
            supersedesAuditId,
            auditWindow
        );
    }

    function submitAudit(
        address deployedAddress,
        bytes32 expectedCodehash,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        uint256 bounty,
        bytes32[] calldata declaredVerdictTools,
        uint256 supersedesAuditId,
        uint256 auditWindow
    ) external returns (uint256 id) {
        return SubmitAuditLib.submitAuditExt(
            deployedAddress,
            expectedCodehash,
            specHash,
            specToolId,
            specErrorsRoot,
            bounty,
            declaredVerdictTools,
            supersedesAuditId,
            auditWindow
        );
    }

    /// @notice Domain-agnostic intake (Pillar B) — submit an audit for a BARE `artifactHash` (any
    ///         content-addressable O), with an OPTIONAL `deployedAddress` EVM anchor (`address(0)` = pure
    ///         off-chain artifact). Thin dispatcher; logic in SubmitAuditLib (delegatecall).
    function submitArtifactAudit(
        bytes32 artifactHash,
        address deployedAddress,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        uint256 bounty,
        bytes32[] calldata declaredVerdictTools,
        uint256 supersedesAuditId,
        uint256 auditWindow
    ) external returns (uint256 id) {
        return SubmitAuditLib.submitArtifactAuditExt(
            artifactHash,
            deployedAddress,
            specHash,
            specToolId,
            specErrorsRoot,
            bounty,
            declaredVerdictTools,
            supersedesAuditId,
            auditWindow
        );
    }

    /// @notice Off-chain case-root preview (re-landed 2026-07-05) — EVM-anchored form. Returns the exact
    ///         caseRoot the submit path would pin, for integrators/UIs to predict the case id / a duplicate.
    function previewCaseRoot(
        address deployedAddress,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        bytes32[] calldata declaredVerdictTools
    ) external view returns (bytes32) {
        return SubmitAuditLib.previewCaseRootExt(
            deployedAddress, specHash, specToolId, specErrorsRoot, declaredVerdictTools
        );
    }

    /// @notice Off-chain case-root preview (re-landed) — bare-artifact (domain-agnostic) form (pure).
    function previewCaseRootFromHash(
        bytes32 artifactHash,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        bytes32[] calldata declaredVerdictTools
    ) external pure returns (bytes32) {
        return SubmitAuditLib.previewCaseRootFromHashExt(
            artifactHash, specHash, specToolId, specErrorsRoot, declaredVerdictTools
        );
    }

    /// @notice Full declared-verdict-tool set for an audit (re-landed enumerator).
    function declaredVerdictToolsOf(uint256 id) external view returns (bytes32[4] memory toolSlots, uint8 n) {
        return SubmitAuditLib.declaredVerdictToolsOfExt(id);
    }

    function _settleClaimStake(VulnerabilityClaim storage claim, bool slash) internal {
        CellStorage.Layout storage L = CellStorage.layout();
        uint256 s = claim.stake;
        if (s == 0) return;
        if (slash) {
            address dest = L.treasuryEscrow != address(0) ? L.treasuryEscrow : L.admin;
            if (!L.token.transfer(dest, s)) revert TransferFailed();
            if (L.treasuryEscrow != address(0)) ITreasuryEscrow(L.treasuryEscrow).recordSlash(s);
        } else if (!L.token.transfer(claim.claimant, s)) {
            revert TransferFailed();
        }
    }

    // -------------------------------------------------------- tools / Gate A

    function registerTool(bytes32 codeHash, bool isSpecValidationTool) external {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(!L.tools[codeHash].exists)) revert ToolAlreadyRegistered();
        if (!(codeHash != bytes32(0))) revert ZeroCodeHash();
        Tool storage t = L.tools[codeHash];
        t.proposer = msg.sender;
        t.isSpecValidationTool = isSpecValidationTool;
        t.isInvariantEvaluator = false;
        t.canonical = false;
        t.exists = true;
        emit ToolRegistered(codeHash, msg.sender, isSpecValidationTool);
    }

    // ====================================================== slice 2: PASS path

    function protocolAcceptAuditor(uint256 id) external {
        CellLogicLib.protocolAcceptAuditorExt(id);
    }

    function protocolRejectAuditor(uint256 id) external {
        CellLogicLib.protocolRejectAuditorExt(id);
    }

    function advanceProtocolDecision(uint256 id) external {
        CellLogicLib.advanceProtocolDecisionExt(id);
    }

    function acceptAudit(uint256 id, bytes32 specErrorsRoot) external {
        CellLogicLib.acceptAuditExt(id, specErrorsRoot);
    }

    function declineAudit(uint256 id) external {
        CellLogicLib.declineAuditExt(id);
    }

    function advanceAssignment(uint256 id) external {
        CellLogicLib.advanceAssignmentExt(id);
    }

    function retryAssignment(uint256 id) external {
        if (CellStorage.layout().audits[id].state != AuditState.Submitted) revert WrongState();
        CellLogicLib.assignNextExt(id);
    }

    function advanceInAudit(uint256 id) external nonReentrant {
        CellLogicLib.advanceInAuditExt(id);
    }

    function provePass(uint256 id, bytes32 toolId, bytes32 resultRoot) external nonReentrant {
        CellLogicLib.provePass(id, toolId, resultRoot);
    }

    function confirmAudit(uint256 id) external nonReentrant {
        CellLogicLib.confirmAudit(id);
    }

    function proveFail(uint256 id, bytes32 toolId, bytes32 resultRoot) external nonReentrant {
        CellLogicLib.proveFail(id, toolId, resultRoot);
    }

    // ==================================================== slice 3: break path

    function _claimEligibleState(AuditState s) internal pure returns (bool) {
        return s == AuditState.AwaitingWindow || s == AuditState.Audited || s == AuditState.InBlock;
    }

    function _boostSubjectAuditor(Audit storage a) internal view returns (address) {
        if (a.lastDiscoverer != address(0)) {
            return a.lastDiscoverer;
        }
        return a.auditor;
    }

    function claimVulnerability(uint256 originalAuditId, bytes32 toolId, bytes32 resultRoot, bytes calldata proof)
        external
        nonReentrant
    {
        _claimViaModule(
            originalAuditId, toolId, resultRoot, proof, bytes32(0), bytes32(0), bytes32(0), bytes32(0), bytes32(0), bytes32(0)
        );
    }

    function claimVulnerability(
        uint256 originalAuditId,
        bytes32 toolId,
        bytes32 resultRoot,
        bytes calldata proof,
        bytes32 vulnerabilityClassId
    ) external nonReentrant {
        _claimViaModule(
            originalAuditId,
            toolId,
            resultRoot,
            proof,
            bytes32(0),
            bytes32(0),
            bytes32(0),
            bytes32(0),
            bytes32(0),
            vulnerabilityClassId
        );
    }

    function claimVulnerability(
        uint256 originalAuditId,
        bytes32 toolId,
        bytes32 resultRoot,
        bytes calldata proof,
        bytes32 evaluatorToolId,
        bytes32 invariantId,
        bytes32 locationCommitment,
        bytes32 witnessCommitment,
        bytes32 contextRoot
    ) external nonReentrant {
        _claimViaModule(
            originalAuditId,
            toolId,
            resultRoot,
            proof,
            evaluatorToolId,
            invariantId,
            locationCommitment,
            witnessCommitment,
            contextRoot,
            bytes32(0)
        );
    }

    function claimVulnerability(
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
    ) external nonReentrant {
        _claimViaModule(
            originalAuditId,
            toolId,
            resultRoot,
            proof,
            evaluatorToolId,
            invariantId,
            locationCommitment,
            witnessCommitment,
            contextRoot,
            vulnerabilityClassId
        );
    }

    function _claimViaModule(
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
    ) internal {
        CellStorage.Layout storage L = CellStorage.layout();
        CellLogicLib.requireNoSettlementBlockExt(originalAuditId);
        if (L.claimDisputeModule == address(0)) revert IssuanceUnset();
        IClaimDisputeModule(L.claimDisputeModule).claimVulnerability(
            msg.sender,
            originalAuditId,
            toolId,
            resultRoot,
            proof,
            evaluatorToolId,
            invariantId,
            locationCommitment,
            witnessCommitment,
            contextRoot,
            vulnerabilityClassId
        );
    }

    function submitFixAudit(
        address deployedFix,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        uint256 bounty,
        uint256 linkedAuditId
    ) external returns (uint256 id) {
        return SubmitAuditLib.submitFixAuditExt(
            deployedFix, specHash, specToolId, specErrorsRoot, bounty, linkedAuditId
        );
    }

    function spawnDisputeReaudit(
        uint256 originalId,
        uint256 disputeBounty,
        address lastDiscoverer,
        address extraExclude,
        bytes32 requiredTool,
        address resolverModule
    ) external returns (uint256 disputeId) {
        return CellLogicLib.spawnDisputeReaudit(
            originalId, disputeBounty, lastDiscoverer, extraExclude, requiredTool, resolverModule
        );
    }

    function settlementExpireClaimDispute(uint256 originalId) external {
        CellStorage.Layout storage L = CellStorage.layout();
        if (msg.sender != L.claimDisputeModule) revert NotAdmin();
        uint256 disputeId = L.activeDisputeAuditId[originalId];
        if (disputeId == 0) revert NoOpenDispute();
        Audit storage d = L.audits[disputeId];
        if (d.state == AuditState.AwaitingWindow) revert DisputeVerdicted();
        if (block.timestamp < d.windowStart + L.claimResolutionWindow) revert DisputeWindowActive();
        L.activeDisputeAuditId[originalId] = 0;
        if (d.bounty > 0 && !L.token.transfer(d.protocol, d.bounty)) revert TransferFailed(        );
    }

    function expireClaim(uint256 originalAuditId) external nonReentrant {
        CellStorage.Layout storage L = CellStorage.layout();
        Audit storage a = L.audits[originalAuditId];
        VulnerabilityClaim storage claim = L.vulnerabilityClaims[originalAuditId];
        if (a.state != AuditState.Claimed) revert NotClaimed();
        if (!claim.exists) revert NoClaimRecord();
        if (claim.resolved) revert ClaimAlreadyResolved();
        if (L.activeDisputeAuditId[originalAuditId] != 0) revert DisputeOpen();
        if (L.claimDisputeModule != address(0)) {
            if (!IClaimDisputeModule(L.claimDisputeModule).claimantDisputeLaneOpen(originalAuditId)) {
                revert ProtocolDisputeDecisionPending();
            }
        }
        if (block.timestamp < claim.claimTimestamp + L.claimResolutionWindow) revert ResolutionWindowActive();
        _resolveClaim(originalAuditId);
    }

    function _resolveClaim(uint256 originalAuditId) internal {
        CellStorage.Layout storage L = CellStorage.layout();
        Audit storage a = L.audits[originalAuditId];
        VulnerabilityClaim storage claim = L.vulnerabilityClaims[originalAuditId];

        claim.resolved = true;
        _settleClaimStake(claim, a.stateBeforeClaim != AuditState.InAudit);
        L.activeFixAuditId[originalAuditId] = 0;
        CellLogicLib.setAuditStateExt(originalAuditId, a.stateBeforeClaim);
        emit ClaimExpired(originalAuditId, claim.claimant, 0);
    }

    // ---------------------------------------- ClaimDisputeModule mutators

    function isDeclaredVerdictTool(uint256 auditId, bytes32 toolId) external view returns (bool) {
        return CellLogicLib.isDeclaredVerdictToolView(auditId, toolId);
    }

    function settlementApplyClaimFiled(uint256 originalAuditId, ClaimInput calldata c) external {
        CellStorage.Layout storage L = CellStorage.layout();
        if (msg.sender != L.claimDisputeModule) revert NotAdmin();
        Audit storage a = L.audits[originalAuditId];
        a.stateBeforeClaim = a.state;
        CellLogicLib.setAuditStateExt(originalAuditId, AuditState.Claimed);
        VulnerabilityClaim storage claim = L.vulnerabilityClaims[originalAuditId];
        claim.claimant = c.claimant;
        claim.toolId = c.toolId;
        claim.proofHash = c.proofHash;
        claim.claimTimestamp = block.timestamp;
        claim.stake = c.stake;
        claim.resolved = false;
        claim.exists = true;
        claim.witnessPath = c.witnessPath;
        claim.evaluatorToolId = c.evaluatorToolId;
        claim.invariantId = c.invariantId;
        claim.locationCommitment = c.locationCommitment;
        claim.witnessCommitment = c.witnessCommitment;
        claim.contextRoot = c.contextRoot;
        emit VulnerabilityClaimed(originalAuditId, c.claimant, c.toolId, c.proofHash, c.stake);
    }

    function settlementResolveClaim(
        uint256 originalId,
        address claimant,
        uint256 amount,
        bool vindicated,
        bool slashAuditorFailed
    ) external {
        CellStorage.Layout storage L = CellStorage.layout();
        if (msg.sender != L.claimDisputeModule) revert NotAdmin();
        Audit storage a = L.audits[originalId];
        VulnerabilityClaim storage claim = L.vulnerabilityClaims[originalId];
        claim.resolved = true;
        if (vindicated) {
            _settleClaimStake(claim, true);
            CellLogicLib.setAuditStateExt(originalId, a.stateBeforeClaim);
            emit ClaimVindicated(originalId, claimant, amount);
            return;
        }
        _settleClaimStake(claim, false);
        if (slashAuditorFailed && a.stateBeforeClaim != AuditState.InAudit && a.auditor != address(0)) {
            L.auditors[a.auditor].failed += 1;
        }
        if (claimant != address(0)) {
            L.auditors[claimant].found += 1;
            a.lastDiscoverer = claimant;
        }
        CellLogicLib.setAuditStateExt(originalId, AuditState.Exploited);
        L.protocols[a.protocol].exploited += 1;
        emit OriginalAuditExploited(originalId, claimant, amount, address(0));
    }

    function settlementClearDispute(uint256 originalId) external {
        if (msg.sender != CellStorage.layout().claimDisputeModule) revert NotAdmin();
        CellStorage.layout().activeDisputeAuditId[originalId] = 0;
    }

    function settlementToken(uint8 op, address from, address to, uint256 amount) external {
        CellStorage.Layout storage L = CellStorage.layout();
        if (
            msg.sender != L.claimDisputeModule && msg.sender != L.specGapModule && msg.sender != L.specArbiterModule
                && msg.sender != L.integrityReviewModule
        ) {
            revert NotAdmin();
        }
        if (op == 0) {
            if (amount > 0 && !L.token.transferFrom(from, address(this), amount)) revert StakeTransferFailed();
        } else if (op == 1) {
            if (amount > 0 && !L.token.transfer(to, amount)) revert TransferFailed();
        } else if (op == 2 && (msg.sender == L.specGapModule || msg.sender == L.specArbiterModule || msg.sender == L.integrityReviewModule)) {
            if (amount > 0 && L.treasuryEscrow != address(0)) {
                if (!L.token.transfer(L.treasuryEscrow, amount)) revert TransferFailed();
                ITreasuryEscrow(L.treasuryEscrow).recordSlash(amount);
            }
        }
    }

    function settlementPayDiscoverer(
        uint256 originalAuditId,
        address claimant,
        uint256 escrowDraw,
        bool bountyPotLocked,
        uint256 bounty
    ) external returns (uint256 paid) {
        CellStorage.Layout storage L = CellStorage.layout();
        if (msg.sender != L.claimDisputeModule) revert NotAdmin();
        Audit storage a = L.audits[originalAuditId];
        address boostSubject = a.stateBeforeClaim == AuditState.InAudit ? a.auditor : _boostSubjectAuditor(a);
        paid = DiscovererPayoutLib.pay(
            IPayoutToken(address(L.token)),
            IPayoutEscrow(L.treasuryEscrow),
            L.discoveryCapBps,
            L.discoveryFloorBps,
            PAY_DISCOVERER_MAX_ITERATIONS,
            a.protocol,
            claimant,
            boostSubject,
            escrowDraw,
            bountyPotLocked,
            bounty
        );
        if (paid > 0) {
            emit DiscovererPayoutResolved(originalAuditId, claimant, boostSubject, paid);
        }
    }

    function structuralGapFailRecorded(uint256 gapAuditId, bytes32 citedTool, bytes32 proofHash)
        external
        onlyStructuralModule
    {
        CellStorage.Layout storage L = CellStorage.layout();
        L.auditProofHash[gapAuditId] = proofHash;
        L.auditVerdictPass[gapAuditId] = false;
        L.auditVerdictToolId[gapAuditId] = citedTool;
        CellLogicLib.setAuditStateExt(gapAuditId, AuditState.Audited);
        Audit storage ga = L.audits[gapAuditId];
        if (ga.bounty > 0) {
            if (!(L.token.transfer(ga.protocol, ga.bounty))) revert BountyPayoutFailed();
            ga.bounty = 0;
        }
    }

    function structuralSpawn(
        uint8 kind,
        address payer,
        address deployedAddress,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specPassDigest,
        uint256 bounty,
        uint256 gapId
    ) external onlyStructuralModule returns (uint256 id) {
        CellStorage.Layout storage L = CellStorage.layout();
        if (!(bounty > 0)) revert BountyRequired();
        if (!(deployedAddress != address(0))) revert DeployedAddressRequired();
        if (!(deployedAddress.code.length > 0)) revert NoContractAtAddress();
        bytes32 artifactHash = deployedAddress.codehash;
        uint8 structuralKind = kind == 0 ? uint8(1) : uint8(2);
        if (structuralKind == 2 && L.artifactRegistered[artifactHash]) {
            revert ArtifactAlreadyAudited(L.artifactToAuditId[artifactHash]);
        }
        id = CellLogicLib.initAuditRowExt(
            payer,
            deployedAddress,
            artifactHash,
            specHash,
            specToolId,
            specPassDigest,
            bounty,
            L.minAuditWindow,
            false,
            false,
            gapId,
            0
        );
        if (structuralKind == 2) {
            L.artifactRegistered[artifactHash] = true;
            L.artifactToAuditId[artifactHash] = id;
        }
        CellLogicLib.setAuditStateExt(id, AuditState.Submitted);
        emit AuditSubmitted(id, payer, deployedAddress, bounty, artifactHash, specToolId, specPassDigest);
        CellLogicLib.assignNextExt(id);
        L.audits[id].protocolApprovedAssignment = true;
    }

    function structuralSlashProposer(address proposer) external onlyStructuralModule {
        if (proposer != address(0)) CellStorage.layout().auditors[proposer].failed += 1;
    }

    function _voidAuditRow(CellStorage.Layout storage L, uint256 auditId, bool slashAuditorFailed) internal {
        Audit storage a = L.audits[auditId];
        if (a.bounty > 0 && a.bountyEscrowed && a.state != AuditState.InBlock) {
            if (!L.token.transfer(a.protocol, a.bounty)) revert TransferFailed();
            a.bounty = 0;
        }
        if (slashAuditorFailed && a.auditor != address(0)) L.auditors[a.auditor].failed += 1;
        if (a.artifactHash != bytes32(0)) {
            L.artifactRegistered[a.artifactHash] = false;
            delete L.artifactToAuditId[a.artifactHash];
        }
        CellLogicLib.setAuditStateExt(auditId, AuditState.Invalidated);
    }

    function settlementOverlay(uint8 kind, uint8 op, uint256 auditId, address aux) external {
        CellStorage.Layout storage L = CellStorage.layout();
        if (op != 2) revert NotAdmin();
        if (kind == 0) {
            if (msg.sender != L.specArbiterModule) revert NotAdmin();
            VulnerabilityClaim storage claim = L.vulnerabilityClaims[auditId];
            if (claim.exists && !claim.resolved) {
                if (claim.stake > 0 && !L.token.transfer(claim.claimant, claim.stake)) revert TransferFailed();
                claim.resolved = true;
                L.activeFixAuditId[auditId] = 0;
            }
            bytes32 toolId = L.audits[auditId].specToolId;
            L.audits[auditId].bounty = 0;
            if (L.audits[auditId].artifactHash != bytes32(0)) {
                L.artifactRegistered[L.audits[auditId].artifactHash] = false;
                delete L.artifactToAuditId[L.audits[auditId].artifactHash];
            }
            CellLogicLib.setAuditStateExt(auditId, AuditState.Invalidated);
            emit SpecInvalidated(auditId, aux, toolId);
            return;
        }
        if (kind == 1) {
            if (msg.sender != L.integrityReviewModule) revert NotAdmin();
            _voidAuditRow(L, auditId, true);
            return;
        }
        revert NotAdmin();
    }
}

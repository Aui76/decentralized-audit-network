// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./IClaimSettlementMutator.sol";
import "./AuditCell.sol";
import "./CellStorage.sol";
import "./RunDigests.sol";

interface IIssuanceUpgradeMint {
    function mintUpgradeAdopt(address to) external returns (uint256);
}

interface ICellEscrowStructural {
    function payStructuralUpgradeEscrow(address recipient, uint256 amount, uint256 maxIterations)
        external
        returns (uint256);
    function escrowBalance() external view returns (uint256);
}

/// @title StructuralUpgradeModule — F-41 network capability gaps (X5).
contract StructuralUpgradeModule {
    enum EscrowTranche {
        Pass,
        Adopt
    }

    enum CanonicalTier {
        None,
        Probationary,
        Official
    }

    enum GapState {
        None,
        GapFiled,
        GapConfirmed,
        FixInAudit,
        Probation,
        Adopted,
        RolledBack,
        Expired,
        // PC-92 bug_011 (G4(d)): the gap's audit was voided before it confirmed the gap. Terminal; the filer's stake is
        // refunded. APPENDED, so every earlier value keeps its number.
        GapVoided
    }

    struct NetworkGap {
        address filer;
        bytes32 gapSpecHash;
        bytes32 harnessToolId;
        bytes32 harnessProofHash;
        address canonicalTarget;
        GapState state;
        uint256 gapAuditId;
        uint256 fixAuditId;
        uint256 juryOk;
        uint256 juryNotOk;
        uint256 juryOkW;
        uint256 juryNotOkW;
        uint256 juryOkWC;
        uint256 juryNotOkWC;
        uint256 probationDeadline;
        uint256 stake;
        bool stakeRefunded;
        uint256 priorCanonicalAuditId;
        uint8 priorCanonicalTier;
        uint256 adoptedAt;
        uint256 probationStartBlock;
        bool exists;
    }

    struct StructuralUpgradeRecord {
        address proposer;
        uint256 gapId;
        bool passEscrowClaimed;
        bool adoptEscrowClaimed;
        bool exists;
    }

    address public admin;
    address public cell;
    address public issuanceModule;
    bool public wiringLocked;

    uint256 public nextGapId = 1;
    uint256 public gapFilingStake = 100 ether;
    uint256 public probationWindow = 90 days;
    uint256 public opsRegressionWindow = 30 days;
    uint256 public canonicalPromotionDuration = 30 days;
    uint256 public juryOkRequired = 30;
    uint256 public juryNetRequired = 30;
    uint256 public minSuccessfulForJury = 1;
    uint256 public minJuryQualifyingBounty = 1;

    uint256 public kJury = 5;
    uint256 public populationJudgmentPriorBps = 8000;
    uint256 public juryOkWCRequired = 3000;
    uint256 public juryNetWCRequired = 3000;

    uint256 public passPayoutBps = 4000;
    uint256 public upgradeClaimCapBps = 540;
    uint256 public upgradeProposalBase = 500 ether;
    uint256 public upgradeMaturityMax = 10;
    uint256 public upgradeMaturityUnit = 50;
    uint256 public upgradeProposerMax = 5;
    uint256 public upgradeProposerUnit = 10;

    uint256 public constant PAY_STRUCTURAL_ESCROW_MAX_ITERATIONS = 512;

    mapping(uint256 => NetworkGap) internal _gaps;
    mapping(uint256 => StructuralUpgradeRecord) internal _upgrades;
    mapping(uint256 => uint8) public structuralAuditKind; // 1 = gap audit, 2 = structural fix
    mapping(uint256 => mapping(address => uint8)) internal _gapJuryVote;
    mapping(uint256 => mapping(address => bool)) internal _gapJuryDutyDeclined;
    mapping(uint256 => mapping(address => bool)) internal _gapJuryCreditClaimed;
    mapping(address => uint256) public jurorOkVoteCount;
    mapping(address => uint256) public jurorCorrectOkVoteCount;
    mapping(uint256 => uint256) public activeStructuralFixAuditId;
    mapping(address => uint256) public canonicalContractAuditId;
    mapping(address => CanonicalTier) public canonicalTier;
    mapping(address => uint256) public canonicalGapIdForDeploy;
    /// bug_001's STORE half (VD-143(1) said "store and emit"; the event alone was emit-only). The witness
    /// audit that justified a rollback, readable on chain forever rather than only reconstructable from
    /// logs - which is what "never stored" meant in the paid review's own words.
    mapping(uint256 => uint256) public rollbackWitnessAuditId;

    event NetworkGapFiled(uint256 indexed gapId, address indexed filer, bytes32 harnessToolId, bytes32 gapSpecHash, uint256 stake);
    event NetworkGapConfirmed(uint256 indexed gapId, uint256 indexed gapAuditId, bytes32 harnessProofHash);
    event NetworkGapExpired(uint256 indexed gapId, uint8 reasonCode);
    event StructuralFixSubmitted(uint256 indexed gapId, uint256 indexed fixAuditId);
    event StructuralGapRecovered(uint256 indexed gapId, uint256 indexed auditId, GapState state);
    event StructuralFixProposalReady(uint256 indexed gapId, uint256 indexed fixAuditId);
    event ProbationStarted(uint256 indexed gapId, uint256 indexed fixAuditId, uint256 startBlock);
    event UpgradeJuryVote(
        uint256 indexed gapId,
        uint256 indexed fixAuditId,
        address indexed juror,
        uint256 workAuditId,
        bool ok,
        uint256 juryOk,
        uint256 juryNotOk,
        uint256 juryOkW,
        uint256 juryNotOkW
    );
    event JuryDutyDeclined(uint256 indexed gapId, address indexed auditor);
    event StructuralUpgradeAdopted(uint256 indexed gapId, uint256 indexed fixAuditId, address deployed, uint8 tier);
    event CanonicalPromoted(uint256 indexed gapId, address indexed deployed, uint256 adoptedAt, uint256 fixAuditId);
    // bug_001 (c), the store-and-emit half of VD-143(1)'s remedy: the witness now RIDES the log. Before
    // this the event carried msg.sender - so the ACT was attributable and the JUSTIFICATION was not, and
    // no reader of the chain could show that a rollback's claimed proof was fabricated.
    event StructuralUpgradeRolledBack(
        uint256 indexed gapId, uint256 indexed fixAuditId, uint256 priorCanonicalAuditId, address indexed rollbackAuditor, bytes32 blockHash, uint256 opsAuditId, bytes32 opsSpecHash, bytes32 toolId, bytes32 resultRoot
    );
    event UpgradeBlockMinted(
        uint256 indexed gapId, uint256 indexed fixAuditId, address proposer, address deployed, bytes32 harnessToolId, uint256 minted, bytes32 blockHash
    );
    event StructuralUpgradeEscrowPaid(
        uint256 indexed gapId, uint256 indexed fixAuditId, uint8 tranche, uint256 paid, uint256 trancheTarget
    );
    event ParameterUpdated(string indexed name, uint256 value);

    error NotAdmin();
    error WiringLocked();
    error HostUnset();
    error NotRegistered();
    error InsufficientHold();
    error ZeroTarget();
    error NoCode();
    // bug_001's witness checks. Named individually rather than one WitnessInvalid, because the caller is
    // usually honest and each failure has its own cure - wrong contract, the regression was never
    // adjudicated, or the tool/root/spec does not match what the chain recorded. `WitnessNotUpheld` is
    // ONE error where the first writing had two (not-settled and not-failing): VD-153 collapsed them,
    // because on the discoverer path the audit's verdict fields describe the PASS that was overturned,
    // so "did it fail" is not a separate question from "did the claim stand".
    error WitnessTargetMismatch();
    error WitnessNotUpheld();
    error WitnessToolMismatch();
    error WitnessResultMismatch();
    error WitnessSpecMismatch();
    error ZeroGapSpec();
    error ZeroHarness();
    error HarnessNotRegistered();
    error HarnessIsSpecTool();
    error BountyRequired();
    error StakeTransferFailed();
    error NoGap();
    error GapNotConfirmed();
    error FixAlreadyOpen();
    error NotInProbation();
    error ProbationEnded();
    error ProbationActive();
    error JuryThresholdNotMet();
    error NotAdopted();
    error PromotionPeriodActive();
    error GapDeployMismatch();
    error NotProbationary();
    error AlreadyOfficial();
    error ProposerCannotRollback();
    error OpsWindowClosed();
    error NotStructuralFix();
    error FixNotInBlock();
    error NoStructuralRecord();
    error AlreadyVoted();
    error ExcludedFromJury();
    error DeclinedJuryDuty();
    error InsufficientJuryStanding();
    error NotWorkAuditor();
    error InvalidWorkAudit();
    error WorkNotConfirmed();
    error WorkBeforeProbation();
    error WorkDoesNotQualify();
    error CanonicalNotOfficial();
    error NotGapAudit();
    error NotAuditor();
    error WrongState();
    error WrongHarnessTool();
    error ReentrantCall();
    error GapAuditRequiresFail();
    error GapUseModuleProveFail();
    error NotProposer();
    error ProposerMismatch();
    error PassTrancheClaimed();
    error AdoptTrancheClaimed();
    error NotReadyForPassClaim();
    error TreasuryEscrowUnset();
    error RollbackWindowNotElapsed();
    error DidNotVoteOk();
    error CreditAlreadyClaimed();
    error BadParamId();
    error ParamLocked();
    error NothingToRecover();
    error InAuditWindowPassed();
    error SpecToolNotRegistered();
    error NotSpecValidationTool();

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus = _NOT_ENTERED;

    // Phase B1 (admin-door-residue-verdicts, VD-26): doors 12-15 lock+bound pass. Ported from
    // IssuanceModule's issuanceParamLockMask shape (A1: capability now, armed later per parameter —
    // ships UNARMED, mask = 0). F2 (upgradeClaimCapBps had TWO write paths, :314 and :331) is closed
    // by deleting the claimCapBps arm from setStructuralUpgradeEscrowParams below, so the variable has
    // exactly ONE door (setUpgradeClaimCapBps) for LOCK_CLAIM_CAP to guard.
    uint256 public structuralParamLockMask;
    uint8 public constant LOCK_GAP_FILING_STAKE = 0; // door 12: setGapFilingStake
    uint8 public constant LOCK_PASS_PAYOUT = 1;      // door 13: setPassPayoutBps (already bounded; lock only)
    uint8 public constant LOCK_CLAIM_CAP = 2;        // door 14: setUpgradeClaimCapBps (F2: sole remaining writer)
    uint8 public constant LOCK_ESCROW_PARAMS = 3;    // door 15: setStructuralUpgradeEscrowParams

    function structuralParamLocked(uint8 id) public view returns (bool) {
        return (structuralParamLockMask & (uint256(1) << id)) != 0;
    }

    /// @notice Lock a structural-upgrade economic param one-way (irreversible). UNARMED at this deploy by design.
    function lockStructuralParam(uint8 id) external onlyAdmin {
        if (id > LOCK_ESCROW_PARAMS) revert BadParamId();
        structuralParamLockMask |= (uint256(1) << id);
        emit ParameterUpdated("structuralParamLock", id);
    }

    function _requireUnlocked(uint8 id) internal view {
        if (structuralParamLocked(id)) revert ParamLocked();
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyCell() {
        if (msg.sender != cell) revert NotAdmin();
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

    function wire(address _cell, address _issuance) external onlyAdmin {
        if (wiringLocked) revert WiringLocked();
        cell = _cell;
        issuanceModule = _issuance;
    }

    // bug_003 (DEC-44 paid review; ruled by VD-143(2)). Same shape as `IssuanceModule.lockWiring`: this
    // asserted `cell` alone while `wire()` also sets `issuanceModule`, and the lock is one-shot and
    // one-way — so an `issuanceModule` left at zero was frozen at zero permanently. Both fields, both
    // directions covered in `LockWiringPrecondition.t.sol`.
    function lockWiring() external onlyAdmin {
        if (cell == address(0) || issuanceModule == address(0)) revert HostUnset();
        wiringLocked = true;
    }

    function setGapFilingStake(uint256 v) external onlyAdmin {
        _requireUnlocked(LOCK_GAP_FILING_STAKE);
        gapFilingStake = v;
        emit ParameterUpdated("gapFilingStake", v);
    }

    function setProbationWindow(uint256 v) external onlyAdmin {
        probationWindow = v;
        emit ParameterUpdated("probationWindow", v);
    }

    function setOpsRegressionWindow(uint256 v) external onlyAdmin {
        if (v > canonicalPromotionDuration) revert PromotionPeriodActive();
        opsRegressionWindow = v;
        emit ParameterUpdated("opsRegressionWindow", v);
    }

    function setCanonicalPromotionDuration(uint256 v) external onlyAdmin {
        if (v < opsRegressionWindow) revert PromotionPeriodActive();
        canonicalPromotionDuration = v;
        emit ParameterUpdated("canonicalPromotionDuration", v);
    }

    function setJuryAdoptThresholds(uint256 okRequired, uint256 netRequired) external onlyAdmin {
        juryOkRequired = okRequired;
        juryNetRequired = netRequired;
    }

    function setJuryVoteParams(uint256 minSuccessful, uint256 minBounty) external onlyAdmin {
        minSuccessfulForJury = minSuccessful;
        minJuryQualifyingBounty = minBounty;
    }

    function setJuryCredibilityParams(
        uint256 _kJury,
        uint256 _populationJudgmentPriorBps,
        uint256 _juryOkWCRequired,
        uint256 _juryNetWCRequired
    ) external onlyAdmin {
        if (_populationJudgmentPriorBps > 10_000) revert WrongState();
        kJury = _kJury;
        populationJudgmentPriorBps = _populationJudgmentPriorBps;
        juryOkWCRequired = _juryOkWCRequired;
        juryNetWCRequired = _juryNetWCRequired;
        emit ParameterUpdated("kJury", _kJury);
        emit ParameterUpdated("populationJudgmentPriorBps", _populationJudgmentPriorBps);
        emit ParameterUpdated("juryOkWCRequired", _juryOkWCRequired);
        emit ParameterUpdated("juryNetWCRequired", _juryNetWCRequired);
    }

    function setPassPayoutBps(uint256 v) external onlyAdmin {
        _requireUnlocked(LOCK_PASS_PAYOUT);
        if (v > 10_000) revert WrongState();
        passPayoutBps = v;
        emit ParameterUpdated("passPayoutBps", v);
    }

    function setUpgradeClaimCapBps(uint256 v) external onlyAdmin {
        _requireUnlocked(LOCK_CLAIM_CAP);
        if (v > 10_000) revert WrongState();
        upgradeClaimCapBps = v;
        emit ParameterUpdated("upgradeClaimCapBps", v);
    }

    // F2 fix (admin-door-residue-verdicts, door 15): the claimCapBps arm is DELETED from this bundle.
    // Pre-fix, this function wrote upgradeClaimCapBps unconditionally at this line, giving the variable
    // a second writer that bypassed any lock placed on setUpgradeClaimCapBps alone. upgradeClaimCapBps
    // now has exactly ONE door (setUpgradeClaimCapBps, LOCK_CLAIM_CAP above).
    function setStructuralUpgradeEscrowParams(
        uint256 base,
        uint256 maturityMax,
        uint256 maturityUnit,
        uint256 proposerMax,
        uint256 proposerUnit
    ) external onlyAdmin {
        _requireUnlocked(LOCK_ESCROW_PARAMS);
        upgradeProposalBase = base;
        upgradeMaturityMax = maturityMax;
        upgradeMaturityUnit = maturityUnit;
        upgradeProposerMax = proposerMax;
        upgradeProposerUnit = proposerUnit;
        emit ParameterUpdated("upgradeProposalBase", base);
    }

    function upgradeProposalPayoutTarget(address proposer) public view returns (uint256) {
        AuditCell c = AuditCell(cell);
        uint256 maturity = c.totalSuccessfulAudits() / upgradeMaturityUnit;
        if (maturity == 0) {
            maturity = 1;
        } else if (maturity > upgradeMaturityMax) {
            maturity = upgradeMaturityMax;
        }

        (uint256 successful,,,,,) = c.auditors(proposer);
        uint256 prop = 1 + successful / upgradeProposerUnit;
        if (prop > upgradeProposerMax) {
            prop = upgradeProposerMax;
        }

        return upgradeProposalBase * maturity * prop;
    }

    function claimStructuralUpgradeEscrow(uint256 fixAuditId, EscrowTranche tranche)
        external
        nonReentrant
        returns (uint256 paid)
    {
        return _payStructuralUpgradeEscrow(fixAuditId, tranche, msg.sender);
    }

    function gapStateOf(uint256 gapId) external view returns (GapState) {
        return _gaps[gapId].state;
    }

    function gapHarnessProofHashOf(uint256 gapId) external view returns (bytes32) {
        return _gaps[gapId].harnessProofHash;
    }

    function harnessToolOf(uint256 gapId) external view returns (bytes32) {
        return _gaps[gapId].harnessToolId;
    }

    function gapHarnessConfirmed(uint256 gapId) external view returns (bool) {
        return _gaps[gapId].harnessProofHash != bytes32(0);
    }

    function isStructuralAudit(uint256 auditId) external view returns (bool) {
        return structuralAuditKind[auditId] != 0;
    }

    function proveGapFail(uint256 gapAuditId, bytes32 toolId, bytes32 resultRoot) external nonReentrant {
        if (resultRoot == bytes32(0)) revert ZeroHarness();
        if (structuralAuditKind[gapAuditId] != 1) revert NotGapAudit();
        AuditCell c = AuditCell(cell);
        if (c.auditAuditorOf(gapAuditId) != msg.sender) revert NotAuditor();
        if (uint256(c.auditStateOf(gapAuditId)) != uint256(CellTypeDefs.AuditState.InAudit)) revert WrongState();
        // VD-218(4) F3 (bug_004's shape, I2): the gap verdict closes where the permissionless timeout opens
        // (`advanceInAuditExt`, `block.timestamp > pickupTime + inAuditWindow`), read from the cell's own row.
        if (block.timestamp > c.getAudit(gapAuditId).pickupTime + c.inAuditWindow()) revert InAuditWindowPassed();
        // PC-92 bug_009 (G5, I5): the ordinary verdict path rechecks the hold AT THE VERDICT
        // (`CellLogicLib.submitVerdictAfterProof`), because eligibility can lapse between accepting and deciding. The gap
        // verdict checked identity and state only, so an auditor the cell would no longer draw could still confirm a gap.
        if (!c.isEligible(msg.sender)) revert InsufficientHold();
        uint256 gapId = c.auditLinkedOf(gapAuditId);
        if (_gaps[gapId].harnessToolId != toolId) revert WrongHarnessTool();
        c.structuralGapFailRecorded(gapAuditId, toolId, resultRoot);
        _onGapVerdict(gapId, gapAuditId, resultRoot);
    }

    function onStructuralCellHook(uint8 phase, uint256 id, bytes32 tool) external onlyCell {
        uint8 kind = structuralAuditKind[id];
        if (kind == 0) return;
        if (phase == 1) {
            if (kind == 1) revert GapAuditRequiresFail();
            if (kind == 2) {
                AuditCell c = AuditCell(cell);
                uint256 gapId = c.auditLinkedOf(id);
                if (_gaps[gapId].harnessProofHash == bytes32(0)) revert GapNotConfirmed();
                if (_gaps[gapId].harnessToolId != tool) revert WrongHarnessTool();
            }
        } else if (phase == 2 && kind == 1) {
            revert GapUseModuleProveFail();
        }
    }

    function beginProbationAfterFixConfirm(uint256 fixId) external nonReentrant {
        AuditCell c = AuditCell(cell);
        if (structuralAuditKind[fixId] != 2) revert NotStructuralFix();
        if (uint256(c.auditStateOf(fixId)) != uint256(CellTypeDefs.AuditState.InBlock)) revert FixNotInBlock();
        _onFixConfirmed(fixId);
    }

    function juryTallyForGap(uint256 gapId) external view returns (uint256 ok, uint256 notOk) {
        NetworkGap storage g = _gaps[gapId];
        return (g.juryOk, g.juryNotOk);
    }

    function juryTallyWeightedForGap(uint256 gapId) external view returns (uint256 okW, uint256 notOkW) {
        NetworkGap storage g = _gaps[gapId];
        return (g.juryOkW, g.juryNotOkW);
    }

    function juryTallyCredibilityForGap(uint256 gapId) external view returns (uint256 okWC, uint256 notOkWC) {
        NetworkGap storage g = _gaps[gapId];
        return (g.juryOkWC, g.juryNotOkWC);
    }

    function juryAdoptReady(uint256 gapId) external view returns (bool) {
        return _juryAdoptSatisfied(_gaps[gapId]);
    }

    function canonicalPromotionReady(uint256 gapId) external view returns (bool) {
        NetworkGap storage g = _gaps[gapId];
        if (!g.exists || g.state != GapState.Adopted) return false;
        address deployed = AuditCell(cell).auditDeployedOf(g.fixAuditId);
        if (canonicalTier[deployed] != CanonicalTier.Probationary) return false;
        return block.timestamp >= g.adoptedAt + canonicalPromotionDuration;
    }

    function structuralGapRunDigest(
        uint256 gapId,
        uint256 gapAuditId,
        bytes32 harnessToolId,
        address canonicalTarget,
        bytes32 resultRoot
    ) external pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "STRUCTURAL_GAP_RUN_V1", gapId, gapAuditId, harnessToolId, canonicalTarget, resultRoot
            )
        );
    }

    function fileNetworkGap(
        address canonicalTarget,
        bytes32 gapSpecHash,
        bytes32 harnessToolId,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        uint256 gapAuditBounty
    ) external nonReentrant returns (uint256 gapId, uint256 gapAuditId) {
        _requireEligible(msg.sender);
        if (canonicalTarget == address(0)) revert ZeroTarget();
        if (canonicalTarget.code.length == 0) revert NoCode();
        _requireOfficialForGapTarget(canonicalTarget);
        if (gapSpecHash == bytes32(0)) revert ZeroGapSpec();
        if (harnessToolId == bytes32(0)) revert ZeroHarness();
        (, bool isSpecTool, , , bool toolExists, , ) = AuditCell(cell).tools(harnessToolId);
        if (!toolExists) revert HarnessNotRegistered();
        if (isSpecTool) revert HarnessIsSpecTool();
        // PC-92 bug_012 (G5): the SPEC tool gets the validation ordinary submission runs
        // (`SubmitAuditLib._requireValidSpecAtSubmit`). This path computed the spec digest straight from its arguments, so
        // a gap could be filed against a spec tool that is unregistered, or registered as something other than a spec tool -
        // and the digest it pinned would be meaningless either way.
        (, bool specIsSpecTool, , , bool specExists, , ) = AuditCell(cell).tools(specToolId);
        if (!specExists) revert SpecToolNotRegistered();
        if (!specIsSpecTool) revert NotSpecValidationTool();
        if (gapAuditBounty == 0) revert BountyRequired();

        AuditCell c = AuditCell(cell);
        bytes32 specPassDigest = RunDigests.specRunDigest(gapSpecHash, specToolId, true, specErrorsRoot);

        uint256 stake = gapFilingStake;
        if (stake > 0) {
            if (!c.token().transferFrom(msg.sender, address(this), stake)) revert StakeTransferFailed();
        }

        gapId = nextGapId++;
        _gaps[gapId] = NetworkGap({
            filer: msg.sender,
            gapSpecHash: gapSpecHash,
            harnessToolId: harnessToolId,
            harnessProofHash: bytes32(0),
            canonicalTarget: canonicalTarget,
            state: GapState.GapFiled,
            gapAuditId: 0,
            fixAuditId: 0,
            juryOk: 0,
            juryNotOk: 0,
            juryOkW: 0,
            juryNotOkW: 0,
            juryOkWC: 0,
            juryNotOkWC: 0,
            probationDeadline: 0,
            stake: stake,
            stakeRefunded: false,
            priorCanonicalAuditId: 0,
            priorCanonicalTier: 0,
            adoptedAt: 0,
            probationStartBlock: 0,
            exists: true
        });

        gapAuditId = c.structuralSpawn(
            0, msg.sender, canonicalTarget, gapSpecHash, specToolId, specPassDigest, gapAuditBounty, gapId
        );
        structuralAuditKind[gapAuditId] = 1;
        _gaps[gapId].gapAuditId = gapAuditId;
        emit NetworkGapFiled(gapId, msg.sender, harnessToolId, gapSpecHash, stake);
    }

    function submitStructuralFix(
        address deployedAddress,
        bytes32 specHash,
        bytes32 specToolId,
        bytes32 specErrorsRoot,
        uint256 bounty,
        uint256 gapId
    ) external nonReentrant returns (uint256 fixAuditId) {
        _requireEligible(msg.sender);
        NetworkGap storage g = _gaps[gapId];
        if (!g.exists) revert NoGap();
        if (g.state != GapState.GapConfirmed) revert GapNotConfirmed();
        if (activeStructuralFixAuditId[gapId] != 0) revert FixAlreadyOpen();

        AuditCell c = AuditCell(cell);
        bytes32 specPassDigest = RunDigests.specRunDigest(specHash, specToolId, true, specErrorsRoot);
        fixAuditId = c.structuralSpawn(
            1, msg.sender, deployedAddress, specHash, specToolId, specPassDigest, bounty, gapId
        );
        structuralAuditKind[fixAuditId] = 2;
        activeStructuralFixAuditId[gapId] = fixAuditId;

        g.state = GapState.FixInAudit;
        g.fixAuditId = fixAuditId;
        _upgrades[fixAuditId] = StructuralUpgradeRecord({
            proposer: msg.sender,
            gapId: gapId,
            passEscrowClaimed: false,
            adoptEscrowClaimed: false,
            exists: true
        });
        emit StructuralFixSubmitted(gapId, fixAuditId);
    }

    /// @notice PC-92 bug_010 / bug_011 (G4(d), I4): the exit for a gap whose audit ended WITHOUT the outcome the gap was
    ///         waiting for. `_onGapVerdict` and `_onFixConfirmed` are the only handlers of the two audits' outcomes, so a
    ///         void or an exploit of either left the gap with no exit and the filer's stake locked.
    ///         - FixInAudit, and the fix audit ended Invalidated or Exploited: the fix failed, the gap did not - it returns to
    ///           GapConfirmed with its fix slot cleared (I1), and the next fix may be submitted.
    ///         - GapFiled, and the gap audit ended Invalidated: nobody adjudicated the gap - it ends GapVoided with the
    ///           filer's stake refunded (VD-117: no adjudicated outcome, no adjudicated loser).
    ///         PULLED, not pushed, and permissionless: it reads the cell's row, so no cell callback (no cell bytes) and no
    ///         counterparty whose call must succeed. Refuses anything else.
    function recoverStructuralGap(uint256 gapId) external nonReentrant {
        NetworkGap storage g = _gaps[gapId];
        AuditCell c = AuditCell(cell);
        if (g.exists && g.state == GapState.FixInAudit) {
            CellTypeDefs.AuditState fs = c.auditStateOf(g.fixAuditId);
            if (fs == CellTypeDefs.AuditState.Invalidated || fs == CellTypeDefs.AuditState.Exploited) {
                activeStructuralFixAuditId[gapId] = 0;
                g.state = GapState.GapConfirmed;
                emit StructuralGapRecovered(gapId, g.fixAuditId, GapState.GapConfirmed);
                return;
            }
        } else if (
            g.exists && g.state == GapState.GapFiled && c.auditStateOf(g.gapAuditId) == CellTypeDefs.AuditState.Invalidated
        ) {
            g.state = GapState.GapVoided;
            if (g.stake > 0 && !g.stakeRefunded) {
                g.stakeRefunded = true;
                if (!c.token().transfer(g.filer, g.stake)) revert StakeTransferFailed();
            }
            emit StructuralGapRecovered(gapId, g.gapAuditId, GapState.GapVoided);
            return;
        }
        revert NothingToRecover();
    }

    function _onGapVerdict(uint256 gapId, uint256 gapAuditId, bytes32 proofHash) internal {
        NetworkGap storage g = _gaps[gapId];
        if (!g.exists || g.state != GapState.GapFiled) revert NoGap();
        g.harnessProofHash = proofHash;
        g.state = GapState.GapConfirmed;
        if (g.stake > 0 && !g.stakeRefunded) {
            g.stakeRefunded = true;
            if (!AuditCell(cell).token().transfer(g.filer, g.stake)) revert StakeTransferFailed();
        }
        emit NetworkGapConfirmed(gapId, gapAuditId, proofHash);
    }

    function _onFixConfirmed(uint256 fixAuditId) internal {
        uint256 gapId = _upgrades[fixAuditId].gapId;
        NetworkGap storage g = _gaps[gapId];
        if (!g.exists || g.state != GapState.FixInAudit) revert NoGap();
        g.state = GapState.Probation;
        g.probationDeadline = block.timestamp + probationWindow;
        g.probationStartBlock = AuditCell(cell).blockHeight();
        emit StructuralFixProposalReady(gapId, fixAuditId);
        emit ProbationStarted(gapId, fixAuditId, g.probationStartBlock);
    }

    function voteStructuralUpgrade(uint256 gapId, bool ok, uint256 workAuditId) external {
        NetworkGap storage g = _gaps[gapId];
        if (!g.exists || g.state != GapState.Probation) revert NotInProbation();
        if (block.timestamp > g.probationDeadline) revert ProbationEnded();
        if (_isJuryExcluded(gapId, msg.sender)) revert ExcludedFromJury();
        if (_gapJuryDutyDeclined[gapId][msg.sender]) revert DeclinedJuryDuty();
        if (_gapJuryVote[gapId][msg.sender] != 0) revert AlreadyVoted();
        if (!_juryQualifies(msg.sender)) revert InsufficientJuryStanding();

        AuditCell c = AuditCell(cell);
        if (c.auditAuditorOf(workAuditId) != msg.sender) revert NotWorkAuditor();
        if (structuralAuditKind[workAuditId] != 0) revert InvalidWorkAudit();
        if (uint256(c.auditStateOf(workAuditId)) != uint256(CellTypeDefs.AuditState.InBlock)) revert WorkNotConfirmed();
        if (c.auditPositiveBlock(workAuditId) < g.probationStartBlock) revert WorkBeforeProbation();
        uint256 workBounty = c.getAudit(workAuditId).bounty;
        if (workBounty < minJuryQualifyingBounty) revert WorkDoesNotQualify();

        uint256 w = _juryVoteWeight(msg.sender);
        uint256 modBps = _juryJudgmentModifierBps(msg.sender);
        if (ok) {
            _gapJuryVote[gapId][msg.sender] = 1;
            g.juryOk += 1;
            g.juryOkW += w;
            jurorOkVoteCount[msg.sender] += 1;
            g.juryOkWC += (w * modBps) / 100;
        } else {
            _gapJuryVote[gapId][msg.sender] = 2;
            g.juryNotOk += 1;
            uint256 wNotOk = _juryNotOkEffectiveWeight(msg.sender);
            g.juryNotOkW += wNotOk;
            g.juryNotOkWC += (wNotOk * modBps) / 100;
        }
        emit UpgradeJuryVote(gapId, g.fixAuditId, msg.sender, workAuditId, ok, g.juryOk, g.juryNotOk, g.juryOkW, g.juryNotOkW);
    }

    function confirmJuryCredit(uint256 gapId) external {
        NetworkGap storage g = _gaps[gapId];
        if (!g.exists) revert NoGap();
        if (g.state != GapState.Adopted) revert NotAdopted();
        if (block.timestamp < g.adoptedAt + opsRegressionWindow) revert RollbackWindowNotElapsed();
        if (_gapJuryVote[gapId][msg.sender] != 1) revert DidNotVoteOk();
        if (_gapJuryCreditClaimed[gapId][msg.sender]) revert CreditAlreadyClaimed();
        _gapJuryCreditClaimed[gapId][msg.sender] = true;
        jurorCorrectOkVoteCount[msg.sender] += 1;
    }

    function adoptStructuralUpgrade(uint256 gapId) external nonReentrant {
        NetworkGap storage g = _gaps[gapId];
        if (!g.exists || g.state != GapState.Probation) revert NotInProbation();
        if (!_juryAdoptSatisfied(g)) revert JuryThresholdNotMet();

        uint256 fixId = g.fixAuditId;
        AuditCell c = AuditCell(cell);
        if (uint256(c.auditStateOf(fixId)) != uint256(CellTypeDefs.AuditState.InBlock)) revert FixNotInBlock();

        address deployed = c.auditDeployedOf(fixId);
        g.priorCanonicalAuditId = canonicalContractAuditId[deployed];
        g.priorCanonicalTier = uint8(canonicalTier[deployed]);
        g.adoptedAt = block.timestamp;
        g.state = GapState.Adopted;

        address proposer = _upgrades[fixId].proposer;
        canonicalContractAuditId[deployed] = fixId;
        canonicalTier[deployed] = CanonicalTier.Probationary;
        canonicalGapIdForDeploy[deployed] = gapId;

        uint256 minted = IIssuanceUpgradeMint(issuanceModule).mintUpgradeAdopt(proposer);

        emit UpgradeBlockMinted(gapId, fixId, proposer, deployed, g.harnessToolId, minted, c.latestBlockHash());
        emit StructuralUpgradeAdopted(gapId, fixId, deployed, uint8(CanonicalTier.Probationary));

        _payStructuralUpgradeEscrow(fixId, EscrowTranche.Adopt, proposer);
    }

    function _payStructuralUpgradeEscrow(uint256 fixAuditId, EscrowTranche tranche, address proposer)
        internal
        returns (uint256 paid)
    {
        AuditCell c = AuditCell(cell);
        if (structuralAuditKind[fixAuditId] != 2) revert NotStructuralFix();
        if (uint256(c.auditStateOf(fixAuditId)) != uint256(CellTypeDefs.AuditState.InBlock)) revert FixNotInBlock();

        StructuralUpgradeRecord storage rec = _upgrades[fixAuditId];
        if (!rec.exists) revert NoStructuralRecord();
        if (proposer != rec.proposer) revert NotProposer();
        if (proposer != c.auditProtocolOf(fixAuditId)) revert ProposerMismatch();

        NetworkGap storage g = _gaps[rec.gapId];
        if (!g.exists) revert NoGap();
        if (tranche == EscrowTranche.Pass) {
            if (g.state != GapState.Probation && g.state != GapState.Adopted) revert NotReadyForPassClaim();
            if (rec.passEscrowClaimed) revert PassTrancheClaimed();
        } else {
            if (g.state != GapState.Adopted) revert NotAdopted();
            if (rec.adoptEscrowClaimed) revert AdoptTrancheClaimed();
        }

        uint256 fullTarget = upgradeProposalPayoutTarget(rec.proposer);
        uint256 trancheTarget;
        if (tranche == EscrowTranche.Pass) {
            trancheTarget = (fullTarget * passPayoutBps) / 10_000;
        } else {
            uint256 passPart = (fullTarget * passPayoutBps) / 10_000;
            trancheTarget = fullTarget > passPart ? fullTarget - passPart : 0;
        }

        address escrow = c.treasuryEscrow();
        if (escrow == address(0)) revert TreasuryEscrowUnset();
        uint256 escrowBal = ICellEscrowStructural(escrow).escrowBalance();
        uint256 cap = (escrowBal * upgradeClaimCapBps) / 10_000;
        uint256 payoutTarget = trancheTarget < cap ? trancheTarget : cap;

        if (tranche == EscrowTranche.Pass) {
            rec.passEscrowClaimed = true;
        } else {
            rec.adoptEscrowClaimed = true;
        }

        if (payoutTarget > 0) {
            paid = ICellEscrowStructural(escrow).payStructuralUpgradeEscrow(
                rec.proposer, payoutTarget, PAY_STRUCTURAL_ESCROW_MAX_ITERATIONS
            );
        }

        emit StructuralUpgradeEscrowPaid(rec.gapId, fixAuditId, uint8(tranche), paid, trancheTarget);
    }

    function promoteCanonicalToOfficial(uint256 gapId) external {
        NetworkGap storage g = _gaps[gapId];
        if (!g.exists || g.state != GapState.Adopted) revert NotAdopted();
        if (block.timestamp < g.adoptedAt + canonicalPromotionDuration) revert PromotionPeriodActive();

        AuditCell c = AuditCell(cell);
        address deployed = c.auditDeployedOf(g.fixAuditId);
        if (canonicalGapIdForDeploy[deployed] != gapId) revert GapDeployMismatch();
        if (canonicalTier[deployed] != CanonicalTier.Probationary) revert NotProbationary();

        canonicalTier[deployed] = CanonicalTier.Official;
        emit CanonicalPromoted(gapId, deployed, g.adoptedAt, g.fixAuditId);
    }

    // bug_001 (DEC-44 paid review; remedy ruled by VD-143(1) as "verify the witness, with store-and-emit").
    //
    // WHAT WAS WRONG, and it is worse than an absent check. The three witness parameters were validated for
    // SHAPE only - non-zero, a registered non-spec tool - which reads at the call site and in the ABI as
    // though a regression proof were required. Nothing compared them to state, nothing stored them, nothing
    // emitted them. So for the whole `opsRegressionWindow` ANY registered eligible non-proposer could
    // un-adopt a legitimate upgrade and call `structuralSlashProposer` on its author, for free, with
    // `(gapId, 0x1, <any registered tool>, 0x1)`. Measured before the fix, not argued: the attack ran green
    // in `StructuralUpgradeFlowCell.t.sol` and the proposer's failed count rose by one.
    //
    // `opsAuditId` IS THE FIX. The witness is no longer three loose hashes; it is a settled audit on this
    // cell, and the four things the signature always implied are now asked of it: it targets THIS deployed
    // contract, it is InBlock, its verdict FAILED, and its recorded tool and proof root are the ones named
    // here. A rollback therefore costs what it always claimed to cost - an actual regression, proven by
    // someone who ran one - and `opsAuditId` rides the event, so the justification is recoverable instead
    // of merely the roller being identifiable (the correction VD-143 made to this finding's first draft).
    //
    // The added parameter is an ABI change on a hull contract, deliberate and signed at G-b. It is the only
    // shape that verifies: nothing indexes (deployed, toolId, resultRoot) back to an audit, and building
    // that index would cost AuditCell storage against 87 bytes of margin. Module-side against 6,152 is
    // VD-107's shape and VD-143's ruling both.
    function rollbackStructuralUpgrade(
        uint256 gapId,
        bytes32 opsSpecHash,
        bytes32 toolId,
        bytes32 resultRoot,
        uint256 opsAuditId
    ) external nonReentrant {
        NetworkGap storage g = _gaps[gapId];
        if (!g.exists || g.state != GapState.Adopted) revert NotAdopted();
        if (block.timestamp > g.adoptedAt + opsRegressionWindow) revert OpsWindowClosed();

        uint256 fixId = g.fixAuditId;
        AuditCell c = AuditCell(cell);
        if (structuralAuditKind[fixId] != 2) revert NotStructuralFix();
        if (uint256(c.auditStateOf(fixId)) != uint256(CellTypeDefs.AuditState.InBlock)) revert FixNotInBlock();

        StructuralUpgradeRecord storage rec = _upgrades[fixId];
        if (!rec.exists) revert NoStructuralRecord();
        if (msg.sender == rec.proposer) revert ProposerCannotRollback();
        (,,, uint256 position,,) = c.auditors(msg.sender);
        if (position == 0) revert NotRegistered();
        if (!c.isEligible(msg.sender)) revert InsufficientHold();

        address deployed = c.auditDeployedOf(fixId);
        if (canonicalTier[deployed] != CanonicalTier.Probationary) revert AlreadyOfficial();
        if (opsSpecHash == bytes32(0) || resultRoot == bytes32(0)) revert ZeroGapSpec();
        (, bool isSpecTool, , , bool toolExists, , ) = c.tools(toolId);
        if (!toolExists || isSpecTool) revert HarnessNotRegistered();

        // THE WITNESS, VERIFIED (bug_001). Four questions the old shape checks only looked like they asked.
        // Order matters for the message a griefer gets: target first, because pointing at the wrong contract
        // is the cheapest forgery once the result root has to exist on chain at all.
        if (c.auditDeployedOf(opsAuditId) != deployed) revert WitnessTargetMismatch();

        // THE STATE PREDICATE IS `Exploited`, ALONE - ruled by VD-153 from the cell's state machine, after
        // this fix's first writing used `InBlock` and the CONTROL TEST caught it. A failing verdict never
        // reaches `InBlock`: `CellLogicLib`:536 opens a VULNERABILITY CLAIM instead, so that predicate
        // would have made this function permanently uncallable - bug_003's failure class, one contract
        // over, introduced by bug_001's fix.
        //
        // The cell has NO state for "a settled failing verdict". It has one for an ADJUDICATED failure:
        // a claim lapses on expiry, returns when a dispute re-audit reproduces the pass, and stands only
        // when a dispute re-audit reproduces the FAILURE - the single write of `Exploited`
        // (`AuditCell`:1268), and terminal. So a rollback now costs a regression a SECOND auditor
        // reproduced under stake, which is a stronger bar than the signature ever advertised.
        if (uint256(c.auditStateOf(opsAuditId)) != uint256(CellTypeDefs.AuditState.Exploited)) {
            revert WitnessNotUpheld();
        }

        // THE PROOF COMES FROM THE CLAIM RECORD, NOT THE AUDIT'S VERDICT FIELDS (VD-153). On the
        // discoverer path - the realistic route for a regression on an already-adopted contract - the
        // audit's `verdictPass`/`verdictToolId`/`proofHash` still describe the PASS THAT WAS OVERTURNED,
        // so checking them would refuse a genuinely exploited contract. The claim record carries the
        // FAILING proof on both paths.
        (, bytes32 claimToolId, bytes32 claimProofHash,,,,,,,,,,) = c.vulnerabilityClaims(opsAuditId);
        if (claimToolId != toolId) revert WitnessToolMismatch();
        if (claimProofHash != resultRoot) revert WitnessResultMismatch();

        // `opsSpecHash` IS VERIFIED, not merely non-zero. Leaving it shape-checked would have reproduced
        // this very defect one field narrower - a parameter that reads as required and is compared to
        // nothing. The vault read this as unfixable without new cell bytes against AuditCell's 87; that
        // premise is false - `AuditCell.audits(id)` already returns `specHash` (position 7), so the check
        // is module-side and costs the cell nothing. Verified beats dropped: the signature keeps its
        // promise instead of retreating from it.
        (,,,,,, bytes32 witnessSpecHash,,,,,,,,,,,,,) = c.audits(opsAuditId);
        if (witnessSpecHash != opsSpecHash) revert WitnessSpecMismatch();

        uint256 priorId = g.priorCanonicalAuditId;
        if (priorId == 0) {
            delete canonicalContractAuditId[deployed];
            canonicalTier[deployed] = CanonicalTier.None;
        } else {
            canonicalContractAuditId[deployed] = priorId;
            canonicalTier[deployed] = CanonicalTier(g.priorCanonicalTier);
        }
        delete canonicalGapIdForDeploy[deployed];
        c.structuralSlashProposer(rec.proposer);

        g.state = GapState.RolledBack;
        rollbackWitnessAuditId[gapId] = opsAuditId;
        emit StructuralUpgradeRolledBack(
            gapId, fixId, priorId, msg.sender, c.latestBlockHash(), opsAuditId, opsSpecHash, toolId, resultRoot
        );
    }

    function expireStructuralUpgrade(uint256 gapId) external {
        NetworkGap storage g = _gaps[gapId];
        if (!g.exists || g.state != GapState.Probation) revert NotInProbation();
        if (block.timestamp <= g.probationDeadline) revert ProbationActive();
        if (_juryAdoptSatisfied(g)) revert JuryThresholdNotMet();
        g.state = GapState.Expired;
        activeStructuralFixAuditId[gapId] = 0;
        emit NetworkGapExpired(gapId, 2);
    }

    function _requireEligible(address actor) internal view {
        AuditCell c = AuditCell(cell);
        (,,, uint256 position,,) = c.auditors(actor);
        if (position == 0) revert NotRegistered();
        if (!c.isEligible(actor)) revert InsufficientHold();
    }

    function _requireOfficialForGapTarget(address target) internal view {
        if (canonicalContractAuditId[target] == 0) return;
        if (canonicalTier[target] != CanonicalTier.Official) revert CanonicalNotOfficial();
    }

    function _isJuryExcluded(uint256 gapId, address auditor) internal view returns (bool) {
        if (auditor == address(0)) return true;
        NetworkGap storage g = _gaps[gapId];
        if (auditor == g.filer) return true;
        AuditCell c = AuditCell(cell);
        if (g.fixAuditId != 0 && auditor == c.auditAuditorOf(g.fixAuditId)) return true;
        if (g.gapAuditId != 0 && auditor == c.auditAuditorOf(g.gapAuditId)) return true;
        return false;
    }

    function _juryQualifies(address auditor) internal view returns (bool) {
        AuditCell c = AuditCell(cell);
        (uint256 successful, uint256 failed, uint256 found,,,) = c.auditors(auditor);
        if (successful < minSuccessfulForJury) return false;
        if (!c.isEligible(auditor)) return false;
        if (failed > found && successful < failed) return false;
        return true;
    }

    function _juryVoteWeight(address auditor) internal view returns (uint256) {
        (uint256 successful,,,,,) = AuditCell(cell).auditors(auditor);
        uint256 bonus = successful / 10;
        if (bonus > 2) bonus = 2;
        return 1 + bonus;
    }

    function _juryNotOkEffectiveWeight(address auditor) internal view returns (uint256) {
        uint256 w = _juryVoteWeight(auditor);
        (uint256 successful,,,,,) = AuditCell(cell).auditors(auditor);
        if (successful >= 10) {
            return w + 1;
        }
        return w;
    }

    function _juryJudgmentModifierBps(address auditor) internal view returns (uint256) {
        uint256 okVotes = jurorOkVoteCount[auditor];
        uint256 prior = populationJudgmentPriorBps;
        if (okVotes == 0) return prior;
        uint256 correctOk = jurorCorrectOkVoteCount[auditor];
        uint256 individualBps = (correctOk * 10_000) / okVotes;
        return (okVotes * individualBps + kJury * prior) / (okVotes + kJury);
    }

    function _juryAdoptSatisfied(NetworkGap storage g) internal view returns (bool) {
        if (g.juryOkW < juryOkRequired) return false;
        if (g.juryOkW < g.juryNotOkW + juryNetRequired) return false;
        if (g.juryOkWC > 0) {
            if (g.juryOkWC < juryOkWCRequired) return false;
            if (g.juryOkWC < g.juryNotOkWC + juryNetWCRequired) return false;
        }
        return true;
    }
}

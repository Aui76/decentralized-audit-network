// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./IClaimSettlementMutator.sol";
import "./AuditCell.sol";
import "./CellStorage.sol";
import "./SpecArbiterModule.sol";

interface ICellEscrowIntegrity {
    function payIntegrityReviewSubsidy(uint256 amount, uint256 maxIterations) external returns (uint256);
    function recordIntegrityReturn(uint256 amount) external;
}

/// @title IntegrityReviewModule — F-52 overlay (X4): wash/collusion review on audit row O.
/// @notice Settlement-touching L1 satellite; lock + sustained void via cell hook (same seam as X1).
contract IntegrityReviewModule {
    enum IntegrityReviewStatus {
        None,
        Open,
        VerdictSubmitted,
        Cleared,
        Sustained,
        Expired
    }

    struct IntegrityReview {
        address opener;
        address reviewer;
        bytes32 integrityToolId;
        bytes32 resultRoot;
        bool pass;
        uint256 bountyAmount;
        uint256 treasuryMatchAmount;
        uint256 filingStake;
        uint256 openedAt;
        uint256 verdictSubmittedAt;
        IntegrityReviewStatus status;
        bool contested;
        bool contestPass;
        bytes32 contestResultRoot;
        uint256 contestStake;
    }

    address public admin;
    address public cell;
    address public specArbiterModule;
    bool public wiringLocked;

    uint256 public integrityFilingStake = 100 ether;
    uint256 public integrityReviewWindow = 7 days;
    uint256 public integrityContestWindow = 2 days;
    uint256 public integrityContestStake = 500 ether;
    uint256 public integrityMatchBps;

    mapping(uint256 => IntegrityReview) internal _reviews;

    event IntegrityReviewOpened(
        uint256 indexed auditId,
        address indexed opener,
        bytes32 indexed integrityToolId,
        uint256 bountyAmount,
        uint256 treasuryMatch
    );
    event IntegrityVerdictSubmitted(uint256 indexed auditId, address indexed reviewer, bool pass, bytes32 resultRoot);
    event IntegrityReviewContested(
        uint256 indexed auditId, address indexed protocol, bool pass, bytes32 resultRoot, uint256 stake
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
    error NotProtocol();
    error AlreadyContested();
    error ContestMustOppose();
    error StakeTransferFailed();
    error TransferFailed();
    error ReentrantCall();

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private constant _PAY_MAX_ITER = 64;
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
        integrityContestStake = v;
        emit ParameterUpdated("integrityContestStake", v);
    }

    function setIntegrityMatchBps(uint256 v) external onlyAdmin {
        integrityMatchBps = v;
        emit ParameterUpdated("integrityMatchBps", v);
    }

    function integrityReviewStatusOf(uint256 auditId) external view returns (IntegrityReviewStatus) {
        return _reviews[auditId].status;
    }

    function confirmBlocked(uint256 auditId) external view returns (bool) {
        IntegrityReviewStatus s = _reviews[auditId].status;
        return s == IntegrityReviewStatus.Open || s == IntegrityReviewStatus.VerdictSubmitted;
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

        uint256 treasuryMatch;
        address escrow = host.treasuryEscrow();
        if (escrow != address(0) && integrityMatchBps > 0) {
            uint256 requested = (bountyAmount * integrityMatchBps) / 10_000;
            if (requested > 0) {
                treasuryMatch = ICellEscrowIntegrity(escrow).payIntegrityReviewSubsidy(requested, _PAY_MAX_ITER);
            }
        }

        _reviews[auditId] = IntegrityReview({
            opener: msg.sender,
            reviewer: address(0),
            integrityToolId: integrityToolId,
            resultRoot: bytes32(0),
            pass: false,
            bountyAmount: bountyAmount,
            treasuryMatchAmount: treasuryMatch,
            filingStake: filing,
            openedAt: block.timestamp,
            verdictSubmittedAt: 0,
            status: IntegrityReviewStatus.Open,
            contested: false,
            contestPass: false,
            contestResultRoot: bytes32(0),
            contestStake: 0
        });

        emit IntegrityReviewOpened(auditId, msg.sender, integrityToolId, bountyAmount, treasuryMatch);
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

    function contestIntegrityVerdict(uint256 auditId, bool pass, bytes32 resultRoot) external nonReentrant {
        IntegrityReview storage r = _reviews[auditId];
        if (r.status != IntegrityReviewStatus.VerdictSubmitted) revert NoVerdict();
        if (msg.sender != AuditCell(cell).auditProtocolOf(auditId)) revert NotProtocol();
        if (r.contested) revert AlreadyContested();
        if (block.timestamp >= r.verdictSubmittedAt + integrityContestWindow) revert ContestWindowClosed();
        if (pass == r.pass) revert ContestMustOppose();
        if (resultRoot == bytes32(0)) revert ResultRootRequired();

        uint256 stake = integrityContestStake;
        if (stake > 0) {
            _settlement().settlementToken(0, msg.sender, address(this), stake);
        }

        r.contested = true;
        r.contestPass = pass;
        r.contestResultRoot = resultRoot;
        r.contestStake = stake;

        emit IntegrityReviewContested(auditId, msg.sender, pass, resultRoot, stake);
    }

    function finalizeIntegrityReview(uint256 auditId) external nonReentrant {
        IntegrityReview storage r = _reviews[auditId];
        if (r.status != IntegrityReviewStatus.VerdictSubmitted) revert NoVerdict();
        if (block.timestamp < r.verdictSubmittedAt + integrityContestWindow) revert ContestWindowOpen();

        address reviewer = r.reviewer;
        uint256 openerBounty = r.bountyAmount;
        uint256 treasuryMatch = r.treasuryMatchAmount;
        uint256 filing = r.filingStake;
        bool finalPass = r.contested ? r.contestPass : r.pass;

        r.status = finalPass ? IntegrityReviewStatus.Cleared : IntegrityReviewStatus.Sustained;

        IClaimSettlementMutator s = _settlement();
        if (finalPass) {
            s.settlementToken(1, address(this), reviewer, openerBounty);
            _returnTreasuryMatch(treasuryMatch);
        } else {
            s.settlementToken(1, address(this), reviewer, openerBounty + treasuryMatch);
        }
        if (filing > 0) {
            s.settlementToken(1, address(this), r.opener, filing);
        }
        if (r.contested && r.contestStake > 0) {
            s.settlementToken(1, address(this), AuditCell(cell).auditProtocolOf(auditId), r.contestStake);
        }
        if (!finalPass) {
            s.settlementOverlay(1, 2, auditId, address(0));
        }

        emit IntegrityReviewFinalized(
            auditId, reviewer, finalPass, finalPass ? openerBounty : openerBounty + treasuryMatch
        );
    }

    function expireIntegrityReview(uint256 auditId) external nonReentrant {
        IntegrityReview storage r = _reviews[auditId];
        if (r.status != IntegrityReviewStatus.Open) revert ReviewNotOpen();
        if (block.timestamp <= r.openedAt + integrityReviewWindow) revert ReviewWindowOpen();

        address opener = r.opener;
        uint256 filing = r.filingStake;
        uint256 bounty = r.bountyAmount;
        uint256 treasuryMatch = r.treasuryMatchAmount;

        r.status = IntegrityReviewStatus.Expired;

        IClaimSettlementMutator s = _settlement();
        if (filing > 0) {
            s.settlementToken(2, address(this), address(0), filing);
        }
        _returnTreasuryMatch(treasuryMatch);
        if (bounty > 0) {
            s.settlementToken(1, address(this), opener, bounty);
        }

        emit IntegrityReviewExpired(auditId, opener, filing);
    }

    function _returnTreasuryMatch(uint256 amount) internal {
        if (amount == 0) return;
        address escrow = AuditCell(cell).treasuryEscrow();
        if (escrow == address(0)) return;
        IClaimSettlementMutator s = _settlement();
        s.settlementToken(1, address(this), escrow, amount);
        ICellEscrowIntegrity(escrow).recordIntegrityReturn(amount);
    }
}

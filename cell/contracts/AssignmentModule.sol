// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./IAssignmentModule.sol";
import "./AuditCell.sol";

/// @title AssignmentModule — X7 live constrained random draw (RandomConstrained).
/// @notice L1 satellite holding the ordinary-audit assignment policy. The cell delegates ordinary
///         selection here and falls back to its in-cell FIFO head when this returns address(0).
///         Dispute lanes use in-cell CRD + ClaimDisputeModule exclusion gate (R8/R9).
///         Settlement independence is unchanged — it is exclusion-based, not draw-based. This module only
///         SELECTS who audits; it never settles, pays, or voids (no-logic-jumps).
///
/// REQUIRED CELL-SIDE WIRING (builder, accompanies this satellite — see proposal §4):
///   - storage: address assignmentModule (AppStorage Layout) + getter; setter setAssignmentModule(addr)
///   - CellLogicLib.findEligibleAuditor (ordinary lane):
///       address chosen = L.assignmentModule == address(0)
///           ? <existing FIFO find>
///           : IAssignmentModule(L.assignmentModule).pickOrdinary(id, protocol);
///       if (chosen == address(0)) chosen = <existing FIFO find>;   // liveness fallback
///   - reject path  → noteReject(id, auditor); decline path → noteDecline(id, auditor)
///   - confirm path → noteCompletion(protocol, auditor)
///   - findDisputeAuditor: CRD in CellLogicLib + disputeCandidateBlocked on ClaimDisputeModule.
///
/// Entropy is blockhash-based: sequencer-influenceable, ACCEPTABLE for a no-real-value testnet
/// (documented). A commit-reveal salt is the mainnet hardening (ledger §4b / mainnet-freeze agenda).
contract AssignmentModule is IAssignmentModule {
    address public admin;
    address public cell;
    bool public wiringLocked;

    AssignmentMode public assignmentMode = AssignmentMode.RandomConstrained;
    uint256 public maxDyadRepeats; // 0 = strict no-repeat (a completed pair is excluded thereafter)

    mapping(uint256 => mapping(address => bool)) public rejectedOnAudit;
    mapping(address => mapping(address => uint256)) public protocolAuditorCompleted;
    mapping(uint256 => uint256) internal _draws; // per-audit re-roll counter (entropy variation)

    uint256 internal constant MAX_SCAN = 256; // gas bound on the pool walk (testnet posture)

    event AssignmentModuleWired(address indexed cell);
    event AssignmentCandidates(uint256 indexed auditId, uint256 eligibleCount, address chosen);
    event AssignmentRejectNoted(uint256 indexed auditId, address indexed auditor);
    event AssignmentCompletionNoted(address indexed protocol, address indexed auditor, uint256 count);
    event ParameterUpdated(string indexed name, uint256 value);

    error NotAdmin();
    error NotCell();
    error WiringLocked();
    error HostUnset();

    constructor(address _admin) {
        admin = _admin;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyCell() {
        if (msg.sender != cell) revert NotCell();
        _;
    }

    function wire(address _cell) external onlyAdmin {
        if (wiringLocked) revert WiringLocked();
        if (_cell == address(0)) revert HostUnset();
        cell = _cell;
        wiringLocked = true;
        emit AssignmentModuleWired(_cell);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert NotAdmin();
        admin = newAdmin;
    }

    function setAssignmentMode(AssignmentMode m) external onlyAdmin {
        assignmentMode = m;
        emit ParameterUpdated("assignmentMode", uint256(m));
    }

    function setMaxDyadRepeats(uint256 n) external onlyAdmin {
        maxDyadRepeats = n;
        emit ParameterUpdated("maxDyadRepeats", n);
    }

    // ------------------------------------------------------------------ selection

    /// @inheritdoc IAssignmentModule
    function pickOrdinary(uint256 auditId, address protocol) external onlyCell returns (address) {
        if (cell == address(0)) revert HostUnset();
        if (assignmentMode == AssignmentMode.QueueFifo) {
            return address(0); // cell uses its FIFO head
        }

        AuditCell ac = AuditCell(cell);
        address tok = address(ac.token());

        uint256 seed = uint256(keccak256(abi.encode(blockhash(block.number - 1), auditId, _draws[auditId]++)));

        address chosen = address(0);
        uint256 eligibleCount = 0;
        uint256 scanned = 0;
        uint256 maxScan = ac.queueLength();
        if (maxScan > MAX_SCAN) maxScan = MAX_SCAN;

        address candidate = ac.queueHead();
        while (candidate != address(0) && scanned < maxScan) {
            if (_isCandidate(ac, tok, auditId, protocol, candidate)) {
                eligibleCount += 1;
                // Reservoir sampling, k=1: replace the chosen element with probability 1/eligibleCount,
                // using an independent per-step draw so the result is uniform over the eligible set.
                uint256 r = uint256(keccak256(abi.encode(seed, eligibleCount)));
                if (r % eligibleCount == 0) {
                    chosen = candidate;
                }
            }
            candidate = ac.queueNext(candidate);
            scanned += 1;
        }

        emit AssignmentCandidates(auditId, eligibleCount, chosen);
        return chosen; // address(0) → cell FIFO fallback (liveness)
    }

    function _isCandidate(AuditCell ac, address tok, uint256 auditId, address protocol, address cand)
        internal
        view
        returns (bool)
    {
        if (cand == protocol) return false;
        if (rejectedOnAudit[auditId][cand]) return false;
        // Dyad cap: a pair that has completed more than maxDyadRepeats audits is excluded.
        // maxDyadRepeats == 0 → strict no-repeat (any completed pairing excludes).
        if (protocolAuditorCompleted[protocol][cand] > maxDyadRepeats) return false;
        // Eligibility: token balance >= position-scaled required hold (mirrors CellLogicLib.requiredHold).
        (,,, uint256 position,,) = ac.auditors(cand);
        uint256 required = position == 0 ? ac.auditorCount() * ac.increment() : (position - 1) * ac.increment();
        return _balanceOf(tok, cand) >= required;
    }

    function _balanceOf(address tok, address who) internal view returns (uint256) {
        (bool ok, bytes memory data) = tok.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    // ------------------------------------------------------------------ onlyCell hooks

    /// @inheritdoc IAssignmentModule
    function noteReject(uint256 auditId, address auditor) external onlyCell {
        rejectedOnAudit[auditId][auditor] = true;
        emit AssignmentRejectNoted(auditId, auditor);
    }

    /// @inheritdoc IAssignmentModule
    function noteDecline(uint256 auditId, address auditor) external onlyCell {
        rejectedOnAudit[auditId][auditor] = true;
        emit AssignmentRejectNoted(auditId, auditor);
    }

    /// @inheritdoc IAssignmentModule
    function noteCompletion(address protocol, address auditor) external onlyCell {
        uint256 c = ++protocolAuditorCompleted[protocol][auditor];
        emit AssignmentCompletionNoted(protocol, auditor, c);
    }
}

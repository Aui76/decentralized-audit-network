// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @title RehearsalTimelock — THE REHEARSAL RIG. NEVER THE PRODUCTION TIMELOCK.
///
/// @notice ⚠ THIS CONTRACT MUST NOT BE DEPLOYED TO ANY CELL THAT HOLDS VALUE, AND MUST NOT BE THE
///         TARGET OF A REAL `transferAdmin`. Production deploys OpenZeppelin's `TimelockController`
///         under DR-3 — audited, standard, and pinned at a named commit as part of the value-bearing
///         deploy prep. This file exists for one purpose and expires with it.
///
/// WHY IT EXISTS, and the reasoning is the whole point (VD-65, 2026-08-30). The load-bearing unknown
/// was never OpenZeppelin's code. `TimelockController` is audited and has been deployed ten thousand
/// times. What has run ZERO times is **this repo's step 8** — the cell's own admin handoff:
/// `AuditCell.transferAdmin(timelock)`, every module following, the deployer EOA provably powerless,
/// and the way back out.
///
/// That sequence has already produced one permanent-on-mainnet defect, caught on paper, and the
/// receipt is in the code at `IssuanceModule.sol`:184: *"Without this the deploy sequence cannot hand
/// the module to the Timelock (Section 3 step 8 / DR-3): the constructor bound admin and nothing could
/// change it. Found 2026-08-01 by rehearsing the sequence on paper — on an immutable mainnet cell it
/// would have been PERMANENT."* If there is a next one, it lives in the same place, and a queue /
/// ETA / execute / cancel rig exercises it completely.
///
/// WHAT IT DOES NOT PROVE, stated on its face so no reader has to infer it. G-27's §5.1 discharges
/// only PARTIALLY through this rig: the SEQUENCE, the DELAY semantics and the CANCEL semantics are
/// proven; OZ-specific integration is not, and remains owed at the value-bearing deploy. A rehearsal
/// that claimed more than it exercised would be worse than none.
///
/// PLACEMENT IS DELIBERATE. `cell/script/` — not `cell/contracts/`. The hull freeze at `e69a932`
/// watches `cell/contracts/` only, so this file adds ZERO hull bytes and `remappings.txt` is
/// untouched. It is also excluded from the public export by `PUBLISHING.md`'s rule that only `.s.sol`
/// scripts ship.
///
/// AND IT IS PROVEN BEFORE ANYTHING LEANS ON IT (VD-65 condition 3). An unproven rig injects
/// misattributed failures into the very rehearsal it serves: if the rehearsal fails you must be able
/// to say it was the SEQUENCE and not the rig. `cell/test/RehearsalTimelock.t.sol` drives the red
/// directions — execute before the ETA reverts, a cancelled call cannot execute, a non-proposer
/// cannot queue — before the rehearsal script exists.
contract RehearsalTimelock {
    address public immutable proposer;
    uint256 public immutable delay;

    /// @dev 0 means NOT QUEUED. Every guard below reads this one word, so there is no second place
    ///      for the queue's state to disagree with itself.
    mapping(bytes32 => uint256) public etaOf;

    event Queued(bytes32 indexed id, address target, bytes data, uint256 eta);
    event Cancelled(bytes32 indexed id);
    event Executed(bytes32 indexed id, address target, bytes data);

    error NotProposer(address caller);
    error AlreadyQueued(bytes32 id);
    error NotQueued(bytes32 id);
    error TooEarly(bytes32 id, uint256 eta, uint256 nowTime);
    error CallReverted(bytes32 id, bytes returndata);
    error ZeroProposer();

    constructor(address proposer_, uint256 delay_) {
        // A zero proposer would make every queue() revert and the rig would look "safe" while being
        // simply inert — the shape this repo calls a decorative guard.
        if (proposer_ == address(0)) revert ZeroProposer();
        proposer = proposer_;
        delay = delay_;
    }

    function idOf(address target, bytes calldata data) public pure returns (bytes32) {
        return keccak256(abi.encode(target, data));
    }

    function queue(address target, bytes calldata data) external returns (bytes32 id) {
        if (msg.sender != proposer) revert NotProposer(msg.sender);
        id = idOf(target, data);
        if (etaOf[id] != 0) revert AlreadyQueued(id);
        uint256 eta = block.timestamp + delay;
        etaOf[id] = eta;
        emit Queued(id, target, data, eta);
    }

    /// @notice The cancel path. This is the one Guardian criterion 3 is about, and the reason the rig
    ///         exists at all rather than a bare `transferAdmin` to a second EOA: a cancel path whose
    ///         executor has never executed it is UNPROVEN, not merely untested.
    function cancel(bytes32 id) external {
        if (msg.sender != proposer) revert NotProposer(msg.sender);
        if (etaOf[id] == 0) revert NotQueued(id);
        delete etaOf[id];
        emit Cancelled(id);
    }

    function execute(address target, bytes calldata data) external payable {
        bytes32 id = idOf(target, data);
        uint256 eta = etaOf[id];
        if (eta == 0) revert NotQueued(id);
        if (block.timestamp < eta) revert TooEarly(id, eta, block.timestamp);
        // Cleared BEFORE the call: a target that re-enters must not find the entry still live. The
        // production timelock does the same and for the same reason.
        delete etaOf[id];
        (bool ok, bytes memory ret) = target.call{value: msg.value}(data);
        if (!ok) revert CallReverted(id, ret);
        emit Executed(id, target, data);
    }

    receive() external payable {}
}

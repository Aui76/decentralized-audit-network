// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/CellToken.sol";
import "../contracts/IntegrityReviewModule.sol";
import "../contracts/IAssignmentModule.sol";
import "./helpers/CellTestDeploy.sol";

contract DrawTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @dev PC-95(1): an assignment module that returns whatever it is told to, including an address that is not in the queue,
///      not eligible, or the audit's own protocol. The real module cannot do this today - the point of the row is that the
///      CELL does not check, so an admin-set module (or a later version of it) is trusted absolutely.
contract PickStub is IAssignmentModule {
    address public pick;
    function setPick(address a) external { pick = a; }
    function pickOrdinary(uint256, address) external view returns (address) { return pick; }
    function noteReject(uint256, address) external {}
    function noteDecline(uint256, address) external {}
    function noteCompletion(address, address) external {}
    function assignmentMode() external pure returns (AssignmentMode) { return AssignmentMode.RandomConstrained; }
    function maxDyadRepeats() external pure returns (uint256) { return 0; }
    function rejectedOnAudit(uint256, address) external pure returns (bool) { return false; }
    function protocolAuditorCompleted(address, address) external pure returns (uint256) { return 0; }
}

/// @notice The hull window's G5 (walkthrough section 3, invariant I5: THE ADJUDICATOR IS NEVER A PARTY - every draw excludes
///         every address with a stake in the outcome, and the module's pick is validated by the cell, not trusted).
///
///         PC-99: the integrity contest's re-audit names the REVIEWER as its one extra exclusion and never the OPENER, who
///         recovers the bounty and gets the auditor a failure when the review's FAIL stands. On a small queue the opener is
///         drawn to judge their own review.
///         PC-95(1): `findEligibleAuditor` returns `pickOrdinary`'s choice with no queue-membership, eligibility or
///         protocol-exclusion check, unlike the fallback scan directly below it.
contract DrawsNeverPartyTest is Test {
    CellToken token;
    AuditCell cell;
    IntegrityReviewModule integrity;
    CellTestDeploy.Deployment d;

    address protocol = address(0xA11CE);
    address auditorA = address(0xB0B);
    address opener = address(0x0FE4);
    address reviewer = address(0x4E71);
    address neutral = address(0x4E07);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 integrityToolId = keccak256("integrity.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");

    uint256 constant BOUNTY = 40 ether;
    uint256 nextSalt = 1;

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        integrity = d.integrityReviewModule;
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        cell.registerTool(integrityToolId, false);
        token.genesisMint(protocol, 10_000 ether);
        token.genesisMint(opener, 10_000 ether);
        token.genesisMint(reviewer, 1_000 ether);
        token.genesisMint(auditorA, 1_000 ether);
        CellTestDeploy.attachMinter(d);
    }

    function _declared() internal view returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = verdictToolId;
    }

    function _register(address a) internal {
        vm.prank(a);
        cell.register();
    }

    /// An audit passed by `auditorA` and sitting in AwaitingWindow, which is where an integrity review may open.
    function _passedAudit() internal returns (uint256 id) {
        DrawTarget t = new DrawTarget(nextSalt++);
        vm.startPrank(protocol);
        token.approve(address(cell), BOUNTY);
        id = cell.submitAudit(address(t), address(t).codehash, specHash, specToolId, specErrors, BOUNTY, _declared(), 0, 0);
        vm.stopPrank();
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditorA);
        cell.provePass(id, verdictToolId, resultRoot);
    }

    /// A review opened by `opener`, a FAIL verdict by `reviewer`, contested by the harmed auditor - which spawns the
    /// re-audit whose auditor the cell draws.
    function _contestedReview(uint256 id) internal returns (uint256 disputeId) {
        uint256 reviewBounty = 10 ether;
        vm.startPrank(opener);
        token.approve(address(cell), integrity.integrityFilingStake() + reviewBounty);
        integrity.openIntegrityReview(id, integrityToolId, reviewBounty);
        vm.stopPrank();
        vm.prank(reviewer);
        integrity.submitIntegrityVerdict(id, false, keccak256("integrity-fail"));
        vm.startPrank(auditorA); // the SUSTAINED verdict harms the auditor, so the auditor has standing
        token.approve(address(cell), integrity.integrityContestStake() + reviewBounty);
        integrity.contestIntegrityVerdict(id, true, keccak256("integrity-pass"));
        vm.stopPrank();
        disputeId = integrity.activeIntegrityDisputeId(id);
    }

    // ------------------------------------------------------------------ PC-99

    /// I5: the OPENER profits from the review they opened, so the draw that adjudicates it must exclude them. With a queue
    /// holding only parties, the right answer is NO ADJUDICATOR - the contest then has its own unstick path - and never the
    /// opener. RED before the cure: the opener is drawn.
    function test_G5_the_integrity_contest_draw_excludes_the_opener() public {
        _register(auditorA);
        _register(opener);
        _register(reviewer);
        uint256 id = _passedAudit();
        uint256 disputeId = _contestedReview(id);

        address drawn = cell.auditAuditorOf(disputeId);
        assertTrue(drawn != opener, "the opener must not judge the review it opened");
        assertTrue(drawn != reviewer, "nor the reviewer whose verdict is contested");
        assertTrue(drawn != auditorA && drawn != protocol, "nor either party to the audit");
        assertEq(drawn, address(0), "on this queue every candidate is a party, so nobody is drawn");

        // I4 stays satisfied: the contest that cannot be adjudicated still ends.
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        integrity.expireContestedIntegrityReview(id);
        assertEq(uint256(cell.auditStateOf(disputeId)), uint256(CellTypeDefs.AuditState.Invalidated), "the row ended");
    }

    /// The companion that proves the cure excludes rather than breaks: with one neutral registrant in the queue, the draw
    /// lands on them.
    function test_G5_a_neutral_registrant_is_still_drawn_for_the_contest() public {
        _register(auditorA);
        _register(opener);
        _register(reviewer);
        _register(neutral);
        uint256 id = _passedAudit();
        uint256 disputeId = _contestedReview(id);
        assertEq(cell.auditAuditorOf(disputeId), neutral, "the one address with no stake in the outcome");
    }

    // ------------------------------------------------------------------ PC-95(1)

    /// The cell must validate the assignment module's pick the way its own fallback scan does: in the queue, eligible, and
    /// not the audit's protocol. RED before the cure: the cell hands the row to whatever the module names.
    function test_G5_an_assignment_modules_pick_is_validated_by_the_cell() public {
        _register(auditorA);
        PickStub stub = new PickStub();
        cell.setAssignmentModule(address(stub));

        // (a) an address that never registered
        stub.setPick(address(0xDEADBEEF));
        uint256 id = _submitOnly();
        assertEq(cell.auditAuditorOf(id), auditorA, "an unregistered pick is refused; the FIFO scan answers instead");

        // (b) the audit's own protocol, which the scan skips by name
        stub.setPick(protocol);
        uint256 id2 = _submitOnly();
        assertEq(cell.auditAuditorOf(id2), auditorA, "the protocol may never audit its own row");

        // (c) a registered auditor who no longer meets the hold - the eligibility the scan checks
        _register(reviewer);
        cell.setIncrement(500 ether); // requiredHold = (auditorCount - 1) * increment
        uint256 all = token.balanceOf(reviewer); // read BEFORE the prank, which binds to the very next call
        vm.prank(reviewer);
        token.transfer(protocol, all); // reviewer can no longer meet the hold
        stub.setPick(reviewer);
        uint256 id3 = _submitOnly();
        assertTrue(cell.auditAuditorOf(id3) != reviewer, "an ineligible pick is refused");
    }

    function _submitOnly() internal returns (uint256 id) {
        DrawTarget t = new DrawTarget(nextSalt++);
        vm.startPrank(protocol);
        token.approve(address(cell), BOUNTY);
        id = cell.submitAudit(address(t), address(t).codehash, specHash, specToolId, specErrors, BOUNTY, _declared(), 0, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ VD-223(1): the pending exclude is keyed to its lane

    /// The second exclude travels from the spawning module to its own spawn through a pending slot. VD-223(1) keys that slot
    /// on the SPAWNING MODULE: consumed by that module's next spawn, and invisible to every other lane. Keyed on the original
    /// alone, an orphaned value would be consumed by the next spawn on that original from ANY lane - excluding a non-party
    /// from a claim dispute's draw. RED before the keying: the claim-lane spawn consumes the integrity-set value.
    function test_G5_the_pending_exclude_is_consumed_by_its_own_lane_and_invisible_to_others() public {
        _register(auditorA);
        _register(opener);
        _register(reviewer);
        uint256 id = _passedAudit();
        // On this original, with the reviewer excluded, the only candidate left is `opener`.
        address im = address(integrity);
        address cm = address(d.claimModule);

        // (1) the value is read by its own lane's spawn ...
        vm.prank(im);
        cell.settlementSetDisputeExclude2(id, opener);
        vm.prank(im);
        uint256 d1 = cell.spawnDisputeReaudit(id, 0, im, reviewer, integrityToolId, im);
        assertEq(cell.auditAuditorOf(d1), address(0), "the integrity lane excluded its second party");

        // (2) ... and consumed by it: the next integrity spawn sees an empty slot.
        vm.prank(im);
        uint256 d2 = cell.spawnDisputeReaudit(id, 0, im, reviewer, integrityToolId, im);
        assertEq(cell.auditAuditorOf(d2), opener, "consumed: the slot reads zero after the spawn that used it");

        // (3) containment: an integrity-set value is invisible to a claim-lane spawn on the same original ...
        vm.prank(im);
        cell.settlementSetDisputeExclude2(id, opener);
        vm.prank(cm);
        uint256 d3 = cell.spawnDisputeReaudit(id, 0, cm, reviewer, verdictToolId, address(0));
        assertEq(cell.auditAuditorOf(d3), opener, "the claim lane does not read the integrity lane's exclude");

        // (4) ... and still waiting for the lane that set it.
        vm.prank(im);
        uint256 d4 = cell.spawnDisputeReaudit(id, 0, im, reviewer, integrityToolId, im);
        assertEq(cell.auditAuditorOf(d4), address(0), "not consumed by the other lane");
    }
}

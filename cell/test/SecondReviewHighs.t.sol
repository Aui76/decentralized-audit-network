// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./helpers/SpecValidationCellSetup.sol";
import "../contracts/SpecArbiterModule.sol";

contract HighTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice Three HIGH findings of the 2026-09-15 second-family review of the fresh scope (VD-180; record
///         OnAir/records/REVIEW-2026-09-15-cursor-cli-gpt56sol-fresh-scope.md), verified by the vault by reading and
///         REPRODUCED here in execution. Each test PINNED THE DEFECT AS IT STOOD; every cure is hull bytes in the
///         2026-09-16 hull window and flips its test. bug_002 and bug_003 FLIPPED in G4; bug_001 FLIPPED in G6.
contract SecondReviewHighsTest is SpecValidationCellSetup {
    CellTestDeploy.Deployment d;
    CellToken token;
    AuditCell cell;
    SpecArbiterModule specArbiter;

    address protocol = address(0xBEEF);
    address auditor = address(0xA11CE);
    address challenger = address(0xCAFE);
    address stranger = address(0x5712A);

    bytes32 specToolId = keccak256("spec-tool");
    bytes32 verdictToolId = keccak256("audit-tool");
    bytes32 specHash = keccak256("spec-hash");
    bytes32 failErrorsRoot = keccak256("spec-tool-errors");
    bytes32 resultRoot = keccak256("verdict-pass");

    function setUp() external {
        d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        specArbiter = d.specArbiterModule;
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        specArbiter.setSpecChallengeFee(100 ether);
        specArbiter.setSpecChallengeStake(500 ether);
        token.genesisMint(protocol, 100_000 ether);
        token.genesisMint(challenger, 10_000 ether);
        CellTestDeploy.attachMinter(d);
    }

    function _declared() internal view returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = verdictToolId;
    }

    /// bug_001 (HIGH), FLIPPED in G6 (PC-89, I6): `submitGenesisAudit` had no caller check and no registration requirement,
    /// so while genesis was pending ANYONE took the one-shot genesis slot. The slot now belongs to the admin, or to a genesis
    /// protocol the admin names, from the deploy block on. The intended protocol - named here - takes it; the stranger does not.
    function test_G6_a_stranger_cannot_occupy_the_one_shot_genesis_slot() public {
        assertTrue(cell.genesisPending(), "precondition: genesis pending");
        (bool named,) = address(cell).call(
            abi.encodeWithSignature("setGenesisBootstrap(address,address)", protocol, address(0))
        );
        assertTrue(named, "the admin names the genesis protocol");

        HighTarget t = new HighTarget(1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("NotGenesisProtocol()"));
        cell.submitGenesisAudit(address(t), address(t).codehash, specHash, specToolId, EMPTY_SPEC_ERRORS,
                                5000 ether, _declared(), 0, 0);
        assertFalse(cell.genesisAuditOpen(), "the slot is still open for its owner");

        HighTarget t2 = new HighTarget(2);
        vm.prank(protocol);
        uint256 id = cell.submitGenesisAudit(address(t2), address(t2).codehash, specHash, specToolId, EMPTY_SPEC_ERRORS,
                                             5000 ether, _declared(), 0, 0);
        assertEq(cell.genesisAuditId(), id, "the named bootstrap protocol holds the slot");
        assertEq(cell.auditProtocolOf(id), protocol);
    }

    /// bug_002 (HIGH), FLIPPED in G4(e) (PC-90): the requested audit window had a floor and no ceiling, so
    /// `windowStart + auditWindow` in the confirm path REVERTED under checked arithmetic forever. Intake now refuses a
    /// request above `MAX_AUDIT_WINDOW` - a revert, not a clamp, so the submitter sees it - and the ceiling itself confirms.
    function test_G4e_a_requested_window_above_the_ceiling_is_refused_at_intake() public {
        vm.prank(auditor);
        cell.register();
        HighTarget t = new HighTarget(3);
        uint256 bounty = 1_000 ether;
        uint256 ceiling = cell.MAX_AUDIT_WINDOW(); // read BEFORE expectRevert, which would otherwise bind to this call
        vm.startPrank(protocol);
        token.approve(address(cell), 2 * bounty);
        vm.expectRevert(abi.encodeWithSignature("AuditWindowTooLong()"));
        cell.submitAudit(address(t), address(t).codehash, specHash, specToolId, EMPTY_SPEC_ERRORS, bounty,
                         _declared(), 0, type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("AuditWindowTooLong()"));
        cell.submitAudit(address(t), address(t).codehash, specHash, specToolId, EMPTY_SPEC_ERRORS, bounty,
                         _declared(), 0, ceiling + 1);
        uint256 id = cell.submitAudit(address(t), address(t).codehash, specHash, specToolId, EMPTY_SPEC_ERRORS, bounty,
                                      _declared(), 0, ceiling);
        vm.stopPrank();
        _reachAwaitingWindow(cell, id, protocol, verdictToolId, resultRoot);

        vm.warp(block.timestamp + ceiling);
        cell.confirmAudit(id);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InBlock), "the ceiling settles");
        assertGe(token.balanceOf(auditor), bounty, "and the auditor is paid (plus any minted reward)");
    }

    /// bug_003 (HIGH), FLIPPED in G4(a) (PC-91): accept, verdict and confirm refused during a spec challenge and
    /// `advanceInAuditExt` did not, so anyone timed out the frozen auditor. Now the timeout honours the freeze (I3), and a
    /// challenge the protocol DEFENDS gives the auditor back the time it was forbidden to use. The finalize and arbiter
    /// exits are in FreezesAndExits.t.sol.
    function test_G4a_a_spec_challenge_freezes_the_timeout_with_the_auditor() public {
        vm.prank(auditor);
        cell.register();
        HighTarget t = new HighTarget(4);
        vm.startPrank(protocol);
        token.approve(address(cell), 1_000 ether);
        uint256 id = cell.submitAudit(address(t), address(t).codehash, specHash, specToolId, EMPTY_SPEC_ERRORS, 1_000 ether,
                                      _declared(), 0, 0);
        vm.stopPrank();
        _protocolAcceptAndAssignedAccept(cell, id, protocol, EMPTY_SPEC_ERRORS);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InAudit), "the auditor holds it");
        uint256 pickup = cell.getAudit(id).pickupTime;

        vm.warp(pickup + 6 days);
        vm.startPrank(challenger);
        token.approve(address(cell), specArbiter.specChallengeStake());
        specArbiter.challengeSpecInvalid(id, failErrorsRoot);
        vm.stopPrank();
        assertTrue(specArbiter.challengeActive(id), "a spec challenge is active");

        vm.prank(auditor);
        vm.expectRevert(); // SpecChallengeActive: the auditor may not deliver its verdict
        cell.provePass(id, verdictToolId, resultRoot);

        vm.warp(pickup + cell.inAuditWindow() + 1);
        vm.prank(stranger);
        vm.expectRevert(CellLogicLib.SpecChallengeActive.selector);
        cell.advanceInAudit(id); // ...and nobody may time it out under the same challenge

        vm.prank(protocol);
        specArbiter.defendSpecChallenge(id, EMPTY_SPEC_ERRORS);
        assertEq(cell.getAudit(id).pickupTime, pickup + 1 days + 1, "the frozen day and second are given back");
        (,,,, uint256 streak,) = cell.auditors(auditor);
        assertEq(streak, 0, "no strike for time the auditor was forbidden to use");

        vm.prank(stranger);
        vm.expectRevert(CellLogicLib.InAuditWindowActive.selector);
        cell.advanceInAudit(id);
        vm.prank(auditor);
        cell.provePass(id, verdictToolId, resultRoot);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.AwaitingWindow), "the auditor delivers");
    }
}

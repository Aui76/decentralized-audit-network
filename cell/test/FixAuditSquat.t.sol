// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/SubmitAuditLib.sol";
import "./helpers/CellTestDeploy.sol";

contract Target {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/*
 * bug_204 - `submitFixAudit` is UNAUTHENTICATED and squats the one-per-claim slot.
 *
 * `SubmitAuditLib.submitFixAuditExt` checks the bounty, the deployed address, the linked id, the linked
 * row's state, that a claim exists and is unresolved, and that the fix slot is free. It never checks that
 * `msg.sender` is the linked row's protocol - and `AuditCell.submitFixAudit` forwards without one either.
 *
 * The slot is a hard block: `L.activeFixAuditId[linkedAuditId] = id` at :268, and :248 refuses every later
 * fix for that claim with `FixAuditAlreadyOpen`. The minimum bounty is `bounty > 0` - ONE WEI is legal.
 *
 * So for 1 wei a stranger occupies the remediation slot on someone else's claimed row and locks the real
 * protocol out of fixing its own audit for the life of the claim. A doorstop attack: cheap, permissionless,
 * and it also burns a pool auditor assignment on the squatted row.
 */
contract FixAuditSquatTest is Test {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;

    address protocol  = address(0xA11CE);
    address auditorA  = address(0xB0B);
    address claimant  = address(0xDEAD);
    address auditorC  = address(0xC0DE);
    address stranger  = address(0xBADD);

    bytes32 specToolId   = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash     = keccak256("spec.v1");
    bytes32 specErrors   = keccak256("errors.v1");
    bytes32 resultRoot   = keccak256("result.v1");
    bytes32 claimRoot    = keccak256("claim.proof");

    uint256 constant ORIG_BOUNTY = 40 ether;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        escrow = d.escrow;
        token.genesisMint(protocol, 2_000 ether);
        token.genesisMint(claimant, 500 ether);
        token.genesisMint(auditorC, 50 ether);
        token.genesisMint(stranger, 10 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
    }

    function _registerAll() internal {
        vm.prank(auditorA);
        cell.register();
        vm.prank(claimant);
        cell.register();
        vm.prank(auditorC);
        cell.register();
    }

    /// @dev an audit taken to Claimed, so the fix slot is open and unfilled.
    function _claimedOriginal() internal returns (uint256 id) {
        _registerAll();
        Target original = new Target(1);
        vm.prank(protocol);
        token.approve(address(cell), ORIG_BOUNTY);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        id = cell.submitAudit(address(original), address(original).codehash, specHash, specToolId, specErrors, ORIG_BOUNTY, declared, 0, 0);
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditorA);
        cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);

        uint256 stake = cell.claimFilingStake();
        vm.prank(claimant);
        token.approve(address(cell), stake);
        vm.prank(claimant);
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Claimed), "row is Claimed");
        assertEq(cell.activeFixAuditId(id), 0, "the fix slot starts empty");
    }

    /* ---------------------------------------------------------------------
     * RED: a stranger must not be able to file a fix audit on someone else's
     * claimed row. Before the guard, this succeeds for ONE WEI.
     * ------------------------------------------------------------------- */
    function test_stranger_cannot_submit_a_fix_audit_on_another_protocols_row() public {
        uint256 id = _claimedOriginal();
        Target fix = new Target(2);

        vm.startPrank(stranger);
        token.approve(address(cell), 1);
        vm.expectRevert(SubmitAuditLib.OnlyLinkedProtocol.selector);
        cell.submitFixAudit(address(fix), specHash, specToolId, specErrors, 1, id);
        vm.stopPrank();

        assertEq(cell.activeFixAuditId(id), 0, "the slot must still be free for the real protocol");
    }

    /* ---------------------------------------------------------------------
     * The damage, pinned separately so the cost is on the record rather than
     * implied: once the slot is taken the REAL protocol is locked out, and
     * `FixAuditAlreadyOpen` is the refusal it meets.
     * ------------------------------------------------------------------- */
    function test_squatted_slot_locks_the_real_protocol_out() public {
        uint256 id = _claimedOriginal();
        Target squat = new Target(3);
        Target real  = new Target(4);

        // Simulate the pre-guard world by letting the LINKED PROTOCOL fill the slot,
        // then showing that a second fix - from anyone, including the protocol - is refused.
        vm.startPrank(protocol);
        token.approve(address(cell), 1 ether);
        cell.submitFixAudit(address(squat), specHash, specToolId, specErrors, 1 ether, id);
        vm.stopPrank();
        assertGt(cell.activeFixAuditId(id), 0, "slot is now occupied");

        vm.startPrank(protocol);
        token.approve(address(cell), 1 ether);
        vm.expectRevert(SubmitAuditLib.FixAuditAlreadyOpen.selector);
        cell.submitFixAudit(address(real), specHash, specToolId, specErrors, 1 ether, id);
        vm.stopPrank();
    }

    /* ---------------------------------------------------------------------
     * GREEN: the legitimate path is untouched - the linked row's protocol can
     * still file its fix, which is the whole point of the function.
     * ------------------------------------------------------------------- */
    function test_linked_protocol_can_still_submit_its_fix_audit() public {
        uint256 id = _claimedOriginal();
        Target fix = new Target(5);

        vm.startPrank(protocol);
        token.approve(address(cell), 1 ether);
        uint256 fixId = cell.submitFixAudit(address(fix), specHash, specToolId, specErrors, 1 ether, id);
        vm.stopPrank();

        assertGt(fixId, id, "the fix audit was created");
        assertEq(cell.activeFixAuditId(id), fixId, "and it holds the slot");
        assertEq(cell.getAudit(fixId).protocol, protocol, "filed by the linked protocol, as designed");
    }
}

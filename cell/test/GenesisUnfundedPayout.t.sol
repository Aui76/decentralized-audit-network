// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./helpers/SpecValidationCellSetup.sol";

contract UnfundedTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice RED-DIRECTION ORACLE for the 2026-09-04 critical finding (bug_101 / bug_301, proposal §A).
///
/// THE DEFECT THIS PINS. A genesis row is created with `skipBountyEscrow = true`, so `a.bounty = B` is
/// recorded while NO `transferFrom` runs — the cell never received B. `confirmAudit` then decides whether to
/// pay by asking the LATCH:
///
///     bool isGenesisConfirm = L.genesisAuditOpen && L.genesisAuditId == id;
///     if (!isGenesisConfirm) { L.token.transfer(a.auditor, a.bounty); }
///
/// and never asks the ROW's own `a.bountyEscrowed`, which every other consumer of `a.bounty` checks
/// (e.g. `AuditCell._voidAuditRow`, `SpecArbiterModule._payoutAndVoid`). The latch is released on a
/// NON-terminal exit — `proveFail` sets the row to `Claimed` and calls `_releaseGenesisIfOpen` — and the row
/// then walks back out of `Claimed` when the claim resolves. On the next confirm `isGenesisConfirm` is false,
/// so the cell pays B out of funds belonging to other protocols.
///
/// WHAT THIS TEST IS FOR, stated so it is not mistaken for a regression test. It is written to FAIL against
/// the unfixed cell — that is the point. The proposal's acceptance requires the red direction be driven
/// BEFORE the fix lands, so the fix is seen to close a hole that was demonstrably open, rather than asserted
/// to have closed one.
///
/// NOT IN SCOPE HERE: the retry affordance itself. Releasing the latch on a failed genesis is DELIBERATE and
/// separately tested (`GenesisBootstrapCell.t.sol::test_genesis_fail_releases_lock_allows_retry`). That test
/// must keep passing UNCHANGED after the fix — a fix that breaks it has removed the affordance instead of
/// correcting the predicate, and is the wrong fix. This file is deliberately separate so that remains visible.
contract GenesisUnfundedPayoutTest is SpecValidationCellSetup {
    /// @dev Same value the other genesis oracles use (GenesisBootstrapCell.t.sol, GenesisFirstAudit.t.sol).
    uint256 internal constant GENESIS_B_G = 5000 ether;

    CellTestDeploy.Deployment internal d;
    AuditCell cell;
    CellToken token;

    address genesisProtocol = address(0xBEEF);
    address genesisAuditor = address(0xA11CE);
    address otherProtocol = address(0xD00D);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 resultRoot = keccak256("result.v1");
    bytes32 failResultRoot = keccak256("result.fail");

    UnfundedTarget target;

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        // G6 (PC-89): the genesis slot belongs to the admin or a genesis protocol the admin names; this fixture's
        // protocol is a separate address, so the admin names it. Encoded, so the file also compiles on pre-G6 bytes.
        (bool named,) = address(d.cell).call(
            abi.encodeWithSignature("setGenesisBootstrap(address,address)", genesisProtocol, address(0))
        );
        named;
        cell = d.cell;
        token = d.token;
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        target = new UnfundedTarget(1);
        assertTrue(cell.genesisPending(), "setUp: genesis must be pending");
        vm.prank(genesisAuditor);
        cell.register();
    }

    function _submitGenesis() internal returns (uint256 id) {
        vm.startPrank(genesisProtocol);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        id = cell.submitGenesisAudit(
            address(target), address(target).codehash, specHash, specToolId,
            EMPTY_SPEC_ERRORS, GENESIS_B_G, declared, 0, 0
        );
        vm.stopPrank();
    }

    /// @notice The unfunded genesis bounty must NOT be payable once the latch has been released.
    function test_RED_unfunded_genesis_bounty_is_not_paid_after_latch_release() public {
        uint256 id = _submitGenesis();
        assertTrue(cell.genesisAuditOpen(), "genesis slot should be open");

        // The row records a bounty the cell never received.
        // The row is DECLARED-UNFUNDED: no transferFrom ran, yet a.bounty = GENESIS_B_G is recorded.
        // This flag is the per-ROW fact the payout guard fails to consult.
        assertFalse(cell.auditBountyEscrowed(id), "genesis row must be declared-unfunded");

        // Other people's money, sitting in the cell. This is what a wrongful payout would come from.
        // MINT BEFORE attachMinter: `attachMinter` hands the minter role to the issuance module, after
        // which the test contract can no longer mint. `confirmAudit` needs issuance attached (it mints the
        // positive block), so the order is: mint everything -> attach -> run the flow.
        token.genesisMint(address(cell), GENESIS_B_G * 2);
        uint256 stakeNeeded = GENESIS_B_G;  // >= requiredClaimStake for this row; excess is never pulled
        token.genesisMint(genesisAuditor, stakeNeeded);
        CellTestDeploy.attachMinter(d);
        uint256 cellBefore = token.balanceOf(address(cell));
        uint256 auditorBefore = token.balanceOf(genesisAuditor);

        // Drive the row to Claimed via proveFail. This releases the LATCH but not the ROW.
        vm.prank(genesisProtocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(genesisAuditor);
        cell.acceptAudit(id, EMPTY_SPEC_ERRORS);
        uint256 stake = cell.requiredClaimStake(id);
        vm.startPrank(genesisAuditor);
        token.approve(address(cell), stake);
        cell.proveFail(id, verdictToolId, failResultRoot);
        vm.stopPrank();

        assertFalse(cell.genesisAuditOpen(), "latch released");
        assertTrue(cell.genesisPending(), "but the slot stays pending - the retry affordance");

        // Resolve the claim. The row returns to its pre-claim state and lives on.
        // G3 (PC-91 bug_004): a verdict is refused once `pickupTime + inAuditWindow` has passed, and the default claim
        // window (30 d) outlasts the in-audit window (7 d), so the restored InAudit row would already be past its own
        // deadline. That interaction is real and is recorded on PC-91 for G4; it is not this test's subject (the unfunded
        // payout), so the claim window is shortened here to keep the ordinary-confirm path this test needs reachable.
        cell.setParam(0, 1 days);
        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        cell.expireClaim(id);

        // Confirm it as an ORDINARY audit. isGenesisConfirm is now false.
        vm.prank(genesisAuditor);
        cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);

        uint256 auditorGain = token.balanceOf(genesisAuditor) - auditorBefore;
        assertTrue(
            auditorGain < GENESIS_B_G,
            "UNFUNDED BOUNTY WAS PAID: the auditor received a bounty the cell never received"
        );
        assertTrue(
            token.balanceOf(address(cell)) + GENESIS_B_G > cellBefore,
            "the cell paid out B it never took in - other protocols' funds left"
        );
    }

    /// @notice The GREEN direction: an ordinary, genuinely escrowed bounty must still be paid in full.
    /// Without this, "gate the payout on bountyEscrowed" could be satisfied by never paying anyone.
    function test_GREEN_ordinary_escrowed_bounty_is_still_paid() public {
        uint256 bounty = 10 ether;
        token.genesisMint(otherProtocol, bounty);   // before the minter role moves
        CellTestDeploy.attachMinter(d);

        UnfundedTarget paidTarget = new UnfundedTarget(2);
        vm.startPrank(otherProtocol);
        token.approve(address(cell), bounty);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        uint256 id = cell.submitAudit(
            address(paidTarget), address(paidTarget).codehash, specHash, specToolId,
            EMPTY_SPEC_ERRORS, bounty, declared, 0, 0
        );
        vm.stopPrank();

        assertTrue(cell.auditBountyEscrowed(id), "ordinary row IS escrowed");
        uint256 auditorBefore = token.balanceOf(genesisAuditor);

        vm.prank(otherProtocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(genesisAuditor);
        cell.acceptAudit(id, EMPTY_SPEC_ERRORS);
        vm.prank(genesisAuditor);
        cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);

        // >= not ==: a confirmed audit pays the bounty AND mints the positive block, so the gain is
        // bounty + reward. Measured here: 10.15625 for a 10 ether bounty, the 0.15625 being the gated
        // mint. The load-bearing claim is that the BOUNTY still arrives, so assert the floor.
        uint256 honestGain = token.balanceOf(genesisAuditor) - auditorBefore;
        assertGe(
            honestGain, bounty,
            "an escrowed bounty must still be paid in full - the fix must not close the honest path"
        );
    }
}

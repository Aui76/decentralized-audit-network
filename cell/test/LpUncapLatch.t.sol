// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

// Oracle for G-22 — the lp==0 mint-uncap edge, closed by the first-funding latch (2026-07-08, DEC-22 docket).
// Proposal: body/proposals/fix-lp-uncap-latch-proposal.txt.
//
// The edge: `lpBalance == 0` disabled the LP mint cap entirely (uncapped activityMint). That is load-bearing
// at GENESIS (LP is 0 by definition; the first mint must happen) but becomes an amplifier afterwards: an
// lpManager draining LP to exactly 0 (withdrawForLP has no per-epoch cap — C-3/G-27 overlap) flips the mint
// from ~5% x lp to fully uncapped. The naive "lp==0 -> mint 0" fix would BRICK issuance (escrow deposits
// derive from the mint: IssuanceModule recordDeposit(treasuryMinted)).
//
// The fix: `lpFirstFunded` records the first nonzero lpBalance observed at settle (set-once, no setter).
// Pre-latch behavior is byte-identical (genesis bootstrap untouched). Post-latch, lp==0 computes the cap
// against the first-funded snapshot: bounded mint, self-healing, no new knob.

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/IssuanceModule.sol";
import "./helpers/CellTestDeploy.sol";

contract G22Target {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

contract LpUncapLatch is Test {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    IssuanceModule issuance;

    address auditor = address(0xB0B);
    address protocol = address(0xC01);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");
    uint256 saltNonce = 1;

    uint256 constant BOUNTY = 1_000 ether; // large bounty -> bounty cap slack; the LP cap is the binding prong

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deployWithoutAssignment(address(this));
        token = d.token; cell = d.cell; escrow = d.escrow; issuance = d.issuance;
        token.genesisMint(protocol, 5_000_000 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        vm.prank(auditor);
        cell.register();
        // (setLPManager call removed 2026-08-09 — the role and its setter are gone with DEC-38.)
    }

    function _confirm(uint256 bounty) internal returns (uint256 minted) {
        G22Target t = new G22Target(saltNonce++);
        vm.startPrank(protocol);
        token.approve(address(cell), bounty);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        uint256 id = cell.submitAudit(
            address(t), address(t).codehash, specHash, specToolId, specErrors, bounty, declared, 0, 0
        );
        vm.stopPrank();
        vm.prank(protocol); cell.protocolAcceptAuditor(id);
        vm.prank(auditor); cell.acceptAudit(id, specErrors);
        vm.prank(auditor); cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);
        minted = cell.auditBlockRewardMinted(id);
    }

    // ---- (1) Genesis regression: pre-latch behavior is exactly the old path ----
    function test_genesis_bootstrap_unlatched_and_mints() public {
        assertEq(issuance.lpFirstFunded(), 0, "latch unset before any settle");
        uint256 minted = _confirm(BOUNTY); // lp==0 at reward time -> old uncapped bootstrap branch
        assertGt(minted, 0, "genesis-era mint still happens (bootstrap preserved)");
        assertGt(escrow.lpBalance(), 0, "treasury split of the mint funds LP");
    }

    // ---- (2) Latch arms on the first settle that SEES funded LP ----
    function test_latch_arms_once_and_is_immutable() public {
        _confirm(BOUNTY); // funds LP; latch was checked before funding -> still 0
        uint256 lpAfterFirst = escrow.lpBalance();
        _confirm(BOUNTY); // this settle sees lp>0 -> latch arms
        uint256 latched = issuance.lpFirstFunded();
        assertGt(latched, 0, "latch armed");
        assertEq(latched, lpAfterFirst, "latch == lp observed at settle time (snapshot semantics)");
        _confirm(BOUNTY);
        assertEq(issuance.lpFirstFunded(), latched, "set-once: later settles never move it");
    }

    // ---- (3) and (4) RETIRED 2026-08-09 — their subject was deleted, and this note is the point ----
    //
    // Both tests drained LP to exactly 0 via `escrow.withdrawForLP(lpBal)` and then asserted that the mint
    // stayed capped (3) and that LP self-healed (4). DEC-38 removed `withdrawForLP` from CellEscrow, and that
    // function was the ONLY decrement of `lpBalance` — the two remaining sites (`+= toLP`, `+= canMove`)
    // both add. So the drain these tests perform is not merely unsupported by the API, it is UNREACHABLE BY
    // CONSTRUCTION: after the latch arms, `lpBalance` can never return to 0.
    //
    // They are retired rather than deleted because deleting them silently would leave a guard in immutable
    // code with no written trace of what once covered it — the failure this repo files as B.11 (absence has
    // no error message). Tests (1) and (2) above are UNTOUCHED and still load-bearing: (1) covers the genesis
    // bootstrap (`lp == 0` pre-latch, which still happens on every fresh cell) and (2) covers the latch
    // arming at `IssuanceModule.sol`:380, which still executes.
    //
    // WHAT THIS EXPOSES, and it is a finding rather than a cleanup: the G-22 latch's protective arm is now
    // vestigial. `IssuanceModule.sol`:466 reads `effLp = lp == 0 ? lpFirstFunded : lp`. With no drain lever,
    // `lp == 0` can only hold BEFORE first funding — and there `lpFirstFunded` is 0 too (:380 sets it only
    // when `lpNow > 0`), so the bootstrap branch is taken and `lpFirstFunded` is never consulted for its
    // protective purpose again. DEC-38 SUBSUMES G-22: removing the door removed the attack the latch patched.
    // The latch is deliberately left in the contract (see the note at the deletion site in CellEscrow.sol) —
    // cheap, conservative, and correct if a future cell ever reintroduces a decrement.
    //
    // REOPEN TRIGGER, mechanical: if any future change adds a path that DECREASES `lpBalance`, these two
    // tests must come back, because the drain scenario becomes reachable again the moment one exists.
    //
    // A note on the alternative that was considered and NOT taken: the branch could still be exercised by
    // forcing storage with `vm.store`. That was rejected here for one honest reason — it would need
    // `lpBalance`'s slot index, which nobody verified against a build, and a test that silently targets the
    // wrong slot passes while proving nothing. If the branch is judged worth covering, do it with a measured
    // slot and say in the test that the state is production-unreachable.
}

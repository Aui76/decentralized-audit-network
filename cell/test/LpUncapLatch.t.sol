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
    address lpManager = address(0x1122);
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
        escrow.setLPManager(lpManager);
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

    // ---- (3) THE FIX: full LP drain no longer uncaps the mint ----
    function test_full_lp_drain_mint_stays_capped() public {
        _confirm(BOUNTY);
        _confirm(BOUNTY); // latch armed
        uint256 latched = issuance.lpFirstFunded();

        uint256 lpBal = escrow.lpBalance(); // hoisted: an inner view call consumes vm.prank
        vm.prank(lpManager);
        escrow.withdrawForLP(lpBal); // drain to exactly 0 (the G-22 lever)
        assertEq(escrow.lpBalance(), 0, "LP fully drained");

        uint256 uncapped = (issuance.emaSlow() * issuance.emaToMintBps()) / 10_000;
        uint256 capAtLatch = (issuance.mintLpCapBps() * latched) / 10_000;
        assertLt(capAtLatch, uncapped, "test regime: latch cap must bind below uncapped activityMint");

        uint256 basis = issuance.nextPositiveBlockReward();
        assertLe(basis, capAtLatch, "reward basis capped by the first-funded snapshot, NOT uncapped");
        assertGt(basis, 0, "and NOT zero - issuance is not bricked");

        uint256 minted = _confirm(BOUNTY);
        assertGt(minted, 0, "mint continues bounded during the drain");
        assertLe(minted, capAtLatch, "minted <= latch cap (weight/bounty prongs can only reduce it)");
    }

    // ---- (4) Self-healing: deposits refill LP; live lp governs again ----
    function test_refill_returns_to_live_lp_cap() public {
        _confirm(BOUNTY);
        _confirm(BOUNTY); // latch armed
        uint256 latched = issuance.lpFirstFunded();

        uint256 lpBal = escrow.lpBalance(); // hoisted: an inner view call consumes vm.prank
        vm.prank(lpManager);
        escrow.withdrawForLP(lpBal);
        _confirm(BOUNTY); // bounded mint -> its treasury split refills LP

        uint256 lpNow = escrow.lpBalance();
        assertGt(lpNow, 0, "LP self-heals from the bounded mint's deposit");
        uint256 basis = issuance.nextPositiveBlockReward();
        uint256 uncapped = (issuance.emaSlow() * issuance.emaToMintBps()) / 10_000;
        uint256 capLive = (issuance.mintLpCapBps() * lpNow) / 10_000;
        uint256 expected = capLive < uncapped ? capLive : uncapped;
        // manipulation damping may scale the basis down, never up — bound, don't pin
        assertLe(basis, expected, "live lp governs the cap again after refill");
        assertEq(issuance.lpFirstFunded(), latched, "latch untouched by drain/refill cycle");
    }
}

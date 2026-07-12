// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

// Oracle for G-20 — cumulative bound on the green-light mint (2026-07-08, DEC-22 docket, option 1).
// Proposal: body/proposals/fix-greenlight-cumulative-cap-proposal.txt.
//
// Per-confirm the green-light mint was already bounded (50% x supplement, 30 bps escrow drawdown, four
// gates, §2.6 wash-proof EMAs). What it lacked was any CUMULATIVE bound — across a long real depression
// it could mint indefinitely. Fix: lifetime `greenLightMintedCumulative` <= greenLightCumulativeCapBps
// of totalSupply (read at mint time; saturating headroom; partial mint at the boundary).
//
// 2026-07-10 (operator apply): t3/t4 baselines corrected + t5 added. The cap is supply-scaled and
// READ AT MINT TIME; a confirm's own block mints (auditor+treasury+founder, ~2.03x the G-17-capped
// reward) grow totalSupply BEFORE the green-light branch reads headroom, so pre-confirm capTotal
// snapshots under-count by capBps x blockMint. Adjudication + cheap-lunch check of the reopen
// semantics: body/proposals/fix-g20-cap-test-baseline-proposal.txt.
//
// Fixture note: the existing suites only tested the GATE view (AdaptiveIssuanceClosure, FloorReserveCap)
// — this suite makes the mint FIRE end-to-end. The trick is credBounty: for an unestablished protocol
// credBounty == netMean == networkCumulativeBounty / networkAuditCount (both public -> stdstore-pinnable),
// so the settle's post-blend emaFast can be forced ABOVE prevFast (the recovery gate) deterministically
// with a TINY real bounty.

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/IssuanceModule.sol";
import "./helpers/CellTestDeploy.sol";

contract G20Target {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

contract GreenLightCumulativeCap is Test {
    using stdStorage for StdStorage;

    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    IssuanceModule issuance;

    address protocol = address(0xA11CE);
    address auditor = address(0xB0B);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");

    bytes32 constant GREEN_LIGHT_TOPIC = keccak256("GreenLightMintPaid(address,uint256,uint256)");

    uint256 constant TINY = 0.001 ether;
    uint256 saltNonce = 1;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        escrow = d.escrow;
        issuance = d.issuance;

        token.genesisMint(protocol, 1_000 ether);
        token.genesisMint(address(this), 20_000 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        _fundEscrow(10_000 ether); // pool > 0 so supplement > 0; far below the pinned reserve

        vm.prank(auditor);
        cell.register();

        _confirm(1 ether); // warm the EMAs so pins override a live signal
    }

    // ---- t1 headroom math (pure, deterministic) ----
    function test_headroom_math_saturating() public {
        uint256 capTotal = (token.totalSupply() * issuance.greenLightCumulativeCapBps()) / 10_000;
        assertEq(issuance.greenLightMintHeadroom(), capTotal, "untouched counter -> full headroom");

        stdstore.target(address(issuance)).sig("greenLightMintedCumulative()").checked_write(capTotal);
        assertEq(issuance.greenLightMintHeadroom(), 0, "counter at cap -> zero headroom");

        stdstore.target(address(issuance)).sig("greenLightMintedCumulative()").checked_write(capTotal + 1 ether);
        assertEq(issuance.greenLightMintHeadroom(), 0, "counter past cap -> saturates, no underflow");
    }

    // ---- t2 the mint fires end-to-end, is accounted, and never exceeds headroom ----
    function test_green_light_mint_fires_and_is_accounted() public {
        _pinDepressionRecovery();
        uint256 headBefore = issuance.greenLightMintHeadroom();
        assertGt(headBefore, 0, "precondition: lifetime headroom open");

        uint256 minted = _confirmGreenLight(TINY);
        assertGt(minted, 0, "green-light mint fired under pinned depression-recovery");
        assertLe(minted, headBefore, "mint never exceeds lifetime headroom");
        assertEq(issuance.greenLightMintedCumulative(), minted, "counter accounts the mint exactly");
    }

    // ---- t3 boundary clamp: partial mint exactly equal to the remaining headroom ----
    function test_boundary_partial_mint_equals_headroom() public {
        // First, measure an unclamped mint under the pinned state.
        _pinDepressionRecovery();
        uint256 probe = _confirmGreenLight(TINY);
        assertGt(probe, 0, "probe mint fired");

        // Leave LESS headroom than a full mint: cumulative := capTotal - probe/2.
        uint256 capTotal = (token.totalSupply() * issuance.greenLightCumulativeCapBps()) / 10_000;
        uint256 remaining = probe / 2;
        assertGt(remaining, 0, "probe big enough to halve");
        stdstore.target(address(issuance)).sig("greenLightMintedCumulative()").checked_write(
            capTotal - remaining
        );

        uint256 cumulativeBefore = capTotal - remaining;

        _pinDepressionRecovery();
        uint256 clamped = _confirmGreenLight(TINY);
        assertGt(clamped, 0, "boundary mint still fires");
        // Headroom AT MINT TIME: the boundary confirm's own block mints grew supply before the
        // green-light read; the green-light mint itself lands after it. Reconstruct exactly.
        uint256 supplyAtMint = token.totalSupply() - clamped;
        uint256 headroomAtMint =
            (supplyAtMint * issuance.greenLightCumulativeCapBps()) / 10_000 - cumulativeBefore;
        assertEq(clamped, headroomAtMint, "boundary mint == exact headroom at mint time");
        assertEq(
            issuance.greenLightMintedCumulative(),
            cumulativeBefore + clamped,
            "headroom spent precisely, counter accounted"
        );
    }

    // ---- t4 spent cap: the mint goes silent, counter frozen ----
    // The cap is supply-scaled, so one confirm's own block mint reopens capBps x blockMint of
    // headroom (t5 pins that exactly). To assert TRUE silence, over-spend the counter by a margin
    // (1 ether) far above any single block's cap growth (~1e13 wei at TINY bounty).
    function test_spent_cap_stops_minting() public {
        uint256 capTotal = (token.totalSupply() * issuance.greenLightCumulativeCapBps()) / 10_000;
        uint256 pinned = capTotal + 1 ether;
        stdstore.target(address(issuance)).sig("greenLightMintedCumulative()").checked_write(pinned);

        _pinDepressionRecovery();
        uint256 minted = _confirmGreenLight(TINY);
        assertEq(minted, 0, "no green-light mint while the counter exceeds the supply-scaled cap");
        assertEq(issuance.greenLightMintedCumulative(), pinned, "counter frozen");
    }

    // ---- t5 self-scaling reopen: a spent cap reopens by EXACTLY capBps of the block's own mint ----
    // Decided semantics (IssuanceModule: "read at mint time - self-scaling, no epoch machinery"):
    // the cap is capBps of a GROWING supply, so post-spent confirms reopen dust-sized headroom
    // (capBps x this block's mint <= ~1% of the block's funded bounty; cheap-lunch analysis in
    // body/proposals/fix-g20-cap-test-baseline-proposal.txt section 2).
    function test_self_scaling_reopen_is_exact() public {
        uint256 capBps = issuance.greenLightCumulativeCapBps();
        uint256 supplyBefore = token.totalSupply();
        uint256 capTotal = (supplyBefore * capBps) / 10_000;
        stdstore.target(address(issuance)).sig("greenLightMintedCumulative()").checked_write(capTotal);
        assertEq(issuance.greenLightMintHeadroom(), 0, "cap spent at current supply");

        _pinDepressionRecovery();
        uint256 minted = _confirmGreenLight(TINY);

        uint256 supplyAtMint = token.totalSupply() - minted;
        uint256 reopened = (supplyAtMint * capBps) / 10_000 - capTotal;
        assertEq(minted, reopened, "reopen == capBps of the block's own supply growth, exactly");
        assertGt(minted, 0, "reopen is nonzero - the decided semantics, pinned deliberately");
        assertEq(issuance.greenLightMintedCumulative(), capTotal + minted, "reopen accounted");
    }

    // --- helpers ------------------------------------------------------------------------------------------

    /// @dev Pin a genuine-depression + recovering-signal state that survives the settle's own blending:
    ///      netMean pinned at 10k (unestablished protocol -> credBounty == netMean), emaFast entry 9k, so
    ///      post-blend emaFast' = 9k*0.8 + 10k*0.2 = 9.2k > prevFast 9k (recovery gate), and with
    ///      emaSlow' ~ 19.1k the ratio ~ 4810 bps sits inside [recoverability 4500, depression 7000).
    ///      Reserve = 3.6 x emaSlow' (~69k) >> pool (~10k) -> paid 0 < supplement -> green-light branch.
    function _pinDepressionRecovery() internal {
        stdstore.target(address(issuance)).sig("networkCumulativeBounty()").checked_write(50_000 ether);
        stdstore.target(address(issuance)).sig("networkAuditCount()").checked_write(uint256(5));
        stdstore.target(address(issuance)).sig("emaSlow()").checked_write(20_000 ether);
        stdstore.target(address(issuance)).sig("emaFast()").checked_write(9_000 ether);
        stdstore.target(address(issuance)).sig("lastEmaFast()").checked_write(8_000 ether);
    }

    function _confirmGreenLight(uint256 bounty) internal returns (uint256 minted) {
        vm.recordLogs();
        _confirm(bounty);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == GREEN_LIGHT_TOPIC) {
                (uint256 amount,) = abi.decode(logs[i].data, (uint256, uint256));
                return amount;
            }
        }
        return 0;
    }

    function _confirm(uint256 bounty) internal {
        G20Target target = new G20Target(saltNonce++);
        vm.startPrank(protocol);
        token.approve(address(cell), bounty);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        uint256 id = cell.submitAudit(
            address(target), address(target).codehash, specHash, specToolId, specErrors, bounty, declared, 0, 0
        );
        vm.stopPrank();
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditor);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditor);
        cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        vm.prank(auditor);
        cell.confirmAudit(id);
    }

    function _fundEscrow(uint256 amount) internal {
        token.transfer(address(escrow), amount);
        vm.prank(address(cell.issuanceModule()));
        escrow.recordDeposit(amount);
    }
}

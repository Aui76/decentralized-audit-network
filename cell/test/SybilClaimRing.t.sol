// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

// ---------------------------------------------------------------------------
// PROPOSED PoC ARTIFACT — attack A-2 (tokenomics-sybil-hardening-proposal.txt)
// To run: copy into cell/test/ then:
//     cd cell && forge test --match-contract SybilClaimRing -vv
//
// Four-address Sybil ring (P, V, C, D) extracts real escrow via boosted discoverer
// payout after a reproducible fail dispute — not inflation.
// ---------------------------------------------------------------------------

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/CellStorage.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/ClaimDisputeModule.sol";
import "./helpers/CellTestDeploy.sol";

contract RingTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @dev Confirms A-2: claim-dispute ring drains CellEscrow at >1x bounty via reputation boost.
contract SybilClaimRing is Test {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    ClaimDisputeModule claimModule;

    address P = address(0xA11CE);
    address V = address(0xB0B);
    address C = address(0xC1A1);
    address D = address(0xD15E);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");
    bytes32 claimRoot = keccak256("reproducible.fail.proof");

    uint256 constant DECOY_BOUNTY = 10 ether;
    uint256 constant MAIN_BOUNTY = 100 ether;
    uint256 constant ESCROW_SEED = 1_000_000 ether;
    uint256 saltNonce = 1;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deployWithoutAssignment(address(this));
        token = d.token;
        cell = d.cell;
        escrow = d.escrow;
        claimModule = d.claimModule;

        token.genesisMint(P, 50_000 ether);
        token.genesisMint(C, 5_000 ether);
        token.genesisMint(address(this), ESCROW_SEED);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        _fundEscrow(ESCROW_SEED);

        // FIFO assignment: start with V alone so every ordinary audit lands on V.
        vm.prank(V);
        cell.register();
    }

    function _ensureClaimantAndDisputeAuditorRegistered() internal {
        (,,, uint256 cPos,,) = cell.auditors(C);
        if (cPos == 0) {
            vm.prank(C);
            cell.register();
        }
        (,,, uint256 dPos,,) = cell.auditors(D);
        if (dPos == 0) {
            vm.prank(D);
            cell.register();
        }
    }

    function test_sybil_claim_ring_extracts_escrow_above_bounty() public {
        // One reproducible fail is enough for the 5x boost ceiling (failed=1, denom=1).
        _pumpAuditorFailedReputation(1);

        uint256 boostBps = cell.auditorReputationBoostBps(V);
        assertGt(boostBps, 10_000, "reputation boost above 1x before main attack");
        emit log_named_uint("auditor reputation boost bps", boostBps);

        uint256 ringBefore = _ringCombined();
        uint256 escrowBefore = escrow.escrowBalance();

        (uint256 paid,) = _runMainClaimDisputeExtraction();
        assertLt(escrow.escrowBalance(), escrowBefore, "CellEscrow balance fell");
        // M-2 (G-18) APPLIED: the discoverer payout is now capped at 1x the escrowed bounty — the drain lever is
        // dead (this line was `assertGt(paid, MAIN_BOUNTY)` when the PoC proved the flaw).
        assertLe(paid, MAIN_BOUNTY, "M-2: discoverer payout capped at 1x escrowed bounty");

        // The ring can still net positive here via the self-audit MINT (the A-1 lever), which THIS fix does not
        // touch — that closes with the different-partners fix. The A-2-specific win is that the escrow can no
        // longer be drained above the bounty (asserted above).
        uint256 ringAfter = _ringCombined();
        assertGe(ringAfter, ringBefore, "ring balance did not fall (residual A-1 mint until that fix ships)");

        emit log_named_uint("discoverer paid from escrow (wei)", paid);
        emit log_named_uint("ring net gain (wei)", ringAfter - ringBefore);
    }

    function _pumpAuditorFailedReputation(uint256 rounds) internal {
        for (uint256 i = 0; i < rounds; i++) {
            _runDecoyDisputeFail(DECOY_BOUNTY);
        }
        (, uint256 vFailed,,,,) = cell.auditors(V);
        assertGe(vFailed, rounds, "original auditor failed count pumped");
    }

    function _runDecoyDisputeFail(uint256 bounty) internal {
        RingTarget target = new RingTarget(saltNonce++);
        uint256 id = _submitPassAwaitingWindow(target, bounty);
        _ensureClaimantAndDisputeAuditorRegistered();
        _fileClaim(id);
        _openDisputeAndFail(id, bounty);
    }

    function _runMainClaimDisputeExtraction() internal returns (uint256 paid, uint256 cGain) {
        RingTarget target = new RingTarget(saltNonce++);
        uint256 id = _submitPassConfirm(target, MAIN_BOUNTY);

        uint256 cBefore = token.balanceOf(C);
        uint256 escrowBefore = escrow.escrowBalance();

        _ensureClaimantAndDisputeAuditorRegistered();
        _fileClaim(id);
        _openDisputeAndFail(id, MAIN_BOUNTY);

        paid = escrowBefore - escrow.escrowBalance();
        cGain = token.balanceOf(C) - cBefore;
        // M-2 (G-18) APPLIED: the claimant's gain is the discoverer payout, now CAPPED at 1x the bounty (the
        // stake round-trips). Was `assertGt(cGain, claimFilingStake)` when the boosted payout exceeded the stake.
        assertLe(cGain, MAIN_BOUNTY, "M-2: claimant gain (capped payout) does not exceed the bounty");
    }

    function _submitPassAwaitingWindow(RingTarget target, uint256 bounty) internal returns (uint256 id) {
        vm.startPrank(P);
        token.approve(address(cell), bounty);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        id = cell.submitAudit(
            address(target), address(target).codehash, specHash, specToolId, specErrors, bounty, declared, 0, 0
        );
        vm.stopPrank();
        vm.prank(P);
        cell.protocolAcceptAuditor(id);
        assertEq(cell.auditAuditorOf(id), V, "FIFO assigns original auditor V");
        vm.prank(V);
        cell.acceptAudit(id, specErrors);
        vm.prank(V);
        cell.provePass(id, verdictToolId, resultRoot);
    }

    function _submitPassConfirm(RingTarget target, uint256 bounty) internal returns (uint256 id) {
        id = _submitPassAwaitingWindow(target, bounty);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);
    }

    function _fileClaim(uint256 id) internal {
        uint256 stake = cell.claimFilingStake();
        vm.startPrank(C);
        token.approve(address(cell), stake);
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");
        vm.stopPrank();
    }

    function _openDisputeAndFail(uint256 id, uint256 origBounty) internal {
        uint256 minB = (origBounty * 5000) / 10_000;
        vm.startPrank(P);
        token.approve(address(cell), minB);
        uint256 disputeId = claimModule.openDisputeReaudit(id, minB);
        vm.stopPrank();

        address disputeAuditor = cell.auditAuditorOf(disputeId);
        assertEq(disputeAuditor, D, "dispute auditor excludes V and claimant C");

        vm.prank(disputeAuditor);
        cell.acceptAudit(disputeId, specErrors);
        vm.prank(disputeAuditor);
        cell.proveFail(disputeId, verdictToolId, claimRoot);

        // G-15: dispute confirm settles the claim but must not advance positive-block mint.
        uint256 supplyBefore = token.totalSupply();
        uint256 heightBefore = cell.blockHeight();
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);
        assertEq(cell.blockHeight(), heightBefore, "G-15: dispute confirm must not advance blockHeight");
        assertEq(token.totalSupply(), supplyBefore, "G-15: dispute confirm must not mint supply");
        assertEq(cell.auditPositiveBlock(disputeId), 0, "G-15: no positive block on dispute row");
        (, uint256 dSuccessful,,,,) = cell.auditors(disputeAuditor);
        assertEq(dSuccessful, 0, "G-15: dispute auditor not successful++");

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Exploited));
    }

    function _ringCombined() internal view returns (uint256) {
        return token.balanceOf(P) + token.balanceOf(V) + token.balanceOf(C) + token.balanceOf(D);
    }

    function _fundEscrow(uint256 amount) internal {
        token.transfer(address(escrow), amount);
        vm.prank(address(cell.issuanceModule()));
        escrow.recordDeposit(amount);
    }
}

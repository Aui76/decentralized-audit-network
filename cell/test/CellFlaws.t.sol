// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/CellStorage.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/ClaimDisputeModule.sol";
import "./helpers/CellTestDeploy.sol";
import "../contracts/CellParamIds.sol";

contract Target {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @dev G-10 stub verifiers.
contract RejectingVerifier is IRunProofVerifier {
    function verify(bytes32, bytes calldata) external pure returns (bool) { return false; }
}

contract AcceptingVerifier is IRunProofVerifier {
    function verify(bytes32, bytes calldata) external pure returns (bool) { return true; }
}

/// @dev Genesis-specific flaw regressions (G-01–G-10). Independent of dan-core F-ID register.
contract CellFlaws is Test {
    event PositiveBlockSupplyExhausted(uint256 indexed height, uint256 indexed auditId);
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    IssuanceModule issuance;

    address protocol = address(0xA11CE);
    address auditorA = address(0xB0B);
    address adversary = address(0xDEAD);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        escrow = d.escrow;
        issuance = d.issuance;
        token.genesisMint(protocol, 2_000 ether);
        token.genesisMint(adversary, 500 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
    }

    // G-01
    function test_mutual_bind_rejects_mismatch() public {
        CellToken t2 = new CellToken();
        AuditCell c2 = new AuditCell(address(t2));
        vm.expectRevert(AuditCell.EscrowBoundElsewhere.selector);
        c2.setTreasuryEscrow(address(escrow));
    }

    function test_network_cannot_rebind() public {
        vm.expectRevert("Network already set");
        escrow.setNetwork(address(0xBEEF));
    }

    function test_treasury_cannot_rebind() public {
        vm.expectRevert(AuditCell.TreasuryAlreadySet.selector);
        cell.setTreasuryEscrow(address(0xBEEF));
    }

    // G-02
    function test_lockMinter_blocks_rotation() public {
        token.lockMinter();
        vm.expectRevert("Minter locked");
        token.setMinter(address(0xBEEF));
    }

    function test_genesis_mint_blocked_after_minter_set() public {
        vm.expectRevert("Minter already set");
        token.genesisMint(protocol, 1 ether);
    }

    // G-03
    function test_transferAdmin_rejects_zero() public {
        vm.expectRevert(AuditCell.ZeroAdmin.selector);
        cell.transferAdmin(address(0));
    }

    // G-04
    function test_audit_window_bounds() public {
        vm.expectRevert(AuditCell.AuditWindowOutOfBounds.selector);
        cell.setParam(CellParamIds.MIN_AUDIT, 5 minutes);
        vm.expectRevert(AuditCell.AuditWindowOutOfBounds.selector);
        cell.setParam(CellParamIds.MIN_AUDIT, 31 days);
        cell.setParam(CellParamIds.MIN_AUDIT, 10 minutes);
        assertEq(cell.minAuditWindow(), 10 minutes);
    }

    function test_claim_resolution_window_bounds() public {
        vm.expectRevert(AuditCell.ClaimWindowOutOfBounds.selector);
        cell.setParam(CellParamIds.CLAIM_RESOLUTION, 9 minutes);
        vm.expectRevert(AuditCell.ClaimWindowOutOfBounds.selector);
        cell.setParam(CellParamIds.CLAIM_RESOLUTION, 91 days);
        cell.setParam(CellParamIds.CLAIM_RESOLUTION, 10 minutes);
        assertEq(cell.claimResolutionWindow(), 10 minutes);
    }

    // G-05 — fix confirm after expireClaim must not double-resolve; fix auditor still paid
    function test_fix_confirm_after_expire_claim() public {
        vm.prank(auditorA);
        cell.register();
        vm.prank(adversary);
        cell.register();

        Target original = new Target(1);
        vm.prank(protocol);
        token.approve(address(cell), 40 ether);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        uint256 id = cell.submitAudit(address(original), address(original).codehash, specHash, specToolId, specErrors, 40 ether, declared, 0, 0);

        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditorA);
        cell.provePass(id, verdictToolId, resultRoot);

        uint256 stake = cell.claimFilingStake();
        vm.prank(adversary);
        token.approve(address(cell), stake);
        vm.prank(adversary);
        cell.claimVulnerability(id, verdictToolId, keccak256("claim"), "");

        Target fixTarget = new Target(2);
        vm.prank(protocol);
        token.approve(address(cell), 20 ether);
        vm.prank(protocol);
        uint256 fixId = cell.submitFixAudit(address(fixTarget), specHash, specToolId, specErrors, 20 ether, id);
        address fixAuditor = cell.auditAuditorOf(fixId);

        vm.prank(fixAuditor);
        cell.acceptAudit(fixId, specErrors);
        vm.prank(fixAuditor);
        cell.provePass(fixId, verdictToolId, keccak256("fix.result"));

        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        cell.expireClaim(id);
        assertEq(
            uint256(cell.auditStateOf(id)),
            uint256(CellTypeDefs.AuditState.AwaitingWindow),
            "G-14: restored on expire, not Exploited"
        );

        uint256 fixAuditorBefore = token.balanceOf(fixAuditor);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(fixId);

        assertEq(
            uint256(cell.auditStateOf(id)),
            uint256(CellTypeDefs.AuditState.AwaitingWindow),
            "no re-resolve after fix confirm"
        );
        assertGt(token.balanceOf(fixAuditor), fixAuditorBefore, "fix auditor paid");
    }

    // G-14 — expire restores original; FAIL-at-audit auditor stake refunded (liveness ≠ guilt)
    function test_expire_fail_at_audit_restores_in_audit_refunds_stake() public {
        vm.prank(auditorA);
        cell.register();
        vm.prank(adversary);
        token.transfer(auditorA, 200 ether);

        Target target = new Target(1);
        vm.prank(protocol);
        token.approve(address(cell), 40 ether);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        uint256 id = cell.submitAudit(address(target), address(target).codehash, specHash, specToolId, specErrors, 40 ether, declared, 0, 0);

        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);

        uint256 stake = cell.claimFilingStake();
        uint256 auditorBefore = token.balanceOf(auditorA);
        vm.prank(auditorA);
        token.approve(address(cell), stake);
        vm.prank(auditorA);
        cell.proveFail(id, verdictToolId, keccak256("fail.proof"));

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Claimed));

        vm.warp(block.timestamp + cell.claimResolutionWindow() + 1);
        cell.expireClaim(id);

        assertEq(
            uint256(cell.auditStateOf(id)),
            uint256(CellTypeDefs.AuditState.InAudit),
            "restored to InAudit"
        );
        assertEq(token.balanceOf(auditorA), auditorBefore, "auditor stake refunded on expire");
        (, uint256 aFailed,,,,) = cell.auditors(auditorA);
        assertEq(aFailed, 0, "no failed++ without reproduction");
    }

    // G-06 — uncapped issuance: confirm still mints (no supply-ceiling clamp).
    function test_confirm_mints_without_supply_cap() public {
        vm.prank(auditorA);
        cell.register();

        Target target = new Target(1);
        vm.prank(protocol);
        token.approve(address(cell), 10 ether);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        uint256 id = cell.submitAudit(address(target), address(target).codehash, specHash, specToolId, specErrors, 10 ether, declared, 0, 0);

        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditorA);
        cell.provePass(id, verdictToolId, resultRoot);

        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InBlock));
        assertGt(cell.auditBlockRewardMinted(id), 0, "uncapped curve still mints on confirm");
    }

    // G-08
    function test_protocol_not_self_assigned() public {
        vm.prank(protocol);
        cell.register();

        Target target = new Target(1);
        vm.prank(protocol);
        token.approve(address(cell), 10 ether);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        uint256 id = cell.submitAudit(address(target), address(target).codehash, specHash, specToolId, specErrors, 10 ether, declared, 0, 0);

        assertEq(cell.auditAuditorOf(id), address(0));
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Submitted));
    }

    // -------------------------------------------------- G-10: claim-verifier seam

    /// @dev Drive an ordinary audit to AwaitingWindow (PASS), ready for a post-pass claim.
    function _passedAudit() internal returns (uint256 id) {
        vm.prank(auditorA);
        cell.register();
        vm.prank(adversary);
        cell.register();

        Target target = new Target(1);
        vm.prank(protocol);
        token.approve(address(cell), 40 ether);
        bytes32[] memory declared2 = new bytes32[](1);
        declared2[0] = verdictToolId;
        vm.prank(protocol);
        id = cell.submitAudit(address(target), address(target).codehash, specHash, specToolId, specErrors, 40 ether, declared2, 0, 0);

        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditorA);
        cell.provePass(id, verdictToolId, resultRoot);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.AwaitingWindow));
    }

    // G-10a — verifier unset: claim with empty proof behaves as today.
    function test_g10_unset_verifier_allows_claim() public {
        uint256 id = _passedAudit();
        uint256 stake = cell.claimFilingStake();
        vm.prank(adversary);
        token.approve(address(cell), stake);
        vm.prank(adversary);
        cell.claimVulnerability(id, verdictToolId, keccak256("claim"), "");
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Claimed));
    }

    // G-10b — rejecting verifier: forged claim reverts before any state change.
    function test_g10_rejecting_verifier_blocks_claim() public {
        uint256 id = _passedAudit();
        RejectingVerifier v = new RejectingVerifier();
        cell.setClaimVerifier(address(v));

        uint256 stake = cell.claimFilingStake();
        uint256 advBefore = token.balanceOf(adversary);
        vm.prank(adversary);
        token.approve(address(cell), stake);
        vm.prank(adversary);
        vm.expectRevert(ClaimDisputeModule.ClaimProofRejected.selector);
        cell.claimVulnerability(id, verdictToolId, keccak256("claim"), hex"deadbeef");

        // No state moved: still AwaitingWindow, no claim record, no stake taken.
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.AwaitingWindow), "unchanged");
        assertEq(token.balanceOf(adversary), advBefore, "no stake taken");
        (,,,,, , bool exists,,,,,,) = cell.vulnerabilityClaims(id);
        assertTrue(!exists, "no claim filed");
    }

    // G-10c — accepting verifier: a proof-bearing claim proceeds.
    function test_g10_accepting_verifier_allows_claim() public {
        uint256 id = _passedAudit();
        AcceptingVerifier v = new AcceptingVerifier();
        cell.setClaimVerifier(address(v));

        uint256 stake = cell.claimFilingStake();
        vm.prank(adversary);
        token.approve(address(cell), stake);
        vm.prank(adversary);
        cell.claimVulnerability(id, verdictToolId, keccak256("claim"), hex"01");
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Claimed));
    }

    // G-10d — one-way lock: a wired verifier cannot be swapped out.
    function test_g10_verifier_lock_is_one_way() public {
        AcceptingVerifier v = new AcceptingVerifier();
        cell.setClaimVerifier(address(v));
        cell.lockClaimVerifier();
        vm.expectRevert(AuditCell.ClaimVerifierLocked.selector);
        cell.setClaimVerifier(address(0xBEEF));
    }
}

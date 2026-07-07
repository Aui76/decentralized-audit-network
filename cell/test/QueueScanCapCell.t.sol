// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./helpers/SpecValidationCellSetup.sol";
import "../contracts/ClaimDisputeModule.sol";
import "../contracts/SpecArbiterModule.sol";

contract ScanCapTarget {
    uint256 public x = 1;
}

/// @notice F-CELL-1 / F-CELL-2 oracle — Sybil-inflated queue cannot DoS dispute or spec-challenge paths.
contract QueueScanCapCellTest is SpecValidationCellSetup {
    uint256 internal constant SYBIL_COUNT = 300;
    uint256 internal constant MAX_SCAN = 256;
    /// @dev Without the scan cap, 300+ queue walks blow past this in production; capped path stays well under.
    uint256 internal constant DISPUTE_GAS_CEILING = 8_000_000;

    AuditCell cell;
    CellToken token;
    ClaimDisputeModule claimModule;
    SpecArbiterModule specArbiter;

    address protocol = address(0xBEEF);
    address auditor = address(0xA11CE);
    address disputeAuditor = address(0xD15E);
    address specArbiterPool = address(0xA2B1);
    address challenger = address(0xCAFE);
    address claimant = address(0xC1A1);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 resultRoot = keccak256("result.v1");
    bytes32 claimRoot = keccak256("claim.proof");
    bytes32 failErrorsRoot = keccak256("spec.fail");

    uint256 constant BOUNTY = 10 ether;

    ScanCapTarget target;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        cell = d.cell;
        token = d.token;
        claimModule = d.claimModule;
        specArbiter = d.specArbiterModule;
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);

        target = new ScanCapTarget();
        token.genesisMint(protocol, 100_000 ether);
        token.genesisMint(challenger, 500 ether);
        token.genesisMint(claimant, 500 ether);
        CellTestDeploy.attachMinter(d);

        assertEq(cell.increment(), 0, "gift-free posture");

        vm.prank(disputeAuditor);
        cell.register();
        vm.prank(specArbiterPool);
        cell.register();

        for (uint256 i = 0; i < SYBIL_COUNT; i++) {
            address sybil = address(uint160(0x100000 + i));
            vm.prank(sybil);
            cell.register();
        }

        assertGt(cell.queueLength(), MAX_SCAN, "inflated queue");

        vm.prank(auditor);
        cell.register();
        vm.prank(claimant);
        cell.register();
    }

    function _submitAndClaim() internal returns (uint256 id) {
        vm.startPrank(protocol);
        token.approve(address(cell), BOUNTY);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        id = cell.submitAudit(
            address(target),
            address(target).codehash,
            specHash,
            specToolId,
            EMPTY_SPEC_ERRORS,
            BOUNTY,
            declared,
            0,
            0
        );
        vm.stopPrank();

        _reachAwaitingWindow(cell, id, protocol, verdictToolId, resultRoot);

        uint256 stake = cell.claimFilingStake();
        vm.startPrank(claimant);
        token.approve(address(cell), stake);
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");
        vm.stopPrank();
    }

    function _disputeMin(uint256 bounty) internal pure returns (uint256) {
        return (bounty * 5000) / 10_000;
    }

    function test_protocol_dispute_open_bounded_gas_with_inflated_queue() public {
        uint256 id = _submitAndClaim();
        uint256 minB = _disputeMin(BOUNTY);

        vm.startPrank(protocol);
        token.approve(address(cell), minB);
        uint256 gasBefore = gasleft();
        uint256 disputeId = claimModule.openDisputeReaudit(id, minB);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        assertLt(gasUsed, DISPUTE_GAS_CEILING);
        assertGt(disputeId, id);
        address assigned = cell.auditAuditorOf(disputeId);
        assertTrue(assigned != address(0));
        assertTrue(assigned != protocol && assigned != auditor && assigned != claimant);
    }

    function test_claimant_dispute_open_bounded_gas_with_inflated_queue() public {
        uint256 id = _submitAndClaim();

        vm.prank(protocol);
        claimModule.protocolDeclineDisputeFunding(id);
        vm.warp(block.timestamp + claimModule.protocolClaimDecisionWindow() + 1);

        uint256 minB = _disputeMin(BOUNTY);
        vm.startPrank(claimant);
        token.approve(address(cell), minB);
        uint256 gasBefore = gasleft();
        uint256 disputeId = claimModule.claimantOpenDisputeReaudit(id, minB);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        assertLt(gasUsed, DISPUTE_GAS_CEILING);
        assertGt(disputeId, id);
        assertTrue(cell.auditAuditorOf(disputeId) != address(0));
    }

    function test_spec_challenge_bounded_gas_with_inflated_queue() public {
        vm.startPrank(protocol);
        token.approve(address(cell), BOUNTY);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        uint256 auditId = cell.submitAudit(
            address(target),
            address(target).codehash,
            specHash,
            specToolId,
            EMPTY_SPEC_ERRORS,
            BOUNTY,
            declared,
            0,
            0
        );
        vm.stopPrank();

        vm.startPrank(challenger);
        token.approve(address(cell), specArbiter.specChallengeStake());
        uint256 gasBefore = gasleft();
        specArbiter.challengeSpecInvalid(auditId, failErrorsRoot);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        assertLt(gasUsed, DISPUTE_GAS_CEILING);
        (,,,,, address assigned) = specArbiter.specChallenges(auditId);
        assertTrue(assigned != address(0));
    }

    function _expectedSpecArbiter(uint256 auditId, address chall, address exclude) internal view returns (address) {
        bytes32 seed = keccak256(
            abi.encode(
                "SPEC_ARBITER_V1",
                auditId,
                chall,
                exclude,
                blockhash(block.number - 1),
                cell.queueLength(),
                cell.totalSuccessfulAudits()
            )
        );
        address auditProtocol = cell.auditProtocolOf(auditId);
        address auditAuditor = cell.auditAuditorOf(auditId);
        address chosen = address(0);
        uint256 eligibleCount = 0;
        address cursor = cell.queueHead();
        uint256 scanned = 0;
        uint256 maxScan = cell.queueLength();
        if (maxScan > MAX_SCAN) maxScan = MAX_SCAN;
        while (cursor != address(0) && scanned < maxScan) {
            address next = cell.queueNext(cursor);
            if (
                cursor != auditProtocol && cursor != auditAuditor && cursor != chall && cursor != exclude
                    && cell.isEligible(cursor)
            ) {
                eligibleCount += 1;
                if (uint256(keccak256(abi.encode(seed, eligibleCount))) % eligibleCount == eligibleCount - 1) {
                    chosen = cursor;
                }
            }
            cursor = next;
            scanned += 1;
        }
        return chosen;
    }

    function test_spec_arbiter_matches_seeded_reservoir_draw() public {
        vm.startPrank(protocol);
        token.approve(address(cell), BOUNTY);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        uint256 auditId = cell.submitAudit(
            address(target),
            address(target).codehash,
            specHash,
            specToolId,
            EMPTY_SPEC_ERRORS,
            BOUNTY,
            declared,
            0,
            0
        );
        vm.stopPrank();

        vm.startPrank(challenger);
        token.approve(address(cell), specArbiter.specChallengeStake());
        specArbiter.challengeSpecInvalid(auditId, failErrorsRoot);
        vm.stopPrank();

        (,,,,, address assigned) = specArbiter.specChallenges(auditId);
        address expected = _expectedSpecArbiter(auditId, challenger, address(0));
        assertEq(assigned, expected);
        assertTrue(assigned != address(0));
    }
}

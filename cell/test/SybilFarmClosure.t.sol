// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

// ---------------------------------------------------------------------------
// PROPOSED PoC ARTIFACT — not part of the frozen L0 test tree.
// To run: copy this file into cell/test/ then:
//     cd cell && forge test --match-contract SybilFarmClosure -vv
// It mirrors CellFlaws.t.sol's harness (CellTestDeploy + genesisMint + tools),
// so the imports below assume it sits in cell/test/.
//
// What it demonstrates (attack A-1, tokenomics-sybil-hardening-proposal.txt):
//   A single attacker controlling BOTH the protocol address (P) and the auditor
//   address (V) runs a wash audit. The escrowed bounty P->V nets to zero, and
//   the positive-block reward is MINTED on top — so the attacker's combined
//   (P+V) balance rises by exactly the minted reward, at no net token cost.
// ---------------------------------------------------------------------------

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/CellStorage.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/IssuanceModule.sol";
import "./helpers/CellTestDeploy.sol";
import "./helpers/IssuanceCellStub.sol";

contract SybilTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @dev Confirms A-1: protocol+auditor Sybil harvests minted reward with a washed bounty.
contract SybilFarmClosure is Test {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    IssuanceModule issuance;

    // Both addresses are controlled by the SAME attacker (the whole point of A-1).
    address attackerProtocol = address(0xA11CE); // P
    address attackerAuditor  = address(0xB0B);   // V

    bytes32 specToolId   = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash     = keccak256("spec.v1");
    bytes32 specErrors   = keccak256("errors.v1");
    bytes32 resultRoot   = keccak256("result.v1");

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deployWithoutAssignment(address(this));
        token = d.token;
        cell = d.cell;
        escrow = d.escrow;
        issuance = d.issuance;
        // Seed only the protocol side with the bounty capital; the auditor side starts at 0.
        token.genesisMint(attackerProtocol, 50_000 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
    }

    function test_sybil_self_audit_is_net_positive() public {
        // V registers as auditor (position 1 => zero required hold under (N-1)*increment).
        vm.prank(attackerAuditor);
        cell.register();

        SybilTarget target = new SybilTarget(1);

        // BASELINE = the attacker's INITIAL capital, snapshotted BEFORE the bounty is escrowed.
        // (Bug fix: a snapshot taken after submit omits the 10 AUDIT sitting in escrow, which
        //  round-trips back to V on confirm — that made the old assert under-count by one bounty.)
        uint256 combinedBefore = token.balanceOf(attackerProtocol) + token.balanceOf(attackerAuditor);

        // P funds a 10 AUDIT bounty and submits an audit against its own contract.
        vm.prank(attackerProtocol);
        token.approve(address(cell), 10 ether);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(attackerProtocol);
        uint256 id = cell.submitAudit(
            address(target), address(target).codehash,
            specHash, specToolId, specErrors,
            10 ether, declared, 0, 0
        );

        // P approves the assigned auditor (V), V accepts, V passes its own protocol's contract.
        vm.prank(attackerProtocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(attackerAuditor);
        cell.acceptAudit(id, specErrors);
        vm.prank(attackerAuditor);
        cell.provePass(id, verdictToolId, resultRoot);

        // Wait out the audit window and confirm -> pays bounty to V and MINTS the reward.
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);

        uint256 minted = cell.auditBlockRewardMinted(id);
        assertGt(minted, 0, "positive-block reward was minted");

        uint256 combinedAfter = token.balanceOf(attackerProtocol) + token.balanceOf(attackerAuditor);

        // The bounty washed (P->V, same attacker); the ONLY delta is the minted reward.
        assertEq(
            combinedAfter,
            combinedBefore + minted,
            "attacker combined balance rose by exactly the minted reward (bounty netted to zero)"
        );

        emit log_named_uint("minted reward (pure attacker profit, wei)", minted);
    }

    function test_distinct_gate_crushes_mint_vs_raw_count_path() public {
        _warmHonestNetwork();
        uint256 honestNetMean = issuance.networkCumulativeBounty() / issuance.networkAuditCount();

        vm.prank(attackerAuditor);
        cell.register();

        SybilTarget target = new SybilTarget(99);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;

        uint256 washBounty = 1000 ether;
        for (uint256 i = 0; i < 10; i++) {
            SybilTarget washTarget = new SybilTarget(200 + i);
            _runSybilWash(washTarget, declared, washBounty, i);
        }

        uint256 netMean = issuance.networkCumulativeBounty() / issuance.networkAuditCount();
        assertApproxEqRel(netMean, honestNetMean, 0.05e18, "ring washes do not pump netMean");

        uint256 nRaw = issuance.protocolSubmissionCount(attackerProtocol);
        uint256 protoMean = issuance.protocolCumulativeBounty(attackerProtocol) / nRaw;
        uint256 credRaw = (nRaw * protoMean + issuance.kProtocol() * netMean)
            / (nRaw + issuance.kProtocol());
        uint256 credDistinct = issuance.previewCredBountyForSettle(attackerAuditor, attackerProtocol, washBounty);
        uint256 credNaiveDistinct =
            (1 * protoMean + issuance.kProtocol() * netMean) / (1 + issuance.kProtocol());

        assertEq(issuance.protocolDistinctAuditors(attackerProtocol), 0, "ring auditor never counts");
        assertLt(credDistinct, credRaw, "distinct cred below raw-count path");
        assertApproxEqRel(credDistinct, netMean, 0.02e18, "distinct cred tracks netMean");
        assertGe((credNaiveDistinct * 10_000) / credDistinct, 8_000, "~10x crush vs naive nEff=1");

        uint256 combinedBefore = token.balanceOf(attackerProtocol) + token.balanceOf(attackerAuditor);

        vm.prank(attackerProtocol);
        token.approve(address(cell), washBounty);
        uint256 id = _submitSybilUntilRingAuditor(target, declared, washBounty, 10);
        vm.prank(attackerProtocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(attackerAuditor);
        cell.acceptAudit(id, specErrors);
        vm.prank(attackerAuditor);
        cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);

        uint256 minted = cell.auditBlockRewardMinted(id);
        assertGt(minted, 0);

        uint256 combinedAfter = token.balanceOf(attackerProtocol) + token.balanceOf(attackerAuditor);
        assertEq(combinedAfter, combinedBefore + minted, "snapshot before submit captures full mint delta");

        uint256 crushFactor = (credNaiveDistinct * 10_000) / credDistinct;
        emit log_named_uint("honestNetMean (wei)", honestNetMean);
        emit log_named_uint("post-wash netMean (wei)", netMean);
        emit log_named_uint("credRaw (wei)", credRaw);
        emit log_named_uint("credDistinct (wei)", credDistinct);
        emit log_named_uint("credNaiveDistinct nEff=1 (wei)", credNaiveDistinct);
        emit log_named_uint("cred crush factor bps (x10000)", crushFactor);
        emit log_named_uint("11th wash minted (wei)", minted);
    }

    function test_established_honest_protocol_still_moves_netMean() public {
        IssuanceModule iss = new IssuanceModule(address(this));
        IssuanceCellStub stub = new IssuanceCellStub(iss);
        CellToken t = new CellToken();
        CellEscrow e = new CellEscrow(address(t));
        iss.wire(address(stub), address(t), address(e));
        t.setMinter(address(iss));
        e.setIssuanceModule(address(iss));

        address honestProtocol = address(0xE005);
        address auditor1 = address(0xA001);
        address auditor2 = address(0xA002);
        address auditor3 = address(0xA003);
        uint256 smallBounty = 10 ether;
        uint256 highBounty = 500 ether;

        _issuanceWarm(iss, stub, smallBounty);
        uint256 baselineNetMean = iss.networkCumulativeBounty() / iss.networkAuditCount();

        _establishAuditor(iss, stub, auditor1, smallBounty);
        _establishAuditor(iss, stub, auditor2, smallBounty);
        _establishAuditor(iss, stub, auditor3, smallBounty);

        stub.settlePositiveBlock(1, auditor1, honestProtocol, highBounty);
        stub.settlePositiveBlock(2, auditor2, honestProtocol, highBounty);
        stub.settlePositiveBlock(3, auditor3, honestProtocol, highBounty);
        assertGe(iss.protocolDistinctAuditors(honestProtocol), iss.credibilityCountThreshold());

        uint256 netMeanBeforeLift = iss.networkCumulativeBounty() / iss.networkAuditCount();
        stub.settlePositiveBlock(4, auditor1, honestProtocol, highBounty);
        uint256 netMeanAfter = iss.networkCumulativeBounty() / iss.networkAuditCount();

        assertGt(netMeanAfter, baselineNetMean, "established honest protocol moves netMean");
        assertGt(netMeanAfter, netMeanBeforeLift, "further established confirm lifts netMean");
    }

    function _issuanceWarm(IssuanceModule iss, IssuanceCellStub stub, uint256 bounty) internal {
        address[4] memory auditors = [
            address(0xB100),
            address(0xB200),
            address(0xB300),
            address(0xB400)
        ];
        address[4] memory protocols = [
            address(0xC100),
            address(0xC200),
            address(0xC300),
            address(0xC400)
        ];
        for (uint256 i = 0; i < auditors.length; i++) {
            stub.settlePositiveBlock(i + 100, auditors[i], protocols[i], bounty);
            stub.settlePositiveBlock(i + 200, auditors[i], protocols[(i + 1) % 4], bounty);
        }
    }

    function _establishAuditor(IssuanceModule iss, IssuanceCellStub stub, address auditor, uint256 bounty)
        internal
    {
        stub.settlePositiveBlock(uint256(keccak256(abi.encode(auditor, 1))), auditor, address(0xD100), bounty);
        stub.settlePositiveBlock(uint256(keccak256(abi.encode(auditor, 2))), auditor, address(0xD200), bounty);
        stub.settlePositiveBlock(uint256(keccak256(abi.encode(auditor, 3))), auditor, address(0xD300), bounty);
        assertGe(iss.auditorDistinctProtocols(auditor), iss.credibilityCountThreshold());
    }

    function _warmHonestNetwork() internal {
        address honestAuditor = address(0xC001);
        vm.prank(honestAuditor);
        cell.register();
        for (uint256 i = 0; i < 12; i++) {
            SybilTarget t = new SybilTarget(100 + i);
            address warmProtocol = address(uint160(0x7000 + i));
            vm.prank(attackerProtocol);
            token.transfer(warmProtocol, 50 ether);
            bytes32[] memory declared = new bytes32[](1);
            declared[0] = verdictToolId;
            vm.startPrank(warmProtocol);
            token.approve(address(cell), 10 ether);
            uint256 id = cell.submitAudit(
                address(t), address(t).codehash,
                specHash, specToolId, specErrors,
                10 ether, declared, 0, 0
            );
            vm.stopPrank();
            _confirmWithAssignedAuditor(id);
        }
    }

    function _confirmWithAssignedAuditor(uint256 id) internal {
        (address protocol, address assigned,,,,,,,,,,,,,,,,,,) = cell.audits(id);
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(assigned);
        cell.acceptAudit(id, specErrors);
        vm.prank(assigned);
        cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);
    }

    function _submitSybilUntilRingAuditor(
        SybilTarget target,
        bytes32[] memory declared,
        uint256 bounty,
        uint256 priorSuccessfulWashes
    ) internal returns (uint256 id) {
        vm.prank(attackerProtocol);
        token.approve(address(cell), bounty);
        vm.prank(attackerProtocol);
        id = cell.submitAudit(
            address(target), address(target).codehash,
            specHash, specToolId, specErrors,
            bounty, declared, 0, 0
        );
        (, address assigned,,,,,,,,,,,,,,,,,,) = cell.audits(id);
        uint256 maxRejects = 1 + priorSuccessfulWashes / 10;
        if (maxRejects > 5) maxRejects = 5;
        uint256 rejects;
        while (assigned != attackerAuditor && rejects < maxRejects) {
            vm.prank(attackerProtocol);
            cell.protocolRejectAuditor(id);
            (, assigned,,,,,,,,,,,,,,,,,,) = cell.audits(id);
            rejects++;
        }
        require(assigned == attackerAuditor, "ring auditor not assigned");
    }

    function _runSybilWash(SybilTarget target, bytes32[] memory declared, uint256 bounty, uint256 washIndex)
        internal
    {
        uint256 id = _submitSybilUntilRingAuditor(target, declared, bounty, washIndex);
        vm.prank(attackerProtocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(attackerAuditor);
        cell.acceptAudit(id, specErrors);
        vm.prank(attackerAuditor);
        cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);
    }
}

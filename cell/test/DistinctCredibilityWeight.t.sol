// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/IssuanceModule.sol";
import "./helpers/IssuanceCellStub.sol";

/// @notice Unit tests for distinct-counterparty credibility weight (DEC-6 + §2.5 mutual gate).
contract DistinctCredibilityWeightTest is Test {
    CellToken internal token;
    CellEscrow internal escrow;
    IssuanceModule internal issuance;
    IssuanceCellStub internal stub;

    address internal auditorA = address(0xA001);
    address internal auditorB = address(0xA002);
    address internal auditorC = address(0xA003);
    address internal protocolP = address(0xB001);
    address internal protocolQ = address(0xB002);
    address internal protocolR = address(0xB003);
    address internal protocolS = address(0xB004);

    uint256 internal constant BOUNTY = 10 ether;
    uint256 internal constant K = 10;

    function setUp() public {
        token = new CellToken();
        escrow = new CellEscrow(address(token));
        issuance = new IssuanceModule(address(this));
        stub = new IssuanceCellStub(issuance);
        issuance.wire(address(stub), address(token), address(escrow));
        token.setMinter(address(issuance));
        escrow.setIssuanceModule(address(issuance));
    }

    function _settle(address auditor, address protocol, uint256 bounty) internal {
        stub.settlePositiveBlock(uint256(keccak256(abi.encode(auditor, protocol, bounty))), auditor, protocol, bounty);
    }

    function _z(uint256 nEff) internal pure returns (uint256) {
        return (nEff * 10_000) / (nEff + K);
    }

    function _cred(uint256 nEff, uint256 protoMean, uint256 netMean) internal pure returns (uint256) {
        return (nEff * protoMean + K * netMean) / (nEff + K);
    }

    function test_z_grows_only_with_distinct_established_auditors() public {
        _warmNetwork();

        assertEq(issuance.protocolDistinctAuditors(protocolP), 0);
        _establishAuditor(auditorA);

        uint256 highBounty = 1000 ether;
        uint256 netMean = issuance.networkCumulativeBounty() / issuance.networkAuditCount();
        uint256 credBefore = issuance.previewCredBountyForSettle(auditorA, protocolP, highBounty);
        assertEq(credBefore, netMean, "nEff=0 shrinks to netMean");

        _settle(auditorA, protocolP, highBounty);
        assertEq(issuance.protocolDistinctAuditors(protocolP), 1);

        uint256 n = issuance.protocolSubmissionCount(protocolP);
        uint256 protoMean = issuance.protocolCumulativeBounty(protocolP) / n;
        netMean = issuance.networkCumulativeBounty() / issuance.networkAuditCount();
        address freshAuditor = address(0xD001);
        uint256 credAfter = issuance.previewCredBountyForSettle(freshAuditor, protocolP, highBounty);

        assertGt(protoMean, netMean, "protocol mean elevated vs network");
        assertGt(credAfter, credBefore, "Z rises after first established auditor counts");
        assertEq(credAfter, _cred(1, protoMean, netMean));
    }

    function test_z_shrinks_with_reused_auditor() public {
        _warmNetwork();
        _establishAuditor(auditorA);

        _settle(auditorA, protocolP, BOUNTY);
        assertEq(issuance.protocolDistinctAuditors(protocolP), 1);

        uint256 netMean = issuance.networkCumulativeBounty() / issuance.networkAuditCount();
        uint256 n = issuance.protocolSubmissionCount(protocolP);
        uint256 protoMean = issuance.protocolCumulativeBounty(protocolP) / n;
        uint256 credOne = _cred(1, protoMean, netMean);

        _settle(auditorA, protocolP, BOUNTY);
        assertEq(issuance.protocolDistinctAuditors(protocolP), 1, "reuse does not increment nEff");

        uint256 credReuse = issuance.previewCredBountyForSettle(auditorA, protocolP, BOUNTY);
        assertEq(credReuse, credOne, "Z unchanged on reused (P,A) pair");
    }

    function test_genesis_preview_cred_bounty_matches_settle_path() public {
        uint256 rawBounty = 5000 ether;
        uint256 preview = issuance.previewCredBountyForSettle(auditorA, protocolP, rawBounty);
        assertEq(preview, rawBounty, "genesis nEff=0 cred equals raw bounty (netMean fallback)");

        _settle(auditorA, protocolP, rawBounty);
        assertEq(issuance.emaSlow(), (rawBounty * issuance.emaSlowUnprovenWeightBps()) / 10_000);

        uint256 previewSecond = issuance.previewCredBountyForSettle(auditorA, protocolP, rawBounty);
        uint256 netMean = issuance.networkCumulativeBounty() / issuance.networkAuditCount();
        assertEq(previewSecond, netMean, "ring auditor nEff=0 on reuse keeps cred at netMean");
    }

    function _warmNetwork() internal {
        _settle(auditorB, protocolQ, BOUNTY);
        _settle(auditorC, protocolR, BOUNTY);
        _settle(auditorB, protocolR, BOUNTY);
    }

    function _establishAuditor(address auditor) internal {
        _settle(auditor, protocolQ, BOUNTY);
        _settle(auditor, protocolR, BOUNTY);
        _settle(auditor, protocolS, BOUNTY);
        assertGe(issuance.auditorDistinctProtocols(auditor), issuance.credibilityCountThreshold());
    }
}

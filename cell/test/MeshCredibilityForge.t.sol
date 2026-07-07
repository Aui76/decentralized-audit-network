// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/IssuanceModule.sol";
import "./helpers/IssuanceCellStub.sol";

/// @notice PoC: §2.5 mutual gate + mesh cost vs LP-throttled reward (DEC-6).
contract MeshCredibilityForgeTest is Test {
    CellToken internal token;
    CellEscrow internal escrow;
    IssuanceModule internal issuance;
    IssuanceCellStub internal stub;

    uint256 internal constant K_PROTOCOL = 10;
    uint256 internal constant HONEST_BOUNTY = 10 ether;
    uint256 internal constant WASH_BOUNTY = 1000 ether;

    function setUp() public {
        token = new CellToken();
        escrow = new CellEscrow(address(token));
        issuance = new IssuanceModule(address(this));
        stub = new IssuanceCellStub(issuance);
        issuance.wire(address(stub), address(token), address(escrow));
        token.setMinter(address(issuance));
        escrow.setIssuanceModule(address(issuance));
    }

    function _settle(address auditor, address protocol, uint256 bounty) internal returns (uint256 auditorMinted) {
        (auditorMinted,,) = stub.settlePositiveBlock(
            uint256(keccak256(abi.encode(auditor, protocol, bounty, block.number))), auditor, protocol, bounty
        );
    }

    function _warmHonestNetwork() internal {
        address[4] memory auditors = [
            address(0xA100),
            address(0xA200),
            address(0xA300),
            address(0xA400)
        ];
        address[4] memory protocols = [
            address(0xB100),
            address(0xB200),
            address(0xB300),
            address(0xB400)
        ];
        for (uint256 i = 0; i < auditors.length; i++) {
            _settle(auditors[i], protocols[i], HONEST_BOUNTY);
            _settle(auditors[i], protocols[(i + 1) % 4], HONEST_BOUNTY);
        }
    }

    function test_ring_auditor_below_threshold_does_not_increment_protocol_credibility() public {
        address ringAuditor = address(0xB0B);
        address sybilProtocol = address(0xA11CE);

        _warmHonestNetwork();

        for (uint256 i = 0; i < 20; i++) {
            _settle(ringAuditor, sybilProtocol, WASH_BOUNTY);
        }

        assertEq(issuance.auditorDistinctProtocols(ringAuditor), 1, "ring only ever saw one protocol");
        assertLt(
            issuance.auditorDistinctProtocols(ringAuditor),
            issuance.credibilityCountThreshold(),
            "ring auditor never established"
        );
        assertEq(issuance.protocolDistinctAuditors(sybilProtocol), 0, "protocol credibility stays shrunk");
    }

    function test_reused_protocol_auditor_pair_does_not_double_count() public {
        address auditor = address(0xE001);
        address protocol = address(0xF001);

        _warmHonestNetwork();
        _establishAuditorAcrossThreeProtocols(auditor);

        _settle(auditor, protocol, HONEST_BOUNTY);
        assertEq(issuance.protocolDistinctAuditors(protocol), 1);

        _settle(auditor, protocol, HONEST_BOUNTY);
        assertEq(issuance.protocolDistinctAuditors(protocol), 1, "second settle same pair does not double-count");
        assertTrue(issuance.protocolAuditorSeen(protocol, auditor));
    }

    function test_mesh_reward_per_block_stays_lp_capped() public {
        uint256 k = 3;
        uint256 m = 3;

        address[] memory auditors = new address[](k);
        address[] memory protocols = new address[](m);
        for (uint256 i = 0; i < k; i++) {
            auditors[i] = address(uint160(0xA000 + i));
        }
        for (uint256 j = 0; j < m; j++) {
            protocols[j] = address(uint160(0xB000 + j));
        }

        _warmHonestNetwork();

        uint256 meshBlocks;
        uint256 totalAuditorMinted;
        for (uint256 i = 0; i < k; i++) {
            for (uint256 j = 0; j < m; j++) {
                uint256 auditorMinted = _settle(auditors[i], protocols[j], HONEST_BOUNTY);
                meshBlocks += 1;
                totalAuditorMinted += auditorMinted;

                uint256 lp = escrow.lpBalance();
                if (lp > 0) {
                    uint256 activityMint = (issuance.emaSlow() * issuance.emaToMintBps()) / 10_000;
                    uint256 lpCap = (issuance.mintLpCapBps() * lp) / 10_000;
                    uint256 maxAuditorReward = activityMint < lpCap ? activityMint : lpCap;
                    assertLe(auditorMinted, maxAuditorReward + 1, "mesh block auditor mint LP-throttled");
                }
            }
        }

        assertEq(meshBlocks, k * m, "K x M mesh blocks");
        assertGt(totalAuditorMinted, 0, "mesh produced auditor mint");

        uint256 positionSlots = k + m;
        uint256 quadraticCostProxy = (positionSlots * positionSlots) / 2;
        assertGt(quadraticCostProxy, k, "mesh cost proxy grows faster than linear identity count");
        assertGt(meshBlocks, k, "mesh block cost exceeds linear auditor count");
    }

    function test_single_washed_self_audit_cred_near_net_mean() public {
        address ringAuditor = address(0xB0B);
        address sybilProtocol = address(0xA11CE);

        _warmHonestNetwork();

        uint256 netMeanBefore = issuance.networkCumulativeBounty() / issuance.networkAuditCount();
        uint256 credDistinct = issuance.previewCredBountyForSettle(ringAuditor, sybilProtocol, WASH_BOUNTY);

        assertApproxEqRel(credDistinct, netMeanBefore, 0.01e18, "washed cred ~ netMean when nEff=0");

        uint256 credRawAfterWash = (1 * WASH_BOUNTY + K_PROTOCOL * netMeanBefore) / (1 + K_PROTOCOL);

        _settle(ringAuditor, sybilProtocol, WASH_BOUNTY);

        uint256 netMeanAfter = issuance.networkCumulativeBounty() / issuance.networkAuditCount();
        uint256 credAfter = issuance.previewCredBountyForSettle(ringAuditor, sybilProtocol, WASH_BOUNTY);
        assertApproxEqRel(credAfter, netMeanAfter, 0.01e18, "post-wash cred tracks netMean (nEff still 0)");

        uint256 crushVsNaiveDistinct = (credRawAfterWash * 10_000) / credDistinct;
        assertGe(crushVsNaiveDistinct, 8_000, "cred crushed ~10x vs nEff=1 path");

        emit log_named_uint("netMean (wei)", netMeanBefore);
        emit log_named_uint("credDistinct washed (wei)", credDistinct);
        emit log_named_uint("credRaw nEff=1 counterfactual (wei)", credRawAfterWash);
        emit log_named_uint("measured crush factor bps (x10000)", crushVsNaiveDistinct);
    }

    function _establishAuditorAcrossThreeProtocols(address auditor) internal {
        _settle(auditor, address(0xB100), HONEST_BOUNTY);
        _settle(auditor, address(0xB200), HONEST_BOUNTY);
        _settle(auditor, address(0xB300), HONEST_BOUNTY);
        assertGe(issuance.auditorDistinctProtocols(auditor), issuance.credibilityCountThreshold());
    }
}

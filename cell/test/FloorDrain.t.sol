// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

// ---------------------------------------------------------------------------
// PROPOSED PoC ARTIFACT — attack A-5 (tokenomics-sybil-hardening-proposal.txt)
// To run: copy into cell/test/ then:
//     cd cell && forge test --match-contract FloorDrain -vv
//
// Drives the network into Depression (emaFast/emaSlow < 7000 bps) and shows each
// confirmed audit pays the auditor a real-token floor supplement from CellEscrow,
// capped at maxEscrowDrawdownPerAudit (30 bps), repeatable per window.
// ---------------------------------------------------------------------------

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/IssuanceModule.sol";
import "./helpers/CellTestDeploy.sol";

contract FloorTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @dev Confirms A-5: depression floor bleeds pre-funded CellEscrow on every confirm.
contract FloorDrain is Test {
    using stdStorage for StdStorage;
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    IssuanceModule issuance;

    address protocol = address(0xA11CE);
    address auditor = address(0xB0B);

    uint256 constant HIGH_BOUNTY = 500 ether;
    uint256 constant LOW_BOUNTY = 1 ether;
    uint256 constant WARM_CONFIRMS = 15;
    uint256 constant MAX_LOW_CONFIRMS = 200;

    address[] internal declineProtocols;

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");

    uint256 constant ESCROW_SEED = 1_000_000 ether;
    uint256 constant AUX_PROTOCOL_FUND = 400_000 ether;
    uint256 saltNonce = 1;

    bytes32 constant DEPRESSION_FLOOR_TOPIC = keccak256("DepressionFloorPaid(address,uint256,uint256)");

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        escrow = d.escrow;
        issuance = d.issuance;

        token.genesisMint(protocol, 100_000 ether);
        token.genesisMint(address(this), ESCROW_SEED + AUX_PROTOCOL_FUND);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        _fundEscrow(ESCROW_SEED);

        vm.prank(auditor);
        cell.register();
    }

    function test_depression_floor_draws_real_escrow_repeatable() public {
        _confirmPass(500 ether);
        _forceDepressionState();

        uint256 fastRatio = _fastRatioBps();
        assertLt(fastRatio, issuance.depressionThresholdBps(), "network in depression");
        assertEq(
            uint256(issuance.issuanceNetworkState()),
            uint256(IssuanceModule.IssuanceNetworkState.Depression)
        );
        assertGt(issuance.depressionIntensityBps(), 0);

        uint256 escrowAtDepression = escrow.escrowBalance();
        uint256 drawdownCap = (escrowAtDepression * issuance.maxEscrowDrawdownPerAudit()) / 10_000;

        uint256 paid1 = _confirmPassExpectFloor(1 ether);
        assertGt(paid1, 0, "first depression confirm pays floor from escrow");
        assertLe(paid1, drawdownCap + 1, "floor respects 30-bps drawdown cap");

        uint256 paid2 = _confirmPassExpectFloor(1 ether);
        assertGt(paid2, 0, "second depression confirm repeats floor bleed");

        emit log_named_uint("depression floor paid (confirm 1, wei)", paid1);
        emit log_named_uint("depression floor paid (confirm 2, wei)", paid2);
        emit log_named_uint("fast/slow ratio bps at depression", fastRatio);
    }

    /// @dev S2.6 organic depression reachability (no stdstore on EMAs).
    ///      credBounty at settle uses protoMean/netMean, not rawBounty; kProtocol=10
    ///      anchors cred to netMean. Low raw bounties drag means slowly; emaFast/emaSlow
    ///      stay near 1.0 during gradual decline. Fails with mechanism finding if not crossed.
    function test_natural_activity_decline_reaches_depression() public {
        address protocolB = address(0xB001);
        address protocolC = address(0xC001);
        address protocolD = address(0xD001);
        token.transfer(protocolB, 100_000 ether);
        token.transfer(protocolC, 100_000 ether);
        token.transfer(protocolD, 100_000 ether);

        declineProtocols = new address[](4);
        declineProtocols[0] = protocol;
        declineProtocols[1] = protocolB;
        declineProtocols[2] = protocolC;
        declineProtocols[3] = protocolD;

        // Established auditor (slowWeight = 10000): 5 successful + 3 distinct protocols.
        _confirmPassFor(protocolB, HIGH_BOUNTY);
        _confirmPassFor(protocolC, HIGH_BOUNTY);
        _confirmPassFor(protocolD, HIGH_BOUNTY);
        _confirmPassFor(protocolB, HIGH_BOUNTY);
        _confirmPassFor(protocolC, HIGH_BOUNTY);
        (uint256 successful,,,,,) = cell.auditors(auditor);
        assertGe(successful, issuance.emaSlowMinSuccessfulForFullWeight(), "auditor established");

        // High steady state on primary protocol (nEff >= 1 after first warm confirm here).
        for (uint256 i = 0; i < WARM_CONFIRMS; i++) {
            _confirmPassFor(protocol, HIGH_BOUNTY);
        }
        assertGe(_fastRatioBps(), issuance.depressionThresholdBps(), "healthy after warm");
        assertGt(issuance.emaFast(), 0);
        assertGt(issuance.emaSlow(), 0);

        uint256 credAfterWarm = issuance.previewCredBountyForSettle(auditor, protocol, LOW_BOUNTY);
        emit log_named_uint("credBounty preview after warm (wei)", credAfterWarm);
        emit log_named_uint("netMean after warm (wei)", issuance.networkCumulativeBounty() / issuance.networkAuditCount());

        uint256 lowConfirms;
        uint256 floorAtCross;
        bool crossed;

        for (uint256 i = 0; i < MAX_LOW_CONFIRMS; i++) {
            address payer = declineProtocols[i % declineProtocols.length];
            vm.recordLogs();
            _confirmPassFor(payer, LOW_BOUNTY);
            lowConfirms++;

            if (i == 99 || i == 199) {
                emit log_named_uint("credBounty at low confirm", issuance.previewCredBountyForSettle(auditor, payer, LOW_BOUNTY));
                emit log_named_uint("fast/slow ratio bps mid-decline", _fastRatioBps());
            }

            if (!crossed && _fastRatioBps() < issuance.depressionThresholdBps()) {
                crossed = true;
                floorAtCross = _extractDepressionFloorPaid(vm.getRecordedLogs());
                assertEq(
                    uint256(issuance.issuanceNetworkState()),
                    uint256(IssuanceModule.IssuanceNetworkState.Depression)
                );
            }
        }

        emit log_named_uint("emaFast wei final", issuance.emaFast());
        emit log_named_uint("emaSlow wei final", issuance.emaSlow());
        emit log_named_uint("fast/slow ratio bps final", _fastRatioBps());
        emit log_named_uint("low confirms attempted", lowConfirms);
        emit log_named_uint("netMean final (wei)", issuance.networkCumulativeBounty() / issuance.networkAuditCount());

        assertTrue(crossed, "organic depression not reached - report as mechanism finding");
        assertLt(_fastRatioBps(), issuance.depressionThresholdBps());
        assertGt(floorAtCross, 0, "crossing confirm pays floor from escrow");

        emit log_named_uint("low bounty confirms to cross depression", lowConfirms);
        emit log_named_uint("fast/slow ratio bps after decline", _fastRatioBps());
        emit log_named_uint("depression floor paid at cross (wei)", floorAtCross);
    }

    function _forceDepressionState() internal {
        stdstore.target(address(issuance)).sig("emaSlow()").checked_write(1000 ether);
        stdstore.target(address(issuance)).sig("emaFast()").checked_write(100 ether);
        stdstore.target(address(issuance)).sig("lastEmaFast()").checked_write(100 ether);
    }

    function _depressNetwork(uint256 smallConfirms) internal {
        for (uint256 i = 0; i < smallConfirms; i++) {
            _confirmPass(1 ether);
        }
    }

    function _confirmPassExpectFloor(uint256 bounty) internal returns (uint256 floorPaid) {
        vm.recordLogs();
        _confirmPass(bounty);
        floorPaid = _extractDepressionFloorPaid(vm.getRecordedLogs());
    }

    function _confirmPass(uint256 bounty) internal {
        _confirmPassFor(protocol, bounty);
    }

    function _confirmPassFor(address payer, uint256 bounty) internal {
        FloorTarget target = new FloorTarget(saltNonce++);
        vm.startPrank(payer);
        token.approve(address(cell), bounty);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        uint256 id = cell.submitAudit(
            address(target), address(target).codehash, specHash, specToolId, specErrors, bounty, declared, 0, 0
        );
        vm.stopPrank();
        vm.prank(payer);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditor);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditor);
        cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);
    }

    function _fastRatioBps() internal view returns (uint256) {
        uint256 slow = issuance.emaSlow();
        if (slow == 0) return type(uint256).max;
        return (issuance.emaFast() * 10_000) / slow;
    }

    function _extractDepressionFloorPaid(Vm.Log[] memory logs) internal pure returns (uint256 paid) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != DEPRESSION_FLOOR_TOPIC) continue;
            paid = abi.decode(logs[i].data, (uint256));
            return paid;
        }
    }

    function _fundEscrow(uint256 amount) internal {
        token.transfer(address(escrow), amount);
        vm.prank(address(cell.issuanceModule()));
        escrow.recordDeposit(amount);
    }
}

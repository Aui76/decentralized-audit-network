// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

// ---------------------------------------------------------------------------
// PoC ARTIFACT, CLOSED — attack A-5 (tokenomics-sybil-hardening-proposal.txt); its open question was
// decided by DEC-32 (2026-07-18, body/proposals/closed/floordrain-organic-depression-finding-proposal.txt).
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
    // §2.6 depression-reachability finding — empirically confirmed 2026-07-18 (DEC-32).
    // Organic decline via LOW-bounty confirms CANNOT reach Depression. The credBounty de-pollution
    // that closed A-5 (fake-depression floor drain) pins every below-mean bounty UP to ~the network
    // mean, so a 1-ether low bounty contributes ~netMean to the EMAs and cannot drag emaFast away from
    // emaSlow — the fast/slow ratio stays parked near 100%, never approaching the 7000-bps threshold
    // (measured: ratio 9916 bps after 200 low confirms; credBounty 395 ether for a 1-ether bounty).
    // This test ASSERTS that property (it replaced a false-premise red "must reach depression"). The
    // depression FLOOR itself is still exercised by test_depression_floor_draws_real_escrow_repeatable
    // (the manipulation path), so floor coverage is unchanged; what is proven here is that the organic
    // path INTO depression is closed by construction — the A-11/§2.6 two-for-one, on chain.
    function test_organic_low_bounty_decline_cannot_reach_depression() public {
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

        // High steady state on primary protocol.
        for (uint256 i = 0; i < WARM_CONFIRMS; i++) {
            _confirmPassFor(protocol, HIGH_BOUNTY);
        }
        assertGe(_fastRatioBps(), issuance.depressionThresholdBps(), "healthy after warm");
        assertGt(issuance.emaFast(), 0);
        assertGt(issuance.emaSlow(), 0);

        // The de-pollution in one number: a LOW_BOUNTY (1 ether) previews a credBounty pinned up near the
        // network mean, orders of magnitude above the raw low bounty — this is WHY depression is organically
        // unreachable (the EMAs never see the low value).
        uint256 credLow = issuance.previewCredBountyForSettle(auditor, protocol, LOW_BOUNTY);
        uint256 netMean = issuance.networkCumulativeBounty() / issuance.networkAuditCount();
        emit log_named_uint("credBounty for a 1-ether low bounty (wei)", credLow);
        emit log_named_uint("netMean after warm (wei)", netMean);
        assertGt(credLow, LOW_BOUNTY * 50, "low bounty is pinned FAR above its raw value (de-pollution)");
        assertGe(credLow, netMean / 2, "pinned credBounty sits near the network mean, not the low bounty");

        // Drive the full organic decline. The ratio must NEVER cross into depression.
        bool crossed;
        uint256 minRatioSeen = type(uint256).max;
        for (uint256 i = 0; i < MAX_LOW_CONFIRMS; i++) {
            address payer = declineProtocols[i % declineProtocols.length];
            _confirmPassFor(payer, LOW_BOUNTY);
            uint256 r = _fastRatioBps();
            if (r < minRatioSeen) minRatioSeen = r;
            if (r < issuance.depressionThresholdBps()) crossed = true;
        }

        emit log_named_uint("fast/slow ratio bps final", _fastRatioBps());
        emit log_named_uint("min fast/slow ratio bps across decline", minRatioSeen);
        emit log_named_uint("low confirms applied", MAX_LOW_CONFIRMS);

        // THE FINDING, asserted: organic low-bounty load cannot open the emaFast/emaSlow gap enough to
        // depress the network — the ratio stays healthy throughout (A-11/§2.6). Depression remains
        // reachable ONLY via manipulation (the sibling test), which is the state the floor defends.
        assertFalse(crossed, "organic low-bounty decline must NOT reach depression (credBounty pinning, A-11/2.6)");
        assertGe(_fastRatioBps(), issuance.depressionThresholdBps(), "network stays healthy after full organic decline");
        assertGe(minRatioSeen, issuance.depressionThresholdBps(), "ratio never dipped below the depression threshold");
        assertTrue(
            issuance.issuanceNetworkState() != IssuanceModule.IssuanceNetworkState.Depression,
            "network state is not Depression after organic decline"
        );
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

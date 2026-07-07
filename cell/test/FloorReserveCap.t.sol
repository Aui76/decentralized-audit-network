// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

// Teeth for M-4 (G-21) — the depression-floor RESERVE BOUND in IssuanceModule._updateEmaAndPayFloor.
// Proposal: body/proposals/fix-slump-bonus-cap-proposal.txt.
//
// Three guards, each of which FAILS without the reserve clamp (or would break if green-light were retired as a
// side effect):
//   (1) pool ABOVE reserve   → the slump bonus draws the pool only DOWN TO its reserve, never below, then stops
//                              bleeding (converges instead of asymptoting toward zero).
//   (2) pool AT/BELOW reserve → the bonus draws NOTHING from the pool (poolDraw == 0; no DepressionFloorPaid).
//   (3) green-light PRESERVED → below reserve WITH a recovering signal, the green-light-mint gate is still
//                              enabled (the clamp keeps `supplement` intact, so the mint path is not killed).
//
// The floor path re-blends the EMAs inside the confirm, so exact arithmetic is avoided; the assertions use the
// live views (escrowMinimumThreshold() = reserve, greenLightMintAllowed()) which read the SAME post-blend emaSlow
// the clamp used — so `escrowBalance() >= escrowMinimumThreshold()` is an EXACT consequence of the clamp.

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/IssuanceModule.sol";
import "./helpers/CellTestDeploy.sol";

contract FloorReserveTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

contract FloorReserveCap is Test {
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

    bytes32 constant DEPRESSION_FLOOR_TOPIC = keccak256("DepressionFloorPaid(address,uint256,uint256)");

    uint256 constant ESCROW_SEED = 1_000_000 ether;
    uint256 constant TINY = 0.001 ether; // keep credBounty/slowSignal negligible so a re-pin barely blends
    uint256 saltNonce = 1;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        escrow = d.escrow;
        issuance = d.issuance;

        token.genesisMint(protocol, 100_000 ether);
        token.genesisMint(address(this), ESCROW_SEED + 1_000_000 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        _fundEscrow(ESCROW_SEED);

        vm.prank(auditor);
        cell.register();

        _confirm(1 ether); // warm: bring emaSlow/emaFast > 0 so the pins have a live signal to override
    }

    // (1) Pool ABOVE reserve: the bonus draws only DOWN TO the reserve, never below, and stops there.
    // Teeth: without the clamp the pool bleeds 30 bps/confirm straight through the reserve → the invariant fails.
    function test_floor_draws_only_down_to_reserve_then_stops() public {
        // ISOLATE the floor from the block-reward refill: with emaSlow pinned high the per-block mint's 24.9%
        // treasury split would flow back into escrow faster than the 30-bps floor drains it, masking convergence.
        // Zero the mint for this test so the pool moves ONLY via the floor draw — the reserve bound is independent
        // of the mint, and this makes the "never below reserve" invariant genuine teeth (without the clamp the
        // pool would now actually drain past its reserve).
        issuance.setEmaToMintBps(0);

        uint256 pool = escrow.escrowBalance();
        // Pick emaSlow so reserve = emaSlow * (escrowMinimumThresholdBps/10000) ~= 0.99 * pool → the RESERVE (not
        // the 30-bps drawdown cap) is what binds as the pool is drawn down toward it.
        uint256 targetSlow = (pool * 9900) / 36000;

        bool everStopped;
        for (uint256 i = 0; i < 40; i++) {
            _pin(targetSlow, targetSlow / 100); // deep depression: fast/slow ~ 100 bps
            uint256 floorPaid = _confirmFloor(TINY);
            // INVARIANT (exact consequence of the clamp): the pool is never left below its live reserve.
            assertGe(
                escrow.escrowBalance(),
                issuance.escrowMinimumThreshold(),
                "M-4: pool drawn below its protective reserve"
            );
            if (floorPaid == 0) {
                everStopped = true;
                break;
            }
        }
        assertTrue(everStopped, "M-4: floor converges to the reserve and STOPS (does not bleed toward zero)");
    }

    // (2) Pool AT/BELOW reserve: the bonus draws nothing from the pool.
    // Teeth: without the clamp the bonus pays min(rawSupplement, 30-bps cap) > 0 and the pool shrinks.
    function test_floor_suppressed_when_pool_below_reserve() public {
        uint256 pool = escrow.escrowBalance();
        // Pin emaSlow so reserve ~= 100x the pool → drawable == 0.
        uint256 slowAbovePool = (pool * 1_000_000) / 36000;
        _pin(slowAbovePool, slowAbovePool / 100); // deep depression, reserve far above the pool

        assertGt(issuance.escrowMinimumThreshold(), pool, "precondition: reserve above the pool");
        uint256 escrowBefore = escrow.escrowBalance();

        uint256 floorPaid = _confirmFloor(TINY);

        assertEq(floorPaid, 0, "M-4: no floor drawn while the pool sits below its reserve");
        assertGe(escrow.escrowBalance(), escrowBefore, "M-4: the floor took nothing from the pool");
    }

    // (3) Green-light mint PRESERVED. Below reserve WITH a recovering signal (emaFast rising, ratio in
    // [recoverabilityFactorBps, depressionThresholdBps)), the green-light gate must still be enabled — the clamp
    // leaves `supplement` intact, so the shortfall path (a MINT, which never touches the pool) is not retired.
    // Teeth: flips false if green-light is ever silently disabled by the floor change.
    function test_green_light_mint_gate_preserved_below_reserve() public {
        // emaSlow pinned so reserve (= emaSlow × 3.6) sits ABOVE the seeded pool (~1,000,000 ether). Recovering:
        // emaFast > lastEmaFast, ratio = 6000 bps in [recoverabilityFactorBps 4500, depressionThresholdBps 7000).
        uint256 slow = 1_000_000 ether;
        uint256 fastPrev = 500_000 ether; // lastEmaFast
        uint256 fastNow = 600_000 ether; // emaFast > lastEmaFast (recovering); ratio = 6000 bps
        stdstore.target(address(issuance)).sig("emaSlow()").checked_write(slow);
        stdstore.target(address(issuance)).sig("emaFast()").checked_write(fastNow);
        stdstore.target(address(issuance)).sig("lastEmaFast()").checked_write(fastPrev);

        assertLt(escrow.escrowBalance(), issuance.escrowMinimumThreshold(), "precondition: pool below reserve");
        assertTrue(issuance.greenLightMintEnabled(), "green-light not retired");
        assertGt(issuance.floorDecayBps(), 0, "green-light precondition: floor decay positive");
        assertTrue(
            issuance.greenLightMintAllowed(),
            "M-4: green-light gate still enabled below reserve when the signal is recovering"
        );
    }

    // --- helpers ------------------------------------------------------------------------------------------

    function _pin(uint256 slow, uint256 fast) internal {
        stdstore.target(address(issuance)).sig("emaSlow()").checked_write(slow);
        stdstore.target(address(issuance)).sig("emaFast()").checked_write(fast);
        stdstore.target(address(issuance)).sig("lastEmaFast()").checked_write(fast);
    }

    function _confirmFloor(uint256 bounty) internal returns (uint256 paid) {
        vm.recordLogs();
        _confirm(bounty);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == DEPRESSION_FLOOR_TOPIC) {
                paid = abi.decode(logs[i].data, (uint256));
                return paid;
            }
        }
    }

    function _confirm(uint256 bounty) internal {
        FloorReserveTarget target = new FloorReserveTarget(saltNonce++);
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
        cell.confirmAudit(id);
    }

    function _fundEscrow(uint256 amount) internal {
        token.transfer(address(escrow), amount);
        vm.prank(address(cell.issuanceModule()));
        escrow.recordDeposit(amount);
    }
}

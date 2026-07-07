// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";

import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/IssuanceModule.sol";
import "./helpers/IssuanceCellStub.sol";

/// @dev Minimal network bind for the raise-only arming test (setNetwork requires the mutual binding view).
contract VestingNetworkStub {
    address public treasuryEscrow;

    constructor(address e) {
        treasuryEscrow = e;
    }
}

/// @notice G-24 + G-27(founder) oracle — founder vesting is enforcement, not presentation.
///         Prong 1: vesting pace follows distinct (auditor, protocol) pairs — wash repetition doesn't move it.
///         Prong 2: the two founder levers are monotonic after their lock moments — the founder can tighten
///         his own vesting, never loosen it.
///         Proposal: body/proposals/founder-vesting-enforcement-proposal.txt (manifest row 7).
contract FounderVestingEnforceTest is Test {
    CellToken internal token;
    CellEscrow internal escrow;
    IssuanceModule internal issuance;
    IssuanceCellStub internal cellStub;

    address internal founder = address(0xF00002);

    function setUp() external {
        token = new CellToken();
        token.genesisMint(address(this), 20_000_000 ether);
        escrow = new CellEscrow(address(token));
        issuance = new IssuanceModule(address(this));
        cellStub = new IssuanceCellStub(issuance);
        issuance.wire(address(cellStub), address(token), address(escrow));
        escrow.setIssuanceModule(address(issuance));
        escrow.setFounder(founder);
        escrow.setFounderReleaseTarget(10); // network never set here -> free calibration
        token.setMinter(address(issuance));
    }

    /// t1 — a wash ring repeating the SAME (auditor, protocol) pair advances vesting once (the first pair),
    ///      then never again. Under the old raw counter, three settles = three ticks toward release.
    function test_wash_ring_does_not_accelerate_vesting() external {
        cellStub.settlePositiveBlock(1, address(0xA1), address(0xB1), 50 ether);
        assertEq(issuance.totalDistinctAuditPairs(), 1, "first settle records the pair");

        cellStub.settlePositiveBlock(2, address(0xA1), address(0xB1), 50 ether);
        cellStub.settlePositiveBlock(3, address(0xA1), address(0xB1), 50 ether);
        assertEq(issuance.totalDistinctAuditPairs(), 1, "wash repetition adds nothing");

        uint256 bal = escrow.founderBalance();
        assertGt(bal, 0, "founder slice accrued from settles");
        // release fraction = 1 pair / target 10
        assertEq(escrow.founderClaimable(), (bal * 1_000) / 10_000, "pace frozen at 1/10 despite 3 settles");
    }

    /// t2 — distinct pairs advance vesting proportionally: k pairs -> k/target of the accrued balance.
    function test_distinct_pairs_advance_vesting() external {
        cellStub.settlePositiveBlock(1, address(0xA1), address(0xB1), 50 ether);
        cellStub.settlePositiveBlock(2, address(0xA2), address(0xB2), 50 ether);
        cellStub.settlePositiveBlock(3, address(0xA3), address(0xB3), 50 ether);
        assertEq(issuance.totalDistinctAuditPairs(), 3);

        uint256 bal = escrow.founderBalance();
        assertGt(bal, 0);
        assertEq(escrow.founderClaimable(), (bal * 3_000) / 10_000, "3 pairs / target 10 = 30% released");

        // the claim actually pays and stays within the released fraction
        vm.prank(founder);
        uint256 claimed = escrow.claimFounder();
        assertEq(claimed, (bal * 3_000) / 10_000);
    }

    /// t3 — releaseTarget: free before setNetwork (calibration), RAISE-ONLY after (no tx loosens vesting).
    function test_release_target_raise_only_after_network() external {
        CellEscrow e2 = new CellEscrow(address(token));
        e2.setFounderReleaseTarget(5);
        e2.setFounderReleaseTarget(3); // lowering is fine pre-network: deploy-time calibration

        VestingNetworkStub net = new VestingNetworkStub(address(e2));
        e2.setNetwork(address(net));

        vm.expectRevert("Vesting: raise-only");
        e2.setFounderReleaseTarget(2);

        e2.setFounderReleaseTarget(3); // equal is allowed
        e2.setFounderReleaseTarget(10); // raising (tightening) is allowed
        assertEq(e2.founderReleaseTarget(), 10);
    }

    /// t4 — founderShareBps: free before lockWiring, LOWER-ONLY after (share can shrink, never grow).
    function test_founder_share_lower_only_after_lock() external {
        assertEq(issuance.founderShareBps(), 305);
        issuance.setFounderShareBps(400); // raising is fine pre-lock: calibration

        issuance.lockWiring();

        vm.expectRevert("Founder share: lower-only");
        issuance.setFounderShareBps(500);

        issuance.setFounderShareBps(400); // equal is allowed
        issuance.setFounderShareBps(305); // lowering (tightening) is allowed
        assertEq(issuance.founderShareBps(), 305);
    }
}

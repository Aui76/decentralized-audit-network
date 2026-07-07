// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";

import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/IssuanceModule.sol";
import "../contracts/AuditCell.sol";
import "./helpers/CellTestDeploy.sol";

/// @dev Minimal network bind for founder-bucket unit tests.
contract FounderNetworkStub {
    uint256 public totalSuccessfulAudits;
    address public treasuryEscrow;

    constructor(address escrow) {
        treasuryEscrow = escrow;
    }

    function setTotalSuccessfulAudits(uint256 n) external {
        totalSuccessfulAudits = n;
    }
}

/// @dev G-24: escrow vesting now reads totalDistinctAuditPairs from the issuance module — stub it directly.
contract IssuanceDistinctStub {
    uint256 public totalDistinctAuditPairs;

    function setPairs(uint256 n) external {
        totalDistinctAuditPairs = n;
    }
}

/// @notice R6 oracle — founder cap, deposit, activity-gated claim (cathedral: TreasuryEscrow.t.sol).
contract FounderShareCellTest is Test {
    using stdStorage for StdStorage;

    CellToken internal token;
    CellEscrow internal escrow;
    IssuanceDistinctStub internal issuance;
    FounderNetworkStub internal networkStub;

    address internal founder = address(0xF00000);

    function setUp() external {
        token = new CellToken();
        escrow = new CellEscrow(address(token));
        issuance = new IssuanceDistinctStub();
        networkStub = new FounderNetworkStub(address(escrow));

        // G-27: release-target calibration must happen BEFORE setNetwork (raise-only afterwards).
        escrow.setFounderReleaseTarget(10);
        escrow.setNetwork(address(networkStub));
        escrow.setIssuanceModule(address(issuance));
        escrow.setFounder(founder);

        token.genesisMint(address(this), 20_000_000 ether);
    }

    function test_founderCapRemaining_and_recordFounderDeposit() external {
        uint256 cap = escrow.FOUNDER_CAP_ABS();
        assertEq(escrow.founderCapRemaining(), cap);

        _fundEscrow(cap + 1000 ether);
        vm.prank(address(issuance));
        escrow.recordFounderDeposit(cap + 1000 ether);

        assertEq(escrow.founderTotalMinted(), cap);
        assertEq(escrow.founderBalance(), cap);
        assertEq(escrow.founderCapRemaining(), 0);
    }

    function test_recordFounderDeposit_reverts_without_tokens() external {
        vm.prank(address(issuance));
        vm.expectRevert("Tokens not received");
        escrow.recordFounderDeposit(100 ether);
    }

    function test_claimFounder_activity_gated() external {
        uint256 deposit = 10_000 ether;
        _fundEscrow(deposit);
        vm.prank(address(issuance));
        escrow.recordFounderDeposit(deposit);

        vm.prank(founder);
        vm.expectRevert("Nothing claimable");
        escrow.claimFounder();

        issuance.setPairs(5);
        vm.prank(founder);
        uint256 claimed = escrow.claimFounder();
        assertEq(claimed, (deposit * 5000) / 10_000);

        issuance.setPairs(10);
        vm.prank(founder);
        uint256 rest = escrow.claimFounder();
        assertEq(rest, deposit - claimed);
    }

    function test_settlePositiveBlock_mints_founder_slice_to_bucket() external {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deployWithoutAssignment(address(this));
        d.escrow.setFounder(founder);
        CellTestDeploy.attachMinter(d);

        _setIssuanceEma(d.issuance, 5000 ether, 5000 ether);

        uint256 capBefore = d.escrow.founderCapRemaining();
        uint256 reward = d.issuance.nextPositiveBlockReward();
        assertGt(reward, 0);

        vm.prank(address(d.cell));
        (uint256 auditorMinted,,) = d.issuance.settlePositiveBlock(1, address(0xA), address(0xB), 50 ether);

        // A-1 (G-17): the founder slice derives from the GATED auditor mint — here 0xA is unproven (weight
        // ×0.25) and the 50-bounty cap binds (25% → 12.5) — not the ungated `reward`. Tie expected to the mint.
        uint256 expected = (auditorMinted * d.issuance.founderShareBps()) / 10_000;
        assertEq(d.escrow.founderTotalMinted(), expected);
        assertEq(d.escrow.founderBalance(), expected);
        assertEq(d.escrow.founderCapRemaining(), capBefore - expected);
        assertEq(d.issuance.founderShareBps(), 305);
    }

    function _setIssuanceEma(IssuanceModule mod, uint256 slow, uint256 fast) internal {
        stdstore.target(address(mod)).sig("emaSlow()").checked_write(slow);
      
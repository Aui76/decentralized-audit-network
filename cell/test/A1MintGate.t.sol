// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

// Oracle for A-1 [G-17] — self-audit mint gate (payout weight + per-block bounty cap + §2 re-key).
// Proposal: body/proposals/a1-mint-weight-and-bounty-cap-proposal.txt.
// Assertions read the reward BASIS via nextPositiveBlockReward() just before each confirm (emaSlow is unchanged
// by that view), so `minted` can be checked EXACTLY against basis×weight / the bounty cap — no magic numbers.
//
// Honest framing (register): this fix ANCHORS the self-audit mint to capital-at-risk; it does NOT zero it. A
// graduated, capitalized ring (bounty >= emaSlow) mints the full reward at capBps return-on-capital per cycle
// (positive-EV residual — see test_graduated_capitalized_ring_residual, emitted for the record).

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellToken.sol";
import "../contracts/CellEscrow.sol";
import "../contracts/IssuanceModule.sol";
import "./helpers/CellTestDeploy.sol";

contract A1Target {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

contract A1MintGate is Test {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    IssuanceModule issuance;

    address auditor = address(0xB0B);
    address[6] protocols = [
        address(0xC01), address(0xC02), address(0xC03), address(0xC04), address(0xC05), address(0xC06)
    ];

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");
    uint256 saltNonce = 1;

    uint256 constant BIG = 1_000 ether;   // large bounty → cap slack, isolates the weight prong
    uint256 constant SMALL = 1 ether;     // small bounty → cap binds, isolates the cap prong

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deployWithoutAssignment(address(this));
        token = d.token; cell = d.cell; escrow = d.escrow; issuance = d.issuance;
        for (uint256 i = 0; i < protocols.length; i++) token.genesisMint(protocols[i], 5_000_000 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        vm.prank(auditor);
        cell.register();
    }

    /// @dev Full lifecycle confirm; returns (minted, rewardBasis-just-before-confirm).
    function _confirm(address protocol, uint256 bounty) internal returns (uint256 minted, uint256 basis) {
        A1Target t = new A1Target(saltNonce++);
        vm.startPrank(protocol);
        token.approve(address(cell), bounty);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        uint256 id = cell.submitAudit(
            address(t), address(t).codehash, specHash, specToolId, specErrors, bounty, declared, 0, 0
        );
        vm.stopPrank();
        vm.prank(protocol); cell.protocolAcceptAuditor(id);
        vm.prank(auditor); cell.acceptAudit(id, specErrors);
        vm.prank(auditor); cell.provePass(id, verdictToolId, resultRoot);
        basis = issuance.nextPositiveBlockReward(); // reward basis (emaSlow unchanged by this view)
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);
        minted = cell.auditBlockRewardMinted(id);
    }

    // Prong 1 — an UNPROVEN auditor (< credibilityCountThreshold distinct protocols) mints at unproven weight.
    // (Confirm #1 warms emaSlow>0; confirm #2 is the assertion — auditor distinct is still 1 < 3.)
    function test_unproven_auditor_mints_at_unproven_weight() public {
        _confirm(protocols[0], BIG); // warm: emaSlow 0→>0; auditor distinct 0→1
        (uint256 minted, uint256 basis) = _confirm(protocols[0], BIG); // distinct still 1 < threshold
        assertGt(basis, 0, "emaSlow warmed");
        assertLt(issuance.auditorDistinctProtocols(auditor), issuance.credibilityCountThreshold());
        assertEq(minted, (basis * issuance.mintUnprovenWeightBps()) / 10_000, "unproven weight applied to mint");
    }

    // Prong 1 (graduated) + the HONEST residual: after 3 distinct protocols, a big-bounty (cap-slack) self-style
    // block mints the FULL reward — the fix anchors, it does not kill. Emit the number for the register.
    function test_graduated_capitalized_ring_residual() public {
        _confirm(protocols[0], BIG); // distinct 0→1
        _confirm(protocols[1], BIG); // 1→2
        _confirm(protocols[2], BIG); // 2→3  (graduated after this)
        assertGe(issuance.auditorDistinctProtocols(auditor), issuance.credibilityCountThreshold());
        (uint256 minted, uint256 basis) = _confirm(protocols[3], BIG); // full weight, cap slack (BIG >= emaSlow)
        assertEq(minted, basis, "graduated + capitalized -> FULL mint (positive-EV residual; not killed)");
        emit log_named_uint("A-1 residual: graduated capitalized full mint per block (wei)", minted);
        emit log_named_uint("A-1 return-on-capital anchor: mintBountyCapBps (per 14-day cycle)", issuance.mintBountyCapBps());
    }

    // Prong 2 — the per-block cap binds on a small bounty even for a graduated auditor: mint == capBps of bounty.
    function test_per_block_bounty_cap_binds() public {
        _confirm(protocols[0], BIG);
        _confirm(protocols[1], BIG);
        _confirm(protocols[2], BIG); // graduate
        (uint256 minted, uint256 basis) = _confirm(protocols[3], SMALL);
        uint256 cap = (SMALL * issuance.mintBountyCapBps()) / 10_000;
        assertEq(minted, cap, "small-bounty mint capped at capBps of the bounty");
        assertLt(minted, basis, "cap bound below the full reward");
    }

    // Prong 3 — re-key: five successful self-audits on ONE protocol do NOT buy full weight (old bug); the mint
    // stays unproven-weighted because distinct-protocol count is still 1.
    function test_rekey_successful_count_does_not_grant_full_weight() public {
        for (uint256 i = 0; i < 5; i++) _confirm(protocols[0], BIG); // 5 successes, ONE distinct protocol
        assertEq(issuance.auditorDistinctProtocols(auditor), 1, "five self-audits = one distinct protocol");
        (uint256 successful,,,,,) = cell.auditors(auditor);
        assertGe(successful, 5, "raw successful >= 5 (would have bought full weight pre-fix)");
        (uint256 minted, uint256 basis) = _confirm(protocols[0], BIG);
        assertEq(minted, (basis * issuance.mintUnprovenWeightBps()) / 10_000, "still unproven despite 5 successes");
    }

    // Genesis / bootstrap sanity: the first-ever block still mints something (nonzero) despite unproven weight.
    // (Detailed genesis figure lives in GenesisFirstAudit.t.sol; this just guards nonzero.)
    function test_first_block_still_mints_nonzero() public {
        (uint256 minted,) = _confirm(protocols[0], BIG);
        assertGt(minted, 0, "first block (emaSlow==0 preview) still mints > 0");
    }
}

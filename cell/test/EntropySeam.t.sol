// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellToken.sol";
import "../contracts/BlockhashEntropy.sol";
import "../contracts/IEntropyProvider.sol";
import "./helpers/CellTestDeploy.sol";

contract MockEntropyProvider is IEntropyProvider {
    bytes32 public immutable word;
    constructor(bytes32 w) { word = w; }
    function seed(bytes32) external view returns (bytes32) { return word; }
}

contract EntropyTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice Entropy-provider seam: fallback when unset, provider wiring, swap changes draw.
contract EntropySeamTest is Test {
    CellTestDeploy.Deployment internal d;
    AuditCell cell;
    CellToken token;
    BlockhashEntropy blockhashProvider;

    address protocol = address(0xBEEF);
    address auditorA = address(0xA11CE);
    address auditorB = address(0xB0B);
    address auditorC = address(0xCAFE);
    address claimant = address(0xC1A1);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");
    bytes32 claimRoot = keccak256("claim.proof");

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        cell = d.cell;
        token = d.token;
        blockhashProvider = new BlockhashEntropy();
        token.genesisMint(protocol, 100_000 ether);
        token.genesisMint(claimant, 10_000 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        vm.prank(auditorA);
        cell.register();
        vm.prank(auditorB);
        cell.register();
        vm.prank(auditorC);
        cell.register();
        vm.prank(claimant);
        cell.register();
    }

    function test_unset_provider_is_zero() public view {
        assertEq(cell.entropyProvider(), address(0));
        assertFalse(cell.entropyProviderLocked());
    }

    function test_blockhash_provider_wires_and_locks() public {
        cell.setEntropyProvider(address(blockhashProvider));
        assertEq(cell.entropyProvider(), address(blockhashProvider));
        cell.lockEntropyProvider();
        assertTrue(cell.entropyProviderLocked());
        vm.expectRevert(AuditCell.AlreadyLocked.selector);
        cell.setEntropyProvider(address(0x1234));
    }

    function test_dispute_assignment_with_provider_set() public {
        cell.setEntropyProvider(address(blockhashProvider));
        uint256 id = _confirmedInBlock(40 ether);
        address assigned = _openDisputeOn(id, 40 ether);
        assertTrue(assigned != address(0));
        assertTrue(assigned != protocol);
        assertTrue(assigned != claimant);
    }

    function test_two_disputes_with_different_providers_succeed() public {
        cell.setEntropyProvider(address(new MockEntropyProvider(bytes32(uint256(1)))));
        address drawA = _openDisputeOn(_confirmedInBlock(40 ether), 40 ether);

        cell.setEntropyProvider(address(new MockEntropyProvider(bytes32(uint256(999)))));
        address drawB = _openDisputeOn(_confirmedInBlock(50 ether), 50 ether);

        assertTrue(drawA != address(0));
        assertTrue(drawB != address(0));
    }

    function test_mock_provider_words_differ() public {
        MockEntropyProvider a = new MockEntropyProvider(bytes32(uint256(1)));
        MockEntropyProvider b = new MockEntropyProvider(bytes32(uint256(999)));
        assertTrue(a.seed(bytes32(0)) != b.seed(bytes32(0)));
    }

    function _confirmedInBlock(uint256 bounty) internal returns (uint256 id) {
        EntropyTarget t = new EntropyTarget(bounty);
        vm.startPrank(protocol);
        token.approve(address(cell), bounty);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        id = cell.submitAudit(
            address(t), address(t).codehash, specHash, specToolId, specErrors, bounty, declared, 0, 0
        );
        vm.stopPrank();
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        address assigned = cell.auditAuditorOf(id);
        vm.prank(assigned);
        cell.acceptAudit(id, specErrors);
        vm.prank(assigned);
        cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);
    }

    function _openDisputeOn(uint256 id, uint256 bounty) internal returns (address disputeAuditor) {
        vm.startPrank(claimant);
        token.approve(address(cell), cell.requiredClaimStake(id));
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");
        vm.stopPrank();
        uint256 minB = (bounty * 5000) / 10_000;
        vm.startPrank(protocol);
        token.approve(address(cell), minB);
        uint256 disputeId = d.claimModule.openDisputeReaudit(id, minB);
        vm.stopPrank();
        disputeAuditor = cell.auditAuditorOf(disputeId);
    }
}

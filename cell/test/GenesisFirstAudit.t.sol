// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./helpers/SpecValidationCellSetup.sol";
import "../contracts/CellEscrow.sol";

contract GenesisFirstAuditTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice E2E: declared-unfunded B_g genesis → first mint ≈312.5, LP seeded, no premine.
contract GenesisFirstAuditTest is SpecValidationCellSetup {
    uint256 internal constant GENESIS_B_G = 5000 ether;

    CellTestDeploy.Deployment internal d;
    AuditCell cell;
    CellToken token;
    CellEscrow escrow;

    address genesisProtocol = address(0xBEEF);
    address genesisAuditor = address(0xA11CE);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 resultRoot = keccak256("result.v1");

    GenesisFirstAuditTarget target;

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        cell = d.cell;
        token = d.token;
        escrow = d.escrow;
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);

        target = new GenesisFirstAuditTarget(1);
        assertTrue(cell.genesisPending());
        assertEq(token.totalSupply(), 0);

        vm.prank(genesisAuditor);
        cell.register();
    }

    function test_genesis_first_audit_unfunded_mint_and_lp_seed() public {
        vm.startPrank(genesisProtocol);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        uint256 id = cell.submitGenesisAudit(
            address(target),
            address(target).codehash,
            specHash,
            specToolId,
            EMPTY_SPEC_ERRORS,
            GENESIS_B_G,
            declared,
            0,
            0
        );
        vm.stopPrank();

        assertEq(id, 0);
        assertTrue(cell.genesisAuditOpen());
        assertEq(cell.genesisAuditId(), id);
        assertEq(token.balanceOf(address(cell)), 0, "no escrowed bounty");

        CellTestDeploy.attachMinter(d);

        vm.prank(genesisProtocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(genesisAuditor);
        cell.acceptAudit(id, EMPTY_SPEC_ERRORS);
        vm.prank(genesisAuditor);
        cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);

        uint256 supplyBefore = token.totalSupply();
        cell.confirmAudit(id);

        uint256 slowSignal = (GENESIS_B_G * d.issuance.emaSlowUnprovenWeightBps()) / 10_000;
        uint256 expectedMint = (slowSignal * d.issuance.emaToMintBps()) / 10_000;
        // A-1 (G-17): the genesis auditor is unproven (0 distinct protocols) → the mint is weighted ×0.25. The
        // per-block bounty cap (25% of B_g=5000 = 1250) is slack against 78.125, so only the weight applies.
        expectedMint = (expectedMint * d.issuance.mintUnprovenWeightBps()) / 10_000;

        assertFalse(cell.genesisPending());
        assertFalse(cell.genesisAuditOpen());
        assertGt(token.totalSupply(), supplyBefore);
        assertEq(cell.auditBlockRewardMinted(id), expectedMint);
        assertEq(expectedMint, 78 ether + 0.125 ether, "B_g=5000 genesis mint x0.25 weight = 78.125");
        assertGt(escrow.lpBalance(), 0, "treasury split seeds LP");
    }

    function test_submitGenesisAudit_reverts_when_not_pending() public {
        _runGenesisOnce();

        GenesisFirstAuditTarget t2 = new GenesisFirstAuditTarget(2);
        vm.startPrank(genesisProtocol);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.expectRevert(AuditCell.GenesisNotPending.selector);
        cell.submitGenesisAudit(
            address(t2),
            address(t2).codehash,
            specHash,
            specToolId,
            EMPTY_SPEC_ERRORS,
            GENESIS_B_G,
            declared,
            0,
            0
        );
        vm.stopPrank();
    }

    function test_submitAudit_zero_bounty_reverts() public {
        vm.startPrank(genesisProtocol);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.expectRevert(AuditCell.BountyRequired.selector);
        cell.submitAudit(
            address(target),
            address(target).codehash,
            specHash,
            specToolId,
            EMPTY_SPEC_ERRORS,
            0,
            declared,
            0,
            0
        );
        vm.stopPrank();
    }

    function _runGenesisOnce() internal {
        vm.startPrank(genesisProtocol);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        uint256 id = cell.submitGenesisAudit(
            address(target),
            address(target).codehash,
            specHash,
            specToolId,
            EMPTY_SPEC_ERRORS,
            GENESIS_B_G,
            declared,
            0,
            0
        );
        vm.stopPrank();
        CellTestDeploy.attachMinter(d);
        vm.prank(genesisProtocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(genesisAuditor);
        cell.acceptAudit(id, EMPTY_SPEC_ERRORS);
        vm.prank(genesisAuditor);
        cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);
    }
}

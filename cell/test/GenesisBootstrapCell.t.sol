// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./helpers/SpecValidationCellSetup.sol";
import "../contracts/SpecArbiterModule.sol";

contract GenesisTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @notice G7 oracle — one-shot genesis bounty + mainnet increment hold.
contract GenesisBootstrapCellTest is SpecValidationCellSetup {
    CellTestDeploy.Deployment internal d;
    AuditCell cell;
    CellToken token;
    SpecArbiterModule specArbiter;

    address genesisProtocol = address(0xBEEF);
    address genesisAuditor = address(0xA11CE);
    address secondAuditor = address(0xB0B);
    address claimant = address(0xC1A1);
    address challenger = address(0xCAFE);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 failErrorsRoot = keccak256("spec.fail");
    bytes32 resultRoot = keccak256("result.v1");
    bytes32 failResultRoot = keccak256("result.fail");
    uint256 challengeFee = 100 ether;

    GenesisTarget target;

    function setUp() public {
        d = CellTestDeploy.deploy(address(this));
        cell = d.cell;
        token = d.token;
        specArbiter = d.specArbiterModule;
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        specArbiter.setSpecChallengeFee(challengeFee);
        specArbiter.setSpecChallengeStake(500 ether);
        token.genesisMint(challenger, 10_000 ether);

        target = new GenesisTarget(1);

        assertTrue(cell.genesisPending());

        vm.prank(genesisAuditor);
        cell.register();
    }

    function _attachIssuance() internal {
        CellTestDeploy.attachMinter(d);
    }

    uint256 internal constant GENESIS_B_G = 5000 ether;

    function _submitGenesis(address deployed, bytes32 codehash) internal returns (uint256 id) {
        vm.startPrank(genesisProtocol);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        id = cell.submitGenesisAudit(
            deployed, codehash, specHash, specToolId, EMPTY_SPEC_ERRORS, GENESIS_B_G, declared, 0, 0
        );
        vm.stopPrank();
    }

    function _submitGenesis() internal returns (uint256 id) {
        return _submitGenesis(address(target), address(target).codehash);
    }

    function _confirmGenesis(uint256 id) internal {
        _attachIssuance();
        vm.prank(genesisProtocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(genesisAuditor);
        cell.acceptAudit(id, EMPTY_SPEC_ERRORS);
        vm.prank(genesisAuditor);
        cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);
    }

    function _submitPaid(address deployed, bytes32 codehash, uint256 bounty) internal returns (uint256 id) {
        vm.startPrank(genesisProtocol);
        token.approve(address(cell), bounty);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        id = cell.submitAudit(
            deployed, codehash, specHash, specToolId, EMPTY_SPEC_ERRORS, bounty, declared, 0, 0
        );
        vm.stopPrank();
    }

    function _confirmPaid(uint256 id) internal {
        _attachIssuance();
        vm.prank(genesisProtocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(genesisAuditor);
        cell.acceptAudit(id, EMPTY_SPEC_ERRORS);
        vm.prank(genesisAuditor);
        cell.provePass(id, verdictToolId, resultRoot);
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);
    }

    function test_paid_id_zero_confirm_does_not_clear_genesis_pending() public {
        GenesisTarget paidTarget = new GenesisTarget(42);
        uint256 bounty = 100 ether;
        token.genesisMint(genesisProtocol, bounty);

        uint256 id = _submitPaid(address(paidTarget), address(paidTarget).codehash, bounty);
        assertEq(id, 0);
        assertTrue(cell.genesisPending());
        assertFalse(cell.genesisAuditOpen());

        _confirmPaid(id);

        assertTrue(cell.genesisPending(), "paid id 0 must not consume genesis exception");
        assertFalse(cell.genesisAuditOpen());
        assertEq(cell.totalSuccessfulAudits(), 1);

        GenesisTarget genesisTarget = new GenesisTarget(99);
        uint256 genesisId = _submitGenesis(address(genesisTarget), address(genesisTarget).codehash);
        assertTrue(cell.genesisAuditOpen());
        assertEq(cell.genesisAuditId(), genesisId);
        _confirmGenesis(genesisId);
        assertFalse(cell.genesisPending());
        assertFalse(cell.genesisAuditOpen());
        assertEq(cell.totalSuccessfulAudits(), 2);
    }

    function test_genesis_submit_requires_positive_bounty() public {
        GenesisTarget g = new GenesisTarget(7);
        vm.startPrank(genesisProtocol);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.expectRevert(AuditCell.BountyRequired.selector);
        cell.submitGenesisAudit(
            address(g),
            address(g).codehash,
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

    function test_genesis_submit_at_genesis() public {
        uint256 id = _submitGenesis();
        assertEq(id, 0);
        assertEq(cell.genesisAuditId(), id);
        assertTrue(cell.genesisPending());
        assertTrue(cell.genesisAuditOpen());
    }

    function test_second_genesis_submit_reverts_while_genesis_open() public {
        _submitGenesis();
        GenesisTarget target2 = new GenesisTarget(2);
        vm.startPrank(genesisProtocol);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.expectRevert(AuditCell.GenesisAuditOpen.selector);
        cell.submitGenesisAudit(
            address(target2),
            address(target2).codehash,
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

    function test_zero_bounty_submitAudit_reverts() public {
        GenesisTarget target2 = new GenesisTarget(2);
        vm.startPrank(genesisProtocol);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.expectRevert(AuditCell.BountyRequired.selector);
        cell.submitAudit(
            address(target2),
            address(target2).codehash,
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

    function test_increment_one_requires_hold_for_auditor_two() public {
        cell.setIncrement(1 ether);
        cell.lockIncrement();

        token.genesisMint(secondAuditor, 1 ether);
        vm.prank(secondAuditor);
        cell.register();
        assertEq(cell.requiredHold(secondAuditor), 1 ether);
    }

    function test_increment_one_blocks_auditor_two_without_hold() public {
        cell.setIncrement(1 ether);
        cell.lockIncrement();

        vm.prank(secondAuditor);
        vm.expectRevert(AuditCell.InsufficientHold.selector);
        cell.register();
    }

    function test_genesis_fail_releases_lock_allows_retry() public {
        uint256 id = _submitGenesis();
        assertTrue(cell.genesisAuditOpen());

        vm.prank(genesisProtocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(genesisAuditor);
        cell.acceptAudit(id, EMPTY_SPEC_ERRORS);
        uint256 stake = cell.requiredClaimStake(id);
        token.genesisMint(genesisAuditor, stake);
        vm.startPrank(genesisAuditor);
        token.approve(address(cell), stake);
        cell.proveFail(id, verdictToolId, failResultRoot);
        vm.stopPrank();

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Claimed));
        assertFalse(cell.genesisAuditOpen());
        assertTrue(cell.genesisPending());
        assertEq(cell.genesisAuditId(), 0);

        GenesisTarget retryTarget = new GenesisTarget(2);
        uint256 retryId = _submitGenesis(address(retryTarget), address(retryTarget).codehash);
        assertTrue(cell.genesisAuditOpen());
        assertEq(cell.genesisAuditId(), retryId);
        _confirmGenesis(retryId);
        assertFalse(cell.genesisPending());
        assertFalse(cell.genesisAuditOpen());
        assertEq(cell.totalSuccessfulAudits(), 1);
    }

    function test_genesis_spec_invalidation_releases_lock_allows_retry() public {
        uint256 id = _submitGenesis();
        _reachAwaitingWindow(cell, id, genesisProtocol, verdictToolId, resultRoot);

        vm.startPrank(challenger);
        token.approve(address(cell), specArbiter.specChallengeStake());
        specArbiter.challengeSpecInvalid(id, failErrorsRoot);
        vm.stopPrank();
        vm.warp(block.timestamp + specArbiter.specChallengeWindow() + 1);
        specArbiter.finalizeSpecChallenge(id);

        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.Invalidated));
        assertFalse(cell.genesisAuditOpen());
        assertTrue(cell.genesisPending());
        assertEq(cell.genesisAuditId(), 0);

        GenesisTarget retryTarget = new GenesisTarget(3);
        uint256 retryId = _submitGenesis(address(retryTarget), address(retryTarget).codehash);
        assertTrue(cell.genesisAuditOpen());
        _confirmGenesis(retryId);
        assertFalse(cell.genesisPending());
        assertEq(cell.totalSuccessfulAudits(), 1);
    }

    function test_fix_audit_still_requires_bounty() public {
        token.genesisMint(claimant, 10_000 ether);
        vm.prank(claimant);
        cell.register();

        uint256 id = _submitGenesis();
        _confirmGenesis(id);

        uint256 stake = cell.requiredClaimStake(id);
        vm.startPrank(claimant);
        token.approve(address(cell), stake);
        cell.claimVulnerability(id, verdictToolId, keccak256("claim"), "");
        vm.stopPrank();

        GenesisTarget fix = new GenesisTarget(99);
        vm.expectRevert(AuditCell.BountyRequired.selector);
        cell.submitFixAudit(
            address(fix),
            specHash,
            specToolId,
            EMPTY_SPEC_ERRORS,
            0,
            id
        );
    }
}

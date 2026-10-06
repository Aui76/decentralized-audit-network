// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../../contracts/AuditCell.sol";
import "../../contracts/CellLogicLib.sol";
import "../../contracts/CellToken.sol";
import "../../contracts/CellEscrow.sol";
import "../../contracts/ClaimDisputeModule.sol";
import "../../contracts/IntegrityReviewModule.sol";
import "../../contracts/CellParamIds.sol";
import "./CellTestDeploy.sol";

contract AskTarget {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

/// @dev DEC-48 fixture: a confirmed original (its bounty already paid to the auditor), a claimant who names a price
///      before filing, and three ways the re-run gets funded. Copied from ClaimantDisputeReauditCell.t.sol; the pool
///      is seeded per test so the bonus can be measured against an empty, a short and a deep pool.
abstract contract ClaimAskFixture is Test {
    CellToken token;
    CellEscrow escrow;
    AuditCell cell;
    ClaimDisputeModule claimModule;
    IntegrityReviewModule integrity;

    address protocol = address(0xA11CE);
    address auditorA = address(0xB0B);
    address claimant = address(0xDEAD);
    address auditorC = address(0xC0DE);
    address funder = address(0xF00D);
    address funder2 = address(0xF00E);
    address opener = address(0x0FE4);
    address reviewer = address(0x4E71);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 integrityToolId = keccak256("integrity.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");
    bytes32 claimRoot = keccak256("claim.proof");
    bytes32 otherRoot = keccak256("neither.side.root");

    uint256 constant ORIG_BOUNTY = 40 ether;
    uint256 constant ASK = 25 ether;
    uint256 constant MIN_B = 20 ether; // DISPUTE_BOUNTY_MIN_BPS: half the original bounty
    uint256 constant POOL_SEED = 10_000 ether;
    uint256 saltNonce = 1;

    // The module's events, re-declared: 0.8.20 has no qualified access to another contract's events.
    event ClaimAskNamed(uint256 indexed originalId, address indexed claimant, uint256 ask);
    event ClaimAskFunded(uint256 indexed originalId, address indexed funder, uint256 ask, uint256 indexed disputeId);
    event ClaimAskPaid(uint256 indexed originalId, address indexed claimant, address indexed funder, uint256 ask);
    event ClaimAskReturned(uint256 indexed originalId, address indexed funder, uint256 ask, uint8 reason);
    event ClaimAskUnfunded(uint256 indexed originalId, address indexed claimant, uint256 ask);
    bytes32 constant SHORTFALL_TOPIC0 = keccak256("DiscovererShortfall(address,uint256,uint256,bool)");

    function setUp() public virtual {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        token = d.token;
        cell = d.cell;
        claimModule = d.claimModule;
        escrow = d.escrow;
        integrity = d.integrityReviewModule;
        token.genesisMint(protocol, 2_000 ether);
        token.genesisMint(claimant, 500 ether);
        token.genesisMint(auditorC, 500 ether);
        token.genesisMint(funder, 2_000 ether);
        token.genesisMint(funder2, 2_000 ether);
        token.genesisMint(opener, 2_000 ether);
        token.genesisMint(address(this), POOL_SEED);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
        cell.registerTool(integrityToolId, false);
        claimModule.setProtocolClaimDecisionWindow(1 days);
        vm.prank(auditorA);
        cell.register();
        vm.prank(claimant);
        cell.register();
        vm.prank(auditorC);
        cell.register();
    }

    // ---- pool -------------------------------------------------------------------------------------------------------

    function _fundEscrow(uint256 amount) internal {
        token.transfer(address(escrow), amount);
        vm.prank(address(cell.issuanceModule()));
        escrow.recordDeposit(amount);
    }

    function _seedPool() internal {
        _fundEscrow(POOL_SEED);
    }

    // ---- rows -------------------------------------------------------------------------------------------------------

    /// @dev Submitted, drawn to auditorA, PASS proved: AwaitingWindow with the bounty still escrowed.
    function _awaitingOriginal() internal returns (uint256 id) {
        AskTarget original = new AskTarget(saltNonce++);
        vm.prank(protocol);
        token.approve(address(cell), ORIG_BOUNTY);
        bytes32[] memory declared = new bytes32[](1);
        declared[0] = verdictToolId;
        vm.prank(protocol);
        id = cell.submitAudit(
            address(original), address(original).codehash, specHash, specToolId, specErrors, ORIG_BOUNTY, declared, 0, 0
        );
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        assertEq(cell.auditAuditorOf(id), auditorA, "fixture: auditorA holds the original");
        vm.prank(auditorA);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditorA);
        cell.provePass(id, verdictToolId, resultRoot);
    }

    /// @dev Confirmed: the bounty left the cell for auditorA, the row sits InBlock.
    function _confirmedOriginal() internal returns (uint256 id) {
        id = _awaitingOriginal();
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(id);
        assertEq(uint256(cell.auditStateOf(id)), uint256(CellTypeDefs.AuditState.InBlock));
        assertFalse(cell.auditBountyEscrowed(id), "fixture: the bounty is gone from the cell");
    }

    function _file(uint256 id, address who) internal {
        uint256 stake = cell.claimFilingStake();
        vm.prank(who);
        token.approve(address(cell), stake);
        vm.prank(who);
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");
    }

    /// @dev A confirmed row with the claimant's price named and bound at filing.
    function _pricedClaim() internal returns (uint256 id) {
        id = _confirmedOriginal();
        vm.prank(claimant);
        claimModule.nameClaimAsk(id, ASK);
        _file(id, claimant);
        (uint256 ask, address f, uint256 funded, uint256 paid) = claimModule.claimAskStatus(id);
        assertEq(ask, ASK, "fixture: the price bound at filing");
        assertEq(f, address(0));
        assertEq(funded, 0);
        assertEq(paid, 0);
    }

    function _stakeOf(uint256 id) internal view returns (uint256 stake) {
        (,,,, stake,,,,,,,,) = cell.vulnerabilityClaims(id);
    }

    // ---- funding lanes ---------------------------------------------------------------------------------------------

    function _protocolFunds(uint256 id) internal returns (uint256 disputeId) {
        vm.startPrank(protocol);
        token.approve(address(cell), MIN_B + ASK);
        disputeId = claimModule.openDisputeReaudit(id, MIN_B);
        vm.stopPrank();
    }

    function _lapseWindow() internal {
        vm.warp(block.timestamp + 1 days + 1);
    }

    function _thirdPartyFunds(uint256 id, address who) internal returns (uint256 disputeId) {
        vm.startPrank(who);
        token.approve(address(cell), MIN_B + ASK);
        disputeId = claimModule.fundClaimAsk(id, MIN_B);
        vm.stopPrank();
    }

    function _claimantLane(uint256 id) internal returns (uint256 disputeId) {
        vm.startPrank(claimant);
        token.approve(address(cell), MIN_B);
        disputeId = claimModule.claimantOpenDisputeReaudit(id, MIN_B);
        vm.stopPrank();
    }

    // ---- verdicts ----------------------------------------------------------------------------------------------------

    function _accept(uint256 disputeId) internal returns (address drawn) {
        drawn = cell.auditAuditorOf(disputeId);
        assertTrue(drawn != auditorA && drawn != claimant, "fixture: the re-run excludes the parties");
        vm.prank(drawn);
        cell.acceptAudit(disputeId, specErrors);
    }

    function _fail(uint256 disputeId, bytes32 root) internal returns (address drawn) {
        drawn = _accept(disputeId);
        vm.prank(drawn);
        cell.proveFail(disputeId, verdictToolId, root);
    }

    function _pass(uint256 disputeId) internal returns (address drawn) {
        drawn = _accept(disputeId);
        vm.prank(drawn);
        cell.provePass(disputeId, verdictToolId, resultRoot);
    }

    function _confirm(uint256 disputeId) internal {
        vm.warp(block.timestamp + cell.minAuditWindow() + 1);
        cell.confirmAudit(disputeId);
    }

    function _assertNoShortfall() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != SHORTFALL_TOPIC0, "no DiscovererShortfall: the bonus is best-effort, never short");
        }
    }

    function _assertNoDebt() internal view {
        assertEq(escrow.discovererDebt(claimant), 0, "DEC-48: nothing is owed to the finder");
        assertEq(escrow.totalDiscovererDebt(), 0, "DEC-48: the pool carries no IOU");
    }
}

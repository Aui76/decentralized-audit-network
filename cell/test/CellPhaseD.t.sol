// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/AuditCell.sol";
import "../contracts/CellLogicLib.sol";
import "../contracts/RunDigests.sol";
import "../contracts/tools/AuditCaseV1.sol";
import "../contracts/ClaimDisputeModule.sol";
import "./helpers/CellTestDeploy.sol";

contract Target {
    uint256 public immutable salt;
    constructor(uint256 s) { salt = s; }
}

contract CellPhaseDTest is Test {
    AuditCell cell;
    ClaimDisputeModule claimModule;
    CellToken token;

    address protocol = address(0xA11CE);
    address auditor = address(0xB0B);
    address adversary = address(0xDEAD);

    bytes32 specToolId = keccak256("spec.tool.v1");
    bytes32 verdictToolId = keccak256("verdict.tool.v1");
    bytes32 specHash = keccak256("spec.v1");
    bytes32 specHash2 = keccak256("spec.v2");
    bytes32 specErrors = keccak256("errors.v1");
    bytes32 resultRoot = keccak256("result.v1");
    bytes32 claimRoot = keccak256("claim.proof");

    uint256 constant BOUNTY = 40 ether;

    function setUp() public {
        CellTestDeploy.Deployment memory d = CellTestDeploy.deploy(address(this));
        cell = d.cell;
        claimModule = d.claimModule;
        token = d.token;
        token.genesisMint(protocol, 2_000 ether);
        token.genesisMint(adversary, 500 ether);
        CellTestDeploy.attachMinter(d);
        CellTestDeploy.registerDefaultTools(d, specToolId, verdictToolId);
    }

    function _declared() internal view returns (bytes32[] memory d) {
        d = new bytes32[](1);
        d[0] = verdictToolId;
    }

    function _submit(address target, bytes32 spec, uint256 supersedes) internal returns (uint256 id) {
        vm.prank(auditor);
        cell.register();
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        vm.prank(protocol);
        id = cell.submitAudit(target, target.codehash, spec, specToolId, specErrors, BOUNTY, _declared(), supersedes, 0);
    }

    function test_sameCaseRoot_reverts_second_submit() public {
        Target t = new Target(1);
        _submit(address(t), specHash, 0);
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        vm.expectRevert(abi.encodeWithSelector(AuditCell.CaseAlreadyAudited.selector, uint256(0)));
        vm.prank(protocol);
        cell.submitAudit(address(t), address(t).codehash, specHash, specToolId, specErrors, BOUNTY, _declared(), 0, 0);
    }

    function test_sameO_newSpec_newCaseRoot_succeeds() public {
        Target t = new Target(2);
        uint256 id0 = _submit(address(t), specHash, 0);
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        vm.prank(protocol);
        uint256 id1 = cell.submitAudit(address(t), address(t).codehash, specHash2, specToolId, specErrors, BOUNTY, _declared(), 0, 0);
        assertTrue(id1 > id0);
        assertTrue(cell.caseRootOf(id1) != cell.caseRootOf(id0));
        assertTrue(cell.caseRootRegistered(cell.caseRootOf(id1)));
    }

    function test_supersedes_sameO_newCaseRoot() public {
        Target t = new Target(3);
        uint256 prior = _submit(address(t), specHash, 0);
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        vm.prank(protocol);
        uint256 next = cell.submitAudit(address(t), address(t).codehash, specHash2, specToolId, specErrors, BOUNTY, _declared(), prior, 0);
        assertEq(cell.auditSupersedesOf(next), prior);
    }

    function test_supersedes_reverts_sameCaseRoot() public {
        Target t = new Target(4);
        uint256 prior = _submit(address(t), specHash, 0);
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        vm.expectRevert(abi.encodeWithSelector(AuditCell.CaseAlreadyAudited.selector, prior));
        vm.prank(protocol);
        cell.submitAudit(address(t), address(t).codehash, specHash, specToolId, specErrors, BOUNTY, _declared(), prior, 0);
    }

    function _claimedOriginal(address target) internal returns (uint256 id) {
        id = _submit(target, specHash, 0);
        vm.prank(protocol);
        cell.protocolAcceptAuditor(id);
        vm.prank(auditor);
        cell.acceptAudit(id, specErrors);
        vm.prank(auditor);
        cell.provePass(id, verdictToolId, resultRoot);

        vm.prank(adversary);
        cell.register();
        uint256 stake = cell.claimFilingStake();
        vm.prank(adversary);
        token.approve(address(cell), stake);
        vm.prank(adversary);
        cell.claimVulnerability(id, verdictToolId, claimRoot, "");
    }

    function test_dispute_shares_caseRoot_no_reregister() public {
        Target t = new Target(5);
        uint256 id = _claimedOriginal(address(t));
        bytes32 root = cell.caseRootOf(id);

        uint256 minB = (BOUNTY * 5000) / 10_000;
        vm.prank(protocol);
        token.approve(address(cell), minB);
        vm.prank(protocol);
        uint256 disputeId = claimModule.openDisputeReaudit(id, minB);

        assertEq(cell.caseRootOf(disputeId), root);
        assertEq(cell.caseRootToAuditId(root), id);
    }

    function test_fix_new_caseRoot() public {
        Target original = new Target(6);
        uint256 id = _claimedOriginal(address(original));

        Target fix = new Target(99);
        vm.prank(protocol);
        token.approve(address(cell), BOUNTY);
        vm.prank(protocol);
        uint256 fixId = cell.submitFixAudit(address(fix), specHash, specToolId, specErrors, BOUNTY, id);
        assertTrue(cell.caseRootOf(fixId) != cell.caseRootOf(id));
    }

    function test_declaredVerdictToolsOf_matches_caseRoot() public {
        Target t = new Target(7);
        uint256 id = _submit(address(t), specHash, 0);

        bytes32[] memory toolArr = new bytes32[](1);
        toolArr[0] = verdictToolId;
        bytes32[] memory sorted = AuditCaseV1.sortToolIds(toolArr);
        bytes32 passDigest = RunDigests.specRunDigest(specHash, specToolId, true, specErrors);
        bytes32 expected = AuditCaseV1.caseRoot(
            address(t).codehash, specHash, specToolId, passDigest, sorted
        );
        assertEq(cell.caseRootOf(id), expected);
    }
}

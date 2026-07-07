// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/tools/TransferCreditsV1.sol";
import "../contracts/tools/WithdrawCreditsV1.sol";
import "../contracts/TutorialDualVault.sol";

interface IDualVault {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function transferCredits(address from, address to, uint256 amount) external;
    function credits(address) external view returns (uint256);
}

contract TransferCreditsV1Test is Test {
    uint256 internal constant SALT = 2_026_062_402;

    function _runTransferFixture(address target) internal returns (bool pass, bytes32 resultRoot) {
        IDualVault v = IDualVault(target);
        address from = TransferCreditsV1.FIXTURE_FROM;
        address actor = TransferCreditsV1.FIXTURE_ACTOR;
        vm.deal(from, 1 ether);
        vm.prank(from);
        v.deposit{value: 1 ether}();
        uint256 pre = v.credits(from);
        vm.prank(actor);
        v.transferCredits(from, TransferCreditsV1.FIXTURE_TO, 1 ether);
        uint256 post = v.credits(from);
        bytes32 root;
        (pass, , , root) = TransferCreditsV1.encodeResult(target, pre, post);
        return (pass, root);
    }

    function _runWithdrawFixture(address target) internal returns (bool pass, bytes32 resultRoot) {
        IDualVault v = IDualVault(target);
        address caller = WithdrawCreditsV1.FIXTURE_CALLER;
        vm.deal(caller, 1 ether);
        vm.prank(caller);
        v.deposit{value: 1 ether}();
        uint256 pre = v.credits(caller);
        vm.prank(caller);
        v.withdraw(1 ether);
        uint256 post = v.credits(caller);
        bytes32 root;
        (pass, , , root) = WithdrawCreditsV1.encodeResult(target, pre, post);
        return (pass, root);
    }

    function test_tool_artifact_hash_matches_zero_slot_build() public pure {
        assertEq(
            TransferCreditsV1.toolArtifactHash(),
            0x390f7f7742a2419d6ddd8f9dc9afffacbdef7e41b861d6c295ec147e3a73fbed
        );
    }

    function test_dual_vault_withdraw_pass_transfer_fail() public {
        TutorialDualVault vault = new TutorialDualVault(SALT);
        (bool wPass,) = _runWithdrawFixture(address(vault));
        (bool tPass,) = _runTransferFixture(address(vault));
        assertTrue(wPass, "withdraw-credits must PASS");
        assertFalse(tPass, "transfer-credits must FAIL");
    }
}

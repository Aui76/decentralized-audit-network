// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/tools/WithdrawCreditsV1.sol";
import "../contracts/Gate0R2Target.sol";
import "../contracts/Gate0R2TargetFix.sol";

interface IGate0Credits {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function credits(address) external view returns (uint256);
}

contract WithdrawCreditsV1Test is Test {
    uint256 internal constant SALT = 991028;

    function _runFixture(address target) internal returns (bool pass, bytes32 resultRoot) {
        IGate0Credits t = IGate0Credits(target);
        address caller = WithdrawCreditsV1.FIXTURE_CALLER;
        vm.deal(caller, 1 ether);
        vm.prank(caller);
        t.deposit{value: 1 ether}();
        uint256 pre = t.credits(caller);
        vm.prank(caller);
        t.withdraw(1 ether);
        uint256 post = t.credits(caller);
        bytes32 root;
        (pass, , , root) = WithdrawCreditsV1.encodeResult(target, pre, post);
        return (pass, root);
    }

    function test_spec_hash_constants() public pure {
        assertEq(WithdrawCreditsV1.specInvariantId(), keccak256("INVARIANT_WITHDRAW_DECREMENTS_CREDITS_V1"));
    }

    function test_tool_artifact_hash_matches_zero_slot_build() public pure {
        assertEq(
            WithdrawCreditsV1.toolArtifactHash(),
            0x630e81f397d999d092e086f66d93af2828eed69363e37dc1cca6395c5670c2c7
        );
    }

    function test_tool_id_v110_differs_from_label_v100() public pure {
        bytes32 labelHash = keccak256("WithdrawCreditsV1Lib@1.0.0");
        bytes32 v100Id = keccak256(
            abi.encode(
                keccak256("AUDIT_TOOL_V1"),
                "withdraw-credits",
                "1.0.0",
                labelHash,
                "encodeResult(address,uint256,uint256)"
            )
        );
        assertTrue(WithdrawCreditsV1.toolId() != v100Id, "content-bound id must differ from label v1.0.0");
        assertTrue(WithdrawCreditsV1.toolArtifactHash() != labelHash, "artifact hash must not be label");
    }

    function test_gate0_r2_target_fail() public {
        Gate0R2Target target = new Gate0R2Target(SALT);
        (bool pass, bytes32 root) = _runFixture(address(target));
        assertFalse(pass);
        assertTrue(root != bytes32(0));
        Gate0R2Target target2 = new Gate0R2Target(SALT);
        (, bytes32 root2) = _runFixture(address(target2));
        assertEq(root, root2);
    }

    function test_gate0_r2_fix_pass() public {
        Gate0R2TargetFix target = new Gate0R2TargetFix(SALT);
        (bool pass, bytes32 root) = _runFixture(address(target));
        assertTrue(pass);
        assertTrue(root != bytes32(0));
    }

    function test_deterministic_across_runs() public {
        Gate0R2Target a = new Gate0R2Target(SALT);
        Gate0R2Target b = new Gate0R2Target(SALT + 1);
        (, bytes32 rootA) = _runFixture(address(a));
        (, bytes32 rootB) = _runFixture(address(b));
        assertTrue(rootA != rootB, "different codehash => different root");
        Gate0R2Target a2 = new Gate0R2Target(SALT);
        (, bytes32 rootA2) = _runFixture(address(a2));
        assertEq(rootA, rootA2);
    }
}

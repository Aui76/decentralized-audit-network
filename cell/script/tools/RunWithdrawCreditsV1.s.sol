// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../../contracts/tools/WithdrawCreditsV1.sol";

interface IGate0Credits {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function credits(address) external view returns (uint256);
}

/// @dev Harness: run pinned fixture on TARGET_ADDRESS (or deploy new Gate0R2Target with TARGET_SALT).
/// Usage:
///   TARGET_ADDRESS=0x... forge script script/tools/RunWithdrawCreditsV1.s.sol:RunWithdrawCreditsV1 --rpc-url base_sepolia
contract RunWithdrawCreditsV1 is Script {
    function run() external {
        address target = vm.envAddress("TARGET_ADDRESS");
        IGate0Credits t = IGate0Credits(target);
        address caller = WithdrawCreditsV1.FIXTURE_CALLER;

        vm.deal(caller, 1 ether);
        vm.prank(caller);
        t.deposit{value: 1 ether}();
        uint256 pre = t.credits(caller);
        vm.prank(caller);
        t.withdraw(1 ether);
        uint256 post = t.credits(caller);

        (bool pass, bytes32 artifactHash, , bytes32 resultRoot) =
            WithdrawCreditsV1.encodeResult(target, pre, post);

        console2.log("target", target);
        console2.log("pass", pass);
        console2.log("artifactHash");
        console2.logBytes32(artifactHash);
        console2.log("specHash");
        console2.logBytes32(WithdrawCreditsV1.specHash());
        console2.log("toolId");
        console2.logBytes32(WithdrawCreditsV1.toolId());
        console2.log("contextRoot");
        console2.logBytes32(WithdrawCreditsV1.contextRoot());
        console2.log("resultRoot");
        console2.logBytes32(resultRoot);
    }
}

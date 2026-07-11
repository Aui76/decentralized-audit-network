// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title Gate0R2TargetFix
/// @dev Round 2 fix artifact — withdraw decrements credits (R2-01 satisfied).
contract Gate0R2TargetFix {
    uint256 public immutable salt;
    mapping(address => uint256) public credits;

    constructor(uint256 s) {
        salt = s;
    }

    function deposit() external payable {
        credits[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(credits[msg.sender] >= amount, "insufficient");
        credits[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");
    }
}

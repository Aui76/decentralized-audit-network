// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @title Gate0R2Target
/// @dev Round 2 bounty artifact. Distinct runtime codehash via immutable salt.
contract Gate0R2Target {
    uint256 public immutable salt;
    address public owner;
    mapping(address => uint256) public credits;

    constructor(uint256 s) {
        salt = s;
        owner = msg.sender;
    }

    function deposit() external payable {
        credits[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(credits[msg.sender] >= amount, "insufficient");
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");
    }
}

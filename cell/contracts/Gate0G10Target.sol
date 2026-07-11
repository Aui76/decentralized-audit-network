// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title Gate0G10Target
/// @dev R4 forgery simulation — CLEAN deposit/withdraw ledger (distinct salt / codehash).
contract Gate0G10Target {
    uint256 public immutable salt;
    mapping(address => uint256) public balance;

    constructor(uint256 s) {
        salt = s;
    }

    function deposit() external payable {
        balance[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(balance[msg.sender] >= amount, "insufficient balance");
        balance[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");
    }
}

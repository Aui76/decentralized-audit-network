// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @title Gate0R3Target
/// @dev Round 3 bounty artifact. Allowance-based pull ledger; distinct codehash via salt.
contract Gate0R3Target {
    uint256 public immutable salt;
    mapping(address => uint256) public balance;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint256 s) {
        salt = s;
    }

    function deposit() external payable {
        balance[msg.sender] += msg.value;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function pull(address from, address payable to, uint256 amount) external {
        require(balance[from] >= amount, "insufficient balance");
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        balance[from] -= amount;
        allowance[from][msg.sender] -= amount;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "transfer failed");
    }
}

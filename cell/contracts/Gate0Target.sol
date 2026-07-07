// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @title Gate0Target
/// @notice Gate 0 bounty artifact. Spec invariant GENESIS-G0-01: `release` MUST be
///         callable only by `keeper`. Off-chain spec id: keccak256("genesis.gate0.spec.v1").
/// @dev Deploy (1, false) for the vulnerable bounty; (2, true) for the fix audit artifact.
contract Gate0Target {
    uint256 public immutable salt;
    bool public immutable hardened;
    address public keeper;
    uint256 public locked;

    constructor(uint256 s, bool hardened_) {
        salt = s;
        hardened = hardened_;
        keeper = msg.sender;
    }

    function lockFunds() external payable {
        locked += msg.value;
    }

    function release(address payable to, uint256 amount) external {
        if (hardened) {
            require(msg.sender == keeper, "not keeper");
        }
        require(locked >= amount, "insufficient locked");
        locked -= amount;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "transfer failed");
    }
}

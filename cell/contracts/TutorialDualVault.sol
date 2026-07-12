// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @title TutorialDualVault
/// @dev Mini credit vault for tutorial-trick: withdraw path correct, transferCredits omits sender debit.
contract TutorialDualVault {
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

    /// @dev BUG (tutorial): credits[from] never decremented — passes withdraw-credits, fails transfer-credits.
    function transferCredits(address from, address to, uint256 amount) external {
        require(credits[from] >= amount, "insufficient");
        credits[to] += amount;
    }
}

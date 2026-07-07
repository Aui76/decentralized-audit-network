// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/*
 * CellToken — mintable token organ for AuditCell (Genesis public surface).
 *
 * G-02: genesisMint (admin, before setMinter) → setMinter(cell) → lockMinter() one-way.
 * After lock, only the network minter may inflate supply via mint().
 */
contract CellToken {
    string public name = "AUDIT";
    string public symbol = "AUDIT";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    address public admin;
    address public minter;
    bool public minterLocked;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event MinterUpdated(address indexed minter);
    event MinterLocked();
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    /// @dev Seed balances before minter is wired. Reverts once minter is set or locked.
    function genesisMint(address to, uint256 amount) external onlyAdmin {
        require(!minterLocked, "Minter locked");
        require(minter == address(0), "Minter already set");
        require(to != address(0), "Zero recipient");
        require(amount > 0, "Zero amount");
        _mint(to, amount);
    }

    function setMinter(address m) external onlyAdmin {
        require(!minterLocked, "Minter locked");
        require(m != address(0), "Zero minter");
        minter = m;
        emit MinterUpdated(m);
    }

    /// @notice One-way minter lock — call after setMinter(auditCell) and a smoke mint if desired.
    function lockMinter() external onlyAdmin {
        require(minter != address(0), "Minter unset");
        require(!minterLocked, "Already locked");
        minterLocked = true;
        emit MinterLocked();
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Zero admin");
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    /// @dev Only the network minter may mint after genesis wiring.
    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "Not minter");
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "Allowance");
        if (a != type(uint256).max) {
            allowance[from][msg.sender] = a - amount;
        }
        return _transfer(from, to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "Balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

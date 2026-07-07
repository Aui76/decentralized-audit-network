// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IERC20Minimal {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface ICellEscrowLp {
    function withdrawForLP(uint256 amount) external;
}

interface INonfungiblePositionManagerMint {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

/// @notice Holds AUDIT withdrawn via CellEscrow.withdrawForLP; admin seeds Uniswap off-chain / via script.
/// @dev L2 ops helper — NOT part of the frozen cell. Testnet (84532) only.
contract DemoLPManager {
    address public admin;
    IERC20Minimal public immutable auditToken;

    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event WithdrawnFromEscrow(address indexed escrow, uint256 amount);
    event Recovered(address indexed to, uint256 amount);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor(address admin_, address auditToken_) {
        require(admin_ != address(0) && auditToken_ != address(0), "Zero addr");
        admin = admin_;
        auditToken = IERC20Minimal(auditToken_);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Zero admin");
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    function withdrawFromEscrow(address escrow, uint256 amount) external onlyAdmin {
        ICellEscrowLp(escrow).withdrawForLP(amount);
        emit WithdrawnFromEscrow(escrow, amount);
    }

    function approveToken(address spender, uint256 amount) external onlyAdmin {
        require(auditToken.approve(spender, amount), "Approve failed");
    }

    function mintLiquidity(address npm, INonfungiblePositionManagerMint.MintParams calldata params)
        external
        onlyAdmin
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        return INonfungiblePositionManagerMint(npm).mint(params);
    }

    function recover(address to, uint256 amount) external onlyAdmin {
        require(auditToken.transfer(to, amount), "Transfer failed");
        emit Recovered(to, amount);
    }

    function auditBalance() external view returns (uint256) {
        return auditToken.balanceOf(address(this));
    }
}

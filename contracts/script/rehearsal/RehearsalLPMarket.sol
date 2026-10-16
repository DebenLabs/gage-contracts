// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

interface IRehearsalMint {
    function mint(address, uint256) external;
}

contract RehearsalMeme is ERC20 {
    constructor() ERC20("Meme LP Rehearsal", "rMEME") {
        require(block.chainid == 46_630, "TESTNET ONLY");
        _mint(msg.sender, 1_000_000e18);
    }
}

/// @notice A labeled meme/mock-stock LP fixture. Real BONER/HIMS is covered by MemeStockLPForkTest.
contract RehearsalLPMarket {
    address public immutable OWNER;
    IPositionManager public immutable POSM;
    IAllowanceTransfer public immutable PERMIT2;
    address public immutable STOCK;
    RehearsalMeme public immutable token;
    PoolKey public key;
    uint256 public listedTokenId;
    uint256 public walletTokenId;

    constructor(address owner, IPositionManager posm, IAllowanceTransfer permit2, address stock) {
        require(block.chainid == 46_630, "TESTNET ONLY");
        OWNER = owner;
        POSM = posm;
        PERMIT2 = permit2;
        STOCK = stock;
        token = new RehearsalMeme();
    }

    function create() external {
        require(msg.sender == OWNER && listedTokenId == 0, "OWNER OR ALREADY CREATED");
        bool meme0 = address(token) < STOCK;
        key = PoolKey(
            Currency.wrap(meme0 ? address(token) : STOCK),
            Currency.wrap(meme0 ? STOCK : address(token)),
            3000,
            60,
            IHooks(address(0))
        );
        uint256 amount0 = meme0 ? 50_000e18 : 50e18;
        uint256 amount1 = meme0 ? 50e18 : 50_000e18;
        uint160 price = uint160(Math.sqrt(Math.mulDiv(amount1, 1 << 192, amount0)));
        POSM.poolManager().initialize(key, price);
        IRehearsalMint(STOCK).mint(address(this), 101e18);
        IERC20(STOCK).approve(address(PERMIT2), type(uint256).max);
        token.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(STOCK, address(POSM), type(uint160).max, type(uint48).max);
        PERMIT2.approve(address(token), address(POSM), type(uint160).max, type(uint48).max);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            price, TickMath.getSqrtPriceAtTick(-887_220), TickMath.getSqrtPriceAtTick(887_220), amount0, amount1
        );
        listedTokenId = _mint(liquidity, amount0, amount1);
        walletTokenId = _mint(liquidity, amount0, amount1);
    }

    function _mint(uint128 liquidity, uint256 amount0, uint256 amount1) private returns (uint256 id) {
        id = POSM.nextTokenId();
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            int24(-887_220),
            int24(887_220),
            uint256(liquidity),
            uint128(amount0),
            uint128(amount1),
            OWNER,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        POSM.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)), params),
            block.timestamp
        );
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {TestnetOnly} from "./TestnetOnly.sol";

interface ITestnetMintable {
    function mint(address to, uint256 amount) external;
}

/// @title TestnetMarket
/// @notice Opens one priced Uniswap v4 market per call for a labeled gage testnet: it initializes the pool at the
///         price the two amounts imply and mints one full-range position. The coordinator sends one transaction
///         per market instead of encoding Permit2 and position calldata off chain.
/// @dev NEVER deploy this on chain 4663 (TestnetOnly). Test assets are minted here, which only works because
///      TestnetToken leaves `mint` open; a native-ETH side is funded by the call's value instead.
contract TestnetMarket is TestnetOnly, IERC721Receiver {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Marks this as a testnet fixture, for explorers and the app.
    string public constant TESTNET_NOTICE = "gage testnet fixture: no value";

    int24 internal constant FULL_LOWER = -887_220;
    int24 internal constant FULL_UPPER = 887_220;

    /// @notice The only caller that may open a market. Set once at deployment.
    address public immutable ADMIN;
    IPositionManager public immutable POSM;
    IPoolManager public immutable POOL_MANAGER;
    IAllowanceTransfer public immutable PERMIT2;

    error NotAdmin();
    error InvalidAmounts();
    error InsufficientValue();
    error PoolUnavailable();
    error RecoverFailed();

    event MarketOpened(bytes32 indexed poolId, uint160 price, uint256 tokenId, uint128 liquidity);

    constructor(address admin, IPositionManager posm, IAllowanceTransfer permit2) {
        ADMIN = admin;
        POSM = posm;
        POOL_MANAGER = posm.poolManager();
        PERMIT2 = permit2;
    }

    /// @notice Initialize `key` at the price `amount0:amount1` implies and mint a full-range position to `recipient`.
    /// @dev Idempotent on the pool: a pool already initialized keeps its price and only the position is minted.
    ///      Tick spacing must divide the full range, which every pool this testnet opens does.
    function open(PoolKey calldata key, uint256 amount0, uint256 amount1, address recipient)
        external
        payable
        returns (uint256 tokenId, uint160 price)
    {
        if (msg.sender != ADMIN) revert NotAdmin();
        if (amount0 == 0 || amount1 == 0) revert InvalidAmounts();
        price = uint160(Math.sqrt(Math.mulDiv(amount1, 1 << 192, amount0)));
        try POOL_MANAGER.initialize(key, price) returns (int24) {}
        catch {
            // Anyone may initialize a public pool first. Mint against the price the pool actually has, so the
            // position lands in the right ratio instead of the one these amounts imply.
            (uint160 live,,,) = POOL_MANAGER.getSlot0(key.toId());
            if (live == 0) revert PoolUnavailable();
            price = live;
        }
        uint256 native = _fund(key.currency0, amount0) + _fund(key.currency1, amount1);
        if (msg.value < native) revert InsufficientValue();
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            price, TickMath.getSqrtPriceAtTick(FULL_LOWER), TickMath.getSqrtPriceAtTick(FULL_UPPER), amount0, amount1
        );
        tokenId = POSM.nextTokenId();
        bytes memory actions = native == 0
            ? abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR))
            : abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](native == 0 ? 2 : 3);
        params[0] = abi.encode(
            key, FULL_LOWER, FULL_UPPER, uint256(liquidity), uint128(amount0), uint128(amount1), recipient, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        if (native != 0) params[2] = abi.encode(Currency.wrap(address(0)), ADMIN);
        POSM.modifyLiquidities{value: native}(abi.encode(actions, params), block.timestamp);
        emit MarketOpened(PoolId.unwrap(key.toId()), price, tokenId, liquidity);
    }

    /// @notice Return a test asset this helper still holds. A mint settles only what the position consumes, so the
    ///         unspent side of the amounts it was given stays here until someone asks for it back.
    function recoverToken(address token) external {
        if (msg.sender != ADMIN) revert NotAdmin();
        IERC20(token).transfer(ADMIN, IERC20(token).balanceOf(address(this)));
    }

    /// @notice Return leftover test ETH to the admin. Sweeping already refunds the unspent part of a mint.
    function recover() external {
        if (msg.sender != ADMIN) revert NotAdmin();
        (bool ok,) = ADMIN.call{value: address(this).balance}("");
        if (!ok) revert RecoverFailed();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(POSM)) revert NotAdmin();
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}

    /// @dev Mints the test asset this side needs, or reports the native amount the call must cover.
    function _fund(Currency currency, uint256 amount) private returns (uint256 native) {
        address token = Currency.unwrap(currency);
        if (token == address(0)) return amount;
        ITestnetMintable(token).mint(address(this), amount);
        IERC20(token).approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(token, address(POSM), type(uint160).max, type(uint48).max);
        return 0;
    }
}

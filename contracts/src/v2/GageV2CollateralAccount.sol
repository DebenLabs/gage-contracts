// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IUniV3PositionManager} from "../interfaces/IUniV3.sol";
import {Collateral, Kind} from "../types/Types.sol";

interface IV2V3PositionActions {
    struct DecreaseParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function decreaseLiquidity(DecreaseParams calldata) external payable returns (uint256, uint256);
    function collect(CollectParams calldata) external payable returns (uint256, uint256);
}

/// @notice One isolated collateral account per loan. Only its immutable-in-practice vault may release value.
contract GageV2CollateralAccount is IERC721Receiver, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address public vault;
    Collateral public collateral;
    bool public released;
    bool public recovered;
    address[2] public recoveryTokens;
    uint256[2] public recoveryAmounts;

    error NotVault();
    error AlreadyInitialized();
    error InvalidState();
    error TransferFailed();
    error UnexpectedNFT();
    error InsufficientRecovery();

    constructor() {
        vault = address(1);
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    /// @notice Atomically initialize a fresh clone before custody is transferred to it.
    function initialize(Collateral calldata c) external {
        if (vault != address(0)) revert AlreadyInitialized();
        vault = msg.sender;
        collateral = c;
    }

    /// @notice Release the entire original collateral on borrower withdrawal or cancellation.
    function release(address recipient) external onlyVault nonReentrant {
        if (released || recovered || recipient == address(0) || recipient == address(this)) revert InvalidState();
        released = true;
        Collateral memory c = collateral;
        if (c.kind == Kind.ERC20) IERC20(c.token).safeTransfer(recipient, c.amountOrTokenId);
        else IERC721(c.token).safeTransferFrom(address(this), recipient, c.amountOrTokenId);
    }

    /// @notice Recover full LP liquidity plus fees, or account for ERC20 default assets, once.
    function recover(uint256 min0, uint256 min1, uint256 deadline)
        external
        onlyVault
        nonReentrant
        returns (address[2] memory tokens, uint256[2] memory amounts)
    {
        if (released || recovered || block.timestamp > deadline) revert InvalidState();
        recovered = true;
        Collateral memory c = collateral;
        if (c.kind == Kind.ERC20) {
            tokens[0] = c.token;
            amounts[0] = c.amountOrTokenId;
        } else if (c.kind == Kind.UNIV3_POSITION) {
            IUniV3PositionManager.Position memory p = IUniV3PositionManager(c.token).positions(c.amountOrTokenId);
            tokens = [p.token0, p.token1];
            uint256 before0 = IERC20(p.token0).balanceOf(address(this));
            uint256 before1 = IERC20(p.token1).balanceOf(address(this));
            IV2V3PositionActions(c.token)
                .decreaseLiquidity(IV2V3PositionActions.DecreaseParams(c.amountOrTokenId, p.liquidity, 0, 0, deadline));
            IV2V3PositionActions(c.token)
                .collect(
                    IV2V3PositionActions.CollectParams(
                        c.amountOrTokenId, address(this), type(uint128).max, type(uint128).max
                    )
                );
            amounts = [
                IERC20(p.token0).balanceOf(address(this)) - before0, IERC20(p.token1).balanceOf(address(this)) - before1
            ];
        } else {
            if (min0 > type(uint128).max || min1 > type(uint128).max) revert InvalidState();
            IPositionManager posm = IPositionManager(c.token);
            (PoolKey memory key,) = posm.getPoolAndPositionInfo(c.amountOrTokenId);
            tokens = [Currency.unwrap(key.currency0), Currency.unwrap(key.currency1)];
            uint256 before0 = _balance(tokens[0]);
            uint256 before1 = _balance(tokens[1]);
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(
                c.amountOrTokenId,
                uint256(posm.getPositionLiquidity(c.amountOrTokenId)),
                uint128(0),
                uint128(0),
                bytes("")
            );
            params[1] = abi.encode(key.currency0, key.currency1, address(this));
            posm.modifyLiquidities(
                abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params),
                deadline
            );
            amounts = [_balance(tokens[0]) - before0, _balance(tokens[1]) - before1];
        }
        // The user's limits cover all newly recovered assets, including collected LP fees.
        // Check after collection so both v3 and v4 have identical minimum-received semantics.
        if (amounts[0] < min0 || amounts[1] < min1) revert InsufficientRecovery();
        recoveryTokens = tokens;
        recoveryAmounts = amounts;
    }

    /// @notice Send one recorded asset entitlement, authorized and accounted by the vault.
    function payRecovery(uint8 asset, address recipient, uint256 amount) external onlyVault nonReentrant {
        if (!recovered || asset > 1 || recipient == address(0) || recipient == address(this)) revert InvalidState();
        address token = recoveryTokens[asset];
        if (token == address(0)) {
            (bool ok,) = recipient.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(recipient, amount);
        }
    }

    function _balance(address token) private view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// @notice Accept only the loan's expected NFT, pulled by its vault.
    function onERC721Received(address operator, address, uint256 id, bytes calldata) external view returns (bytes4) {
        if (operator != vault || msg.sender != collateral.token || id != collateral.amountOrTokenId) {
            revert UnexpectedNFT();
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

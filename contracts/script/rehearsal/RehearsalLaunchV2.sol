// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {V4Swapper} from "../../src/token/base/V4Swapper.sol";

/// @dev Fixed supply, no mint entrypoint. This is explicitly a testnet stand-in, not a Pons token implementation.
contract RehearsalGAGEV2 is ERC20 {
    constructor() ERC20("GAGE Launch Rehearsal", "rGAGE") {
        require(block.chainid == 46_630, "TESTNET ONLY");
        _mint(msg.sender, 1_000_000_000e18);
    }
}

/// @notice Testnet replacement for the external launch step: a real v4 ETH pool, actual purchase, mock fee receipt.
/// @dev Omits Pons curve, graduation and hook behavior. The 0.1 ETH launch pool stays in this test fixture.
contract RehearsalLaunchV2 is V4Swapper, IERC721Receiver {
    address public immutable OWNER;
    IPositionManager public immutable POSM;
    IAllowanceTransfer public immutable PERMIT2;
    RehearsalGAGEV2 public token;
    address public creatorFeeRecipient;
    uint256 public creatorFees;
    uint256 public purchased;
    PoolKey internal _pool;

    event Launched(address indexed token, address indexed buyer, uint256 buyETH, uint256 purchased);
    event CreatorRecipientChanged(address indexed recipient);

    constructor(address owner, IPositionManager posm, IAllowanceTransfer permit2) V4Swapper(posm.poolManager()) {
        require(block.chainid == 46_630, "TESTNET ONLY");
        OWNER = owner;
        POSM = posm;
        PERMIT2 = permit2;
        creatorFeeRecipient = owner;
    }

    function launch() external payable {
        require(msg.sender == OWNER && address(token) == address(0), "ALREADY LAUNCHED OR WRONG OWNER");
        require(msg.value == 0.2 ether, "0.1 ETH pool + 0.1 ETH initial buy");
        token = new RehearsalGAGEV2();
        _pool = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(0)));
        uint160 price = uint160(Math.sqrt(Math.mulDiv(100_000_000e18, 1 << 192, 0.1 ether)));
        POOL_MANAGER.initialize(_pool, price);
        token.approve(address(PERMIT2), 100_000_000e18);
        PERMIT2.approve(address(token), address(POSM), uint160(100_000_000e18), type(uint48).max);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            price,
            TickMath.getSqrtPriceAtTick(-887_220),
            TickMath.getSqrtPriceAtTick(887_220),
            0.1 ether,
            100_000_000e18
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            _pool,
            int24(-887_220),
            int24(887_220),
            uint256(liquidity),
            uint128(0.1 ether),
            uint128(100_000_000e18),
            address(this),
            bytes("")
        );
        params[1] = abi.encode(_pool.currency0, _pool.currency1);
        params[2] = abi.encode(Currency.wrap(address(0)), address(this));
        POSM.modifyLiquidities{value: 0.1 ether}(
            abi.encode(
                abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP)), params
            ),
            block.timestamp
        );
        creatorFees = 0.001 ether; // fixture fee, deliberately not a statement of Pons economics
        purchased = _swapExactIn(_pool, true, 0.099 ether, 40_000_000e18);
        token.transfer(OWNER, purchased);
        emit Launched(address(token), OWNER, 0.1 ether, purchased);
    }

    function transferCreatorFeeRecipient(address recipient) external {
        require(msg.sender == OWNER && recipient != address(0));
        creatorFeeRecipient = recipient;
        emit CreatorRecipientChanged(recipient);
    }

    function claimCreatorFees() external {
        uint256 amount = creatorFees;
        creatorFees = 0;
        (bool ok,) = creatorFeeRecipient.call{value: amount}("");
        require(ok);
    }

    function pool() external view returns (PoolKey memory) {
        return _pool;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(msg.sender == address(POSM));
        return IERC721Receiver.onERC721Received.selector;
    }
}

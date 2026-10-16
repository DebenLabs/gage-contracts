// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract S0SwapToken is ERC20 {
    constructor(string memory symbol_) ERC20(symbol_, symbol_) {
        _mint(msg.sender, 1e30);
    }
}

interface S0V3Factory {
    function createPool(address, address, uint24) external returns (address);
}

interface S0V3Pool {
    function initialize(uint160) external;
    function mint(address, int24, int24, uint128, bytes calldata) external returns (uint256, uint256);
    function flash(address, uint256, uint256, bytes calldata) external;
}

interface S0Permit2 {
    function approve(address, address, uint160, uint48) external;
}

interface S0UniversalRouter {
    function execute(bytes calldata, bytes[] calldata, uint256) external payable;
}

struct S0RouterParameters {
    address permit2;
    address weth9;
    address v2Factory;
    address v3Factory;
    bytes32 pairInitCodeHash;
    bytes32 poolInitCodeHash;
    address v4PoolManager;
    address v3NFTPositionManager;
    address v4PositionManager;
    address spokePool;
}

interface S0V3PositionManager {
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

    struct DecreaseLiquidityParams {
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
    function mint(MintParams calldata) external payable returns (uint256, uint128, uint256, uint256);
    function decreaseLiquidity(DecreaseLiquidityParams calldata) external payable returns (uint256, uint256);
    function collect(CollectParams calldata) external payable returns (uint256, uint256);
    function ownerOf(uint256) external view returns (address);
}

/// Actual rebuilt upstream implementations; entirely local, with controlled 1:1 assets.
/// Scope: V3 funding, flash and router paths. NFT metadata, V2, Across and V4 swaps are separate gates.
contract IntentUniswapIntegrationTest is Test {
    string private artifacts;
    S0SwapToken private token0;
    S0SwapToken private token1;
    S0V3Pool private pool;
    S0V3PositionManager private nft;
    S0UniversalRouter private router;
    bool private underpay;

    function upstream(string memory name, bytes memory args) private returns (address) {
        return deployCode(string.concat(artifacts, "/", name, "-artifact.json"), args);
    }

    function setUp() public {
        artifacts = vm.envOr("INTENT_S0_UNISWAP_ARTIFACTS", string(""));
        if (bytes(artifacts).length == 0) {
            vm.skip(true);
            return;
        }
        vm.chainId(46_630);
        S0SwapToken a = new S0SwapToken("S0A");
        S0SwapToken b = new S0SwapToken("S0B");
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        address factory = upstream("V3Factory", "");
        pool = S0V3Pool(S0V3Factory(factory).createPool(address(token0), address(token1), 500));
        pool.initialize(uint160(1 << 96));
        pool.mint(address(this), -887_270, 887_270, 1e24, "");
        address permit = upstream("Permit2", "");
        nft = S0V3PositionManager(upstream("V3PositionManager", abi.encode(factory, address(token1), address(0))));
        bytes32 poolHash = keccak256(vm.getCode(string.concat(artifacts, "/V3Pool-artifact.json")));
        assertEq(poolHash, 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54);
        address manager = upstream("PoolManager", abi.encode(address(this)));
        address positions =
            upstream("PositionManager", abi.encode(manager, permit, uint256(100_000), address(0), address(token1)));
        router = S0UniversalRouter(
            upstream(
                "UniversalRouter",
                abi.encode(
                    S0RouterParameters(
                        permit,
                        address(token1),
                        address(0),
                        factory,
                        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f,
                        poolHash,
                        manager,
                        address(nft),
                        positions,
                        address(0)
                    )
                )
            )
        );
        token0.approve(permit, type(uint256).max);
        S0Permit2(permit).approve(address(token0), address(router), type(uint160).max, type(uint48).max);
    }

    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata) external {
        require(msg.sender == address(pool), "unexpected pool");
        token0.transfer(msg.sender, amount0);
        token1.transfer(msg.sender, amount1);
    }

    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external {
        require(msg.sender == address(pool), "unexpected pool");
        (uint256 amount0, uint256 amount1) = abi.decode(data, (uint256, uint256));
        token0.transfer(msg.sender, amount0 + (underpay ? 0 : fee0));
        token1.transfer(msg.sender, amount1 + fee1);
    }

    function testRealFlashLoanChargesBothAssetFees() public {
        uint256 balance0 = token0.balanceOf(address(pool));
        uint256 balance1 = token1.balanceOf(address(pool));
        pool.flash(address(this), 100e18, 200e18, abi.encode(uint256(100e18), uint256(200e18)));
        assertEq(token0.balanceOf(address(pool)) - balance0, 0.05e18);
        assertEq(token1.balanceOf(address(pool)) - balance1, 0.1e18);
    }

    function testFlashUnderpaymentRevertsAtomically() public {
        uint256 beforePool = token0.balanceOf(address(pool));
        uint256 beforeBorrower = token0.balanceOf(address(this));
        underpay = true;
        vm.expectRevert(bytes("F0"));
        pool.flash(address(this), 100e18, 0, abi.encode(uint256(100e18), uint256(0)));
        assertEq(token0.balanceOf(address(pool)), beforePool);
        assertEq(token0.balanceOf(address(this)), beforeBorrower);
    }

    function swap(uint256 minimum) private {
        bytes[] memory inputs = new bytes[](1);
        uint256[] memory minHopPriceX36 = new uint256[](1);
        minHopPriceX36[0] = 0.99e36;
        inputs[0] = abi.encode(
            address(this),
            uint256(1e18),
            minimum,
            abi.encodePacked(address(token0), uint24(500), address(token1)),
            true,
            minHopPriceX36
        );
        router.execute(hex"00", inputs, block.timestamp + 1);
    }

    function testProductionRouterUsesPermit2AndActualV3Pool() public {
        uint256 before0 = token0.balanceOf(address(this));
        uint256 before1 = token1.balanceOf(address(this));
        swap(0.99e18);
        assertEq(before0 - token0.balanceOf(address(this)), 1e18);
        uint256 received = token1.balanceOf(address(this)) - before1;
        assertGe(received, 0.99e18);
        assertLt(received, 1e18);
    }

    function testRouterMinimumOutputRevertsAtomically() public {
        uint256 before0 = token0.balanceOf(address(this));
        uint256 before1 = token1.balanceOf(address(this));
        vm.expectRevert(bytes4(keccak256("V3TooLittleReceived()")));
        swap(2e18);
        assertEq(token0.balanceOf(address(this)), before0);
        assertEq(token1.balanceOf(address(this)), before1);
    }

    function testRealV3PositionMintDecreaseAndCollect() public {
        token0.approve(address(nft), type(uint256).max);
        token1.approve(address(nft), type(uint256).max);
        (uint256 id, uint128 liquidity, uint256 spent0, uint256 spent1) = nft.mint(
            S0V3PositionManager.MintParams(
                address(token0),
                address(token1),
                500,
                -887_270,
                887_270,
                100e18,
                100e18,
                99e18,
                99e18,
                address(this),
                block.timestamp + 1
            )
        );
        assertEq(nft.ownerOf(id), address(this));
        assertGt(liquidity, 0);
        uint256 before0 = token0.balanceOf(address(this));
        uint256 before1 = token1.balanceOf(address(this));
        nft.decreaseLiquidity(
            S0V3PositionManager.DecreaseLiquidityParams(id, liquidity, 99e18, 99e18, block.timestamp + 1)
        );
        (uint256 received0, uint256 received1) =
            nft.collect(S0V3PositionManager.CollectParams(id, address(this), type(uint128).max, type(uint128).max));
        assertEq(token0.balanceOf(address(this)) - before0, received0);
        assertEq(token1.balanceOf(address(this)) - before1, received1);
        assertApproxEqAbs(received0, spent0, 2);
        assertApproxEqAbs(received1, spent1, 2);
    }
}

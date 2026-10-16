// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {V4Fixture} from "../utils/V4Fixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {GageV2CashoutRouter} from "../../src/v2/GageV2CashoutRouter.sol";
import {V2State} from "../../src/v2/V2Types.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {UniV4PositionAdapter} from "../../src/libraries/UniV4PositionAdapter.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GageV2ZapRouter} from "../../src/v2/GageV2ZapRouter.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {LiveEngine} from "./fixtures/LiveEngine.sol";
import {GageV2Registry} from "../../src/v2/GageV2Registry.sol";
import {GageV2CollateralAccount} from "../../src/v2/GageV2CollateralAccount.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";

/// Tests the deployed native V2 engine, bridge and custody implementation. Only admissions and test capital change
/// locally, after the fork reopens the engine to new loans.
contract CmeAdmissionLiveForkTest is V4Fixture {
    address constant CME = address(0x00e2324ff2a59f8ecba8c321c6466e59121c00e795);
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    bytes32 constant POOL = 0xff0aa5f0acd38204bcf7113cc8027b7269b34c675248129fff74371d7d2197b9;
    GageV2Vault vault;
    GageV2Registry registry;
    PoolKey key;
    address borrower;
    address lender;

    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("GAGE_CME_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_CME_FORK_BLOCK"));
        assertEq(block.chainid, 4663);
        assertEq(CME.codehash, 0xc714be92376dbbf4fdadccd16a1c49a5e0c41463e7c704b76770bde1d6240fb7);
        poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        posm = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        permit2 = IAllowanceTransfer(PERMIT2);
        vault = GageV2Vault(0x22658055B70b8B09616B1e0953f2A51cc66cF493);
        registry = GageV2Registry(address(vault.REGISTRY()));
        assertEq(address(registry), 0x1D9f88705D398Cd13Af4e35A74ef21253734f153);
        // Mainnet has since closed this engine to new loans. It is reopened on this fork only.
        LiveEngine.reopen(vault);
        key = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(CME), 0, 200, IHooks(0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044)
        );
        assertEq(_poolId(key), POOL);
        vm.startPrank(registry.owner());
        registry.setERC20Allowed(CME, true, Lane.MEME, 5000e18, 50_000e18, 200_000e18);
        registry.setPoolAllowed(POOL, true, 1e15);
        registry.setPoolInRangeRequired(POOL, true);
        vm.stopPrank();
        borrower = makeAddr("CME borrower");
        lender = makeAddr("CME lender");
        deal(CME, borrower, 600_000e18);
        deal(USDG, borrower, 100_000e6);
        deal(USDG, lender, 100_000e6);
        vm.startPrank(borrower);
        IERC20(CME).approve(address(vault), type(uint256).max);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        IERC721(address(posm)).setApprovalForAll(address(vault), true);
        vm.stopPrank();
        vm.prank(lender);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        _approvePosm(borrower, CME);
        _approvePosm(borrower, USDG);
    }

    function _list(Collateral memory c) internal returns (uint256 id) {
        vm.prank(borrower);
        id = vault.list(c, 90e6, 100e6, 7 days, uint40(block.timestamp + 1 days), false);
    }

    function _fund(uint256 id) internal {
        vm.prank(lender);
        vault.fund(id, 4);
    }

    function _repay(uint256 id) internal {
        vm.startPrank(borrower);
        vault.reclaim(id, borrower);
        vault.withdrawCollateral(id, borrower);
        vm.stopPrank();
    }

    function _default(uint256 id) internal {
        vm.warp(block.timestamp + 7 days + vault.GRACE());
        vault.finalizeDefault(id);
        vm.prank(lender);
        vault.recoverDefault(id, 0, 0, block.timestamp);
    }

    function testCME_erc20ReclaimAndDefaultExactDeltas() public {
        uint256 before = IERC20(CME).balanceOf(borrower);
        uint256 id = _list(Collateral(Kind.ERC20, CME, 10_000e18));
        _fund(id);
        assertEq(IERC20(CME).balanceOf(vault.getLoan(id).account), 10_000e18);
        _repay(id);
        assertEq(IERC20(CME).balanceOf(borrower), before);
        id = _list(Collateral(Kind.ERC20, CME, 10_000e18));
        _fund(id);
        _default(id);
        uint256 lenderBefore = IERC20(CME).balanceOf(lender);
        vm.prank(lender);
        vault.withdrawRecovery(id, 0, lender);
        assertEq(IERC20(CME).balanceOf(lender) - lenderBefore, 10_000e18);
    }

    function testCME_limitsAndRevocation() public {
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, CME, 4999e18));
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, CME, 50_001e18));
        uint256 first;
        for (uint256 i; i < 4; i++) {
            uint256 id = _list(Collateral(Kind.ERC20, CME, 50_000e18));
            if (i == 0) first = id;
        }
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, CME, 5000e18));
        vm.prank(registry.owner());
        registry.setERC20Allowed(CME, false, Lane.MEME, 0, 0, 0);
        vm.startPrank(borrower);
        vault.cancelFunding(first);
        vault.withdrawCollateral(first, borrower);
        vm.stopPrank();
        assertEq(IERC20(CME).balanceOf(borrower), 450_000e18);
    }

    function testCME_nativeEthLPRejectedDespitePoolAdmission() public {
        vm.startPrank(registry.owner());
        registry.setMemePairs(7);
        vm.expectRevert(CollateralRegistry.ZeroAddress.selector);
        registry.setERC20Allowed(address(0), true, Lane.ETH, 1, 1e30, 1e32);
        vm.stopPrank();
        deal(borrower, 2 ether);
        uint256 nft = posm.nextTokenId();
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            int24(-887_200),
            int24(887_200),
            uint256(2e15),
            type(uint128).max,
            type(uint128).max,
            borrower,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(address(0), borrower);
        vm.prank(borrower);
        posm.modifyLiquidities{value: 1 ether}(abi.encode(actions, params), block.timestamp + 60);
        assertGt(posm.getPositionLiquidity(nft), 1e15);
        vm.expectRevert(abi.encodeWithSelector(UniV4PositionAdapter.PairNotAllowed.selector, address(0), CME));
        _list(Collateral(Kind.UNIV4_POSITION, address(posm), nft));
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
        _decrease(key, nft, 2e15, borrower, borrower);
        assertEq(posm.getPositionLiquidity(nft), 0);
    }

    function _sell(PoolKey memory k, address input, uint256 amount) internal returns (uint256 out) {
        address output =
            input == Currency.unwrap(k.currency0) ? Currency.unwrap(k.currency1) : Currency.unwrap(k.currency0);
        bool zeroForOne = input == Currency.unwrap(k.currency0);
        (uint160 sqrt,,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(_poolId(k)));
        uint256 beforeOut = output == address(0) ? address(this).balance : IERC20(output).balanceOf(address(this));
        uint256 beforeIn = input == address(0) ? address(this).balance : IERC20(input).balanceOf(address(this));
        if (input != address(0)) IERC20(input).approve(address(swapRouter), amount);
        swapRouter.swap{value: input == address(0) ? amount : 0}(
            k,
            SwapParams(zeroForOne, -int256(amount), zeroForOne ? sqrt / 2 : sqrt * 2),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 afterIn = input == address(0) ? address(this).balance : IERC20(input).balanceOf(address(this));
        assertEq(beforeIn - afterIn, amount, "Input must fill exactly");
        out = (output == address(0) ? address(this).balance : IERC20(output).balanceOf(address(this))) - beforeOut;
    }

    function testCME_exitCapsViaNativeEthToUsdg() public {
        swapRouter = new PoolSwapTest(poolManager);
        PoolKey memory ethKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), 100, 1, IHooks(address(0)));
        (uint160 s,,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(POOL));
        (uint160 e,,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(_poolId(ethKey)));
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 2; i++) {
            uint256 amount = i == 0 ? 50_000e18 : 200_000e18;
            uint256 ethSpot = Math.mulDiv(Math.mulDiv(amount, 1 << 96, s), 1 << 96, s);
            uint256 spot = Math.mulDiv(Math.mulDiv(ethSpot, e, 1 << 96), e, 1 << 96);
            deal(CME, address(this), amount);
            uint256 ethOut = _sell(key, CME, amount);
            uint256 out = _sell(ethKey, address(0), ethOut);
            emit log_named_uint("CME input", amount);
            emit log_named_uint("spot USDG raw", spot);
            emit log_named_uint("exit USDG raw", out);
            emit log_named_uint("exit bps before gas", out * 10_000 / spot);
            assertGe(out * 10_000 / spot, 9500);
            vm.revertToState(snap);
            snap = vm.snapshotState();
        }
    }

    function testCME_cashoutViaDeployedRouterAndRouteRevocation() public {
        GageV2CashoutRouter router = GageV2CashoutRouter(payable(0x38E37cC00427Dd2A930d2A31e29E4104530d671b));
        PoolKey memory ethKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), 100, 1, IHooks(address(0)));
        uint256 id = _list(Collateral(Kind.ERC20, CME, 50_000e18));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(router), id);
        GageV2CashoutRouter.Route[] memory routes = new GageV2CashoutRouter.Route[](2);
        routes[0] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, CME, address(0), 0, key, 1);
        routes[1] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, address(0), USDG, 0, ethKey, 1);
        GageV2CashoutRouter.Exit memory x =
            GageV2CashoutRouter.Exit(id, borrower, 1, 10e6, 1, 0, block.timestamp, routes);
        vm.prank(router.owner());
        router.setV4Route(key, false);
        vm.prank(borrower);
        vm.expectRevert();
        router.cashOutDetailed(x);
        assertEq(IERC20(CME).balanceOf(vault.getLoan(id).account), 50_000e18);
        vm.prank(router.owner());
        router.setV4Route(key, true);
        uint256 before = IERC20(USDG).balanceOf(borrower);
        uint256 ethBefore = address(router).balance;
        uint256 cmeBefore = IERC20(CME).balanceOf(address(router));
        vm.prank(borrower);
        (,,, uint256 net) = router.cashOutDetailed(x);
        assertEq(IERC20(USDG).balanceOf(borrower) - before, net);
        assertGt(net, 0);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        assertEq(address(router).balance, ethBefore);
        assertEq(IERC20(CME).balanceOf(address(router)), cmeBefore);
        emit log_named_uint("cashout net USDG raw", net);
    }
}

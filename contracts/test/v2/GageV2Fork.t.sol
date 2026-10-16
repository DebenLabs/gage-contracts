// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {V4Fixture} from "../utils/V4Fixture.sol";
import {IUniV3Pool, IUniV3PositionManager} from "../../src/interfaces/IUniV3.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {MockOpenFunderGate} from "../mocks/MockFunderGate.sol";
import {GageV2Registry} from "../../src/v2/GageV2Registry.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {GageV2CollateralAccount} from "../../src/v2/GageV2CollateralAccount.sol";
import {GageV2CashoutRouter, IV2FlashPool} from "../../src/v2/GageV2CashoutRouter.sol";
import {V2Loan, V2State, V2Ask} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {DealFeeRouter} from "../../src/token/DealFeeRouter.sol";
import {FeeFloor} from "../../src/token/FeeFloor.sol";

interface IV3Lifecycle {
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

    function mint(MintParams calldata) external payable returns (uint256, uint128, uint256, uint256);
}

contract GageV2ForkTest is V4Fixture {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant SGAGE = 0x78c88CF8F6E612955526cEB501be82BF3279Bd5d;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant AI = 0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18;
    address constant AI_HOOK = 0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544;
    address constant TENDIES = 0x45242320DBB855EeA8Fd36804C6487E10E97FCF9;
    address constant V3_POOL = 0x237609918F330ADD285b8bC5f8f2922283D1C4C5;
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant V3_MANAGER = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address constant FLASH = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address constant BUYBACK = 0xEaE95cD11e1105BF1E82033c918ff17f931B0245;
    address constant FLOOR = 0x042fed6722e57093D97a4527ad622472ccC8A7be;
    address internal borrower;
    address internal buyer;
    address[4] internal lender;
    GageV2Registry internal registry;
    GageV2Vault internal vault;
    GageV2CashoutRouter internal router;
    PoolKey internal spyKey;
    PoolKey internal aiKey;
    PoolKey internal nvdaKey;
    PoolKey internal cashEthKey;

    function setUp() public virtual {
        string memory rpc = vm.envOr("GAGE_V2_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_V2_FORK_BLOCK"));
        assertEq(block.chainid, 4663);
        poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        posm = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        permit2 = IAllowanceTransfer(PERMIT2);
        borrower = makeAddr("v2 borrower");
        buyer = makeAddr("v2 right buyer");
        uint32[] memory terms = new uint32[](1);
        terms[0] = 7 days;
        registry = new GageV2Registry(address(this), terms, V3_FACTORY);
        registry.setMemePairs(5);
        registry.setERC20Allowed(SPY, true, Lane.STOCK, 1, 1000e18, 10_000e18);
        registry.setERC20Allowed(NVDA, true, Lane.STOCK, 1, type(uint128).max, type(uint256).max);
        registry.setERC20Allowed(AI, true, Lane.MEME, 1, type(uint128).max, type(uint256).max);
        registry.setERC20Allowed(TENDIES, true, Lane.MEME, 1, type(uint128).max, type(uint256).max);
        registry.setERC20Allowed(WETH, true, Lane.ETH, 1, type(uint128).max, type(uint256).max);
        registry.setV3PoolAllowed(V3_POOL, true, 1, type(uint128).max, type(uint128).max);
        registry.setRewardTerms(7 days, 100e18, 1, 5000);
        spyKey = PoolKey(Currency.wrap(SPY), Currency.wrap(USDG), 3000, 60, IHooks(address(0)));
        aiKey = PoolKey(Currency.wrap(AI), Currency.wrap(NVDA), 8_388_608, 8, IHooks(AI_HOOK));
        nvdaKey = PoolKey(Currency.wrap(USDG), Currency.wrap(NVDA), 3000, 60, IHooks(address(0)));
        cashEthKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), 100, 1, IHooks(address(0)));
        registry.setPoolAllowed(keccak256(abi.encode(aiKey)), true, 1);
        registry.setPoolRemovalHook(keccak256(abi.encode(aiKey)), AI_HOOK, AI_HOOK.codehash);
        vault = new GageV2Vault(
            GageV2TokenRegistry(address(registry)), IERC20(USDG), IERC20(SGAGE), BUYBACK, _grace(), _bridge()
        );
        // An engine lends to no one until a funder gate is bound (D47); these accounts stand in for vaults.
        vm.prank(makeAddr("open funder gate"));
        MockOpenFunderGate openGate = new MockOpenFunderGate();
        vault.REWARDS().bindFunderGate(openGate);
        _configureRewards();
        router = new GageV2CashoutRouter(vault, IV2FlashPool(FLASH), poolManager, WETH, address(this));
        router.setV4Route(spyKey, true);
        router.setV4Route(aiKey, true);
        router.setV4Route(nvdaKey, true);
        router.setV4Route(cashEthKey, true);
        router.setV3Route(V3_POOL, true);
        deal(SPY, borrower, 1000e18);
        deal(USDG, buyer, 100_000e6);
        vm.prank(buyer);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        for (uint8 i; i < 4; ++i) {
            lender[i] = address(uint160(0x2000 + i));
            deal(USDG, lender[i], 100_000e6);
            vm.prank(lender[i]);
            IERC20(USDG).approve(address(vault), type(uint256).max);
        }
    }

    function _bridge() internal virtual returns (GageLegacyAdapter) {
        return GageLegacyAdapter(address(0));
    }

    function _grace() internal view virtual returns (uint32) {
        return 1 days;
    }

    function _configureRewards() internal virtual {
        deal(SGAGE, address(this), 1_000_000e18);
        IERC20(SGAGE).approve(address(vault.REWARDS()), type(uint256).max);
        vault.REWARDS().fund(1_000_000e18);
    }

    function _open(Collateral memory c, uint128 cap) internal returns (uint256 id) {
        vm.startPrank(borrower);
        if (c.kind == Kind.ERC20) IERC20(c.token).approve(address(vault), c.amountOrTokenId);
        else IERC721(c.token).approve(address(vault), c.amountOrTokenId);
        id = vault.list(c, cap * 9 / 10, cap, 7 days, uint40(block.timestamp + 1 days), true);
        vault.approve(address(router), id);
        vm.stopPrank();
        for (uint8 i; i < 4; ++i) {
            vm.prank(lender[i]);
            vault.fund(id, 1);
        }
    }

    function _exit(uint256 id) internal view returns (GageV2CashoutRouter.Exit memory x) {
        x.loanId = id;
        x.recipient = borrower;
        x.minimumNet = 1;
        x.maxFinanceFee = 10e6;
        x.minUnderlying0 = 1;
        x.minUnderlying1 = vault.getLoan(id).kind == Kind.ERC20 ? 0 : 1;
        x.deadline = block.timestamp;
    }

    function _v4(PoolKey memory key, address input, address output)
        internal
        pure
        returns (GageV2CashoutRouter.Route memory)
    {
        return GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, input, output, 0, key, 1);
    }

    function _spyExit(uint256 id) internal view returns (GageV2CashoutRouter.Exit memory x) {
        x = _exit(id);
        x.routes = new GageV2CashoutRouter.Route[](1);
        x.routes[0] = _v4(spyKey, SPY, USDG);
    }

    function _checkExit(uint256 id, GageV2CashoutRouter.Exit memory x) internal returns (uint256 net) {
        uint256 beforeOwner = IERC20(USDG).balanceOf(borrower);
        uint256 beforePool = IERC20(USDG).balanceOf(FLASH);
        uint256 beforeFees = IERC20(USDG).balanceOf(BUYBACK);
        uint256 beforeRouter = IERC20(USDG).balanceOf(address(router));
        uint256 originalCredit = vault.cashCredit(borrower);
        vm.prank(borrower);
        (,,, net) = router.cashOutDetailed(x);
        uint256 financing = IERC20(USDG).balanceOf(FLASH) - beforePool;
        uint256 fee = IERC20(USDG).balanceOf(BUYBACK) - beforeFees;
        assertEq(fee, (net + fee) * 50 / 10_000, "fee only on cash after financing and cap");
        assertEq(IERC20(USDG).balanceOf(borrower) - beforeOwner, net);
        assertEq(IERC20(USDG).balanceOf(address(router)), beforeRouter);
        assertEq(vault.cashCredit(borrower), originalCredit);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        uint256 sum;
        for (uint8 i; i < 4; ++i) {
            sum += vault.cashCredit(lender[i]);
        }
        assertEq(sum, vault.getLoan(id).cap);
        emit log_named_uint("net USDG before gas", net);
        emit log_named_uint("cashout fee USDG", fee);
        emit log_named_uint("flash fee USDG", financing);
    }

    function testV2Fork_erc20CashoutFourLendersWithoutBorrowerUSDGAndPreservesDonations() public {
        uint256 id = _open(Collateral(Kind.ERC20, SPY, 1e18), 100e6);
        deal(USDG, address(router), 123e6);
        deal(SPY, address(router), 5e18);
        assertEq(IERC20(USDG).balanceOf(borrower), 0);
        _checkExit(id, _spyExit(id));
        assertEq(IERC20(SPY).balanceOf(address(router)), 5e18);
    }

    function testV2Fork_failedMinimumAndFinancingCapRollbackEverything() public {
        uint256 id = _open(Collateral(Kind.ERC20, SPY, 1e18), 100e6);
        GageV2CashoutRouter.Exit memory x = _spyExit(id);
        x.minimumNet = 100_000e6;
        uint256 beforePool = IERC20(USDG).balanceOf(FLASH);
        vm.prank(borrower);
        vm.expectRevert(GageV2CashoutRouter.InsufficientOutput.selector);
        router.cashOutDetailed(x);
        x.minimumNet = 1;
        x.maxFinanceFee = 0;
        vm.prank(borrower);
        vm.expectRevert(GageV2CashoutRouter.InsufficientOutput.selector);
        router.cashOutDetailed(x);
        assertEq(vault.ownerOf(id), borrower);
        assertEq(vault.cashCredit(lender[0]), 0);
        assertEq(IERC20(SPY).balanceOf(vault.getLoan(id).account), 1e18);
        assertEq(IERC20(USDG).balanceOf(FLASH), beforePool);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
    }

    function testV2Fork_routesOwnershipApprovalsAndCallbacksAreEnforced() public {
        uint256 id = _open(Collateral(Kind.ERC20, SPY, 1e18), 100e6);
        GageV2CashoutRouter.Exit memory x = _spyExit(id);
        // A caller who does not hold the right: the same exit reaches the core's approval check for the holder below.
        vm.expectRevert(GageV2CashoutRouter.InvalidExit.selector);
        router.cashOutDetailed(x);
        router.setV4Route(spyKey, false);
        vm.prank(borrower);
        vm.expectRevert(GageV2CashoutRouter.InvalidExit.selector);
        router.cashOutDetailed(x);
        // Pin that the refusal above was the route admission: the identical exit succeeds once the key is admitted.
        uint256 snapshot = vm.snapshotState();
        router.setV4Route(spyKey, true);
        vm.prank(borrower);
        router.cashOutDetailed(x);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        vm.revertToState(snapshot);
        vm.expectRevert(GageV2CashoutRouter.BadCallback.selector);
        router.uniswapV3FlashCallback(0, 0, "");
        vm.expectRevert(GageV2CashoutRouter.BadCallback.selector);
        router.uniswapV3SwapCallback(1, -1, "");
        vm.expectRevert(GageV2CashoutRouter.BadCallback.selector);
        router.unlockCallback("");
        // The pinned callers themselves are refused while no callback is expected: the stored hash and pool are clear.
        vm.prank(FLASH);
        vm.expectRevert(GageV2CashoutRouter.BadCallback.selector);
        router.uniswapV3FlashCallback(0, 0, "");
        vm.prank(V3_POOL);
        vm.expectRevert(GageV2CashoutRouter.BadCallback.selector);
        router.uniswapV3SwapCallback(1, -1, "");
        vm.prank(address(poolManager));
        vm.expectRevert(GageV2CashoutRouter.BadCallback.selector);
        router.unlockCallback("");
        router.setV4Route(spyKey, true);
        vm.prank(borrower);
        vault.approve(address(0), id);
        vm.prank(borrower);
        vm.expectRevert(GageV2Vault.NotAuthorized.selector);
        router.cashOutDetailed(x);
    }

    function testV2Fork_underwaterCashoutPreservesRight() public {
        uint256 id = _open(Collateral(Kind.ERC20, SPY, 1e18), 10_000e6);
        GageV2CashoutRouter.Exit memory x = _spyExit(id);
        vm.prank(borrower);
        vm.expectRevert(GageV2CashoutRouter.InsufficientOutput.selector);
        router.cashOutDetailed(x);
        assertEq(vault.ownerOf(id), borrower);
    }

    // Liquidity-position loans (v3 and v4 cash-outs and defaults) were tested here until D44: the release's engine lends
    // against tokens only and its collateral account refuses every position kind, so those cases cannot run on it.

    function testV2Fork_tradeAndExitFeesBuyOnlyGageAndAddRealFloorLiquidity() public {
        uint256 id = _open(Collateral(Kind.ERC20, SPY, 100e18), 10_000e6);
        vm.prank(borrower);
        vault.setAskWithMaxFee(id, 2000e6, uint40(block.timestamp + 1 hours), type(uint16).max);
        V2Ask memory ask = vault.getAsk(id);
        vm.prank(buyer);
        vault.buy(id, borrower, ask.nonce, ask.price, 100, borrower);
        vm.prank(borrower);
        vault.approve(address(router), id);
        _checkExit(id, _spyExit(id));
        assertEq(vault.cashCredit(BUYBACK), address(vault.BRIDGE()) == address(0) ? 110e6 : 20e6);
        vault.withdrawUSDGFor(BUYBACK);
        DealFeeRouter processor = DealFeeRouter(payable(BUYBACK));
        FeeFloor floor = FeeFloor(payable(FLOOR));
        uint256 beforeProcessed = processor.totalUSDGProcessed();
        uint256 beforeAdded = processor.totalGAGEAdded();
        uint256 sgageSupply = IERC20(SGAGE).totalSupply();
        uint256 opsBalance = floor.OPS_WALLET().balance;
        uint256 added = processor.process(10e6);
        assertGt(added, 0);
        assertEq(processor.totalUSDGProcessed() - beforeProcessed, 10e6);
        assertEq(processor.totalGAGEAdded() - beforeAdded, added);
        assertEq(IERC20(SGAGE).totalSupply(), sgageSupply);
        assertEq(floor.OPS_WALLET().balance, opsBalance);
        emit log_named_uint("GAGE added to permanent floor", added);
    }
}

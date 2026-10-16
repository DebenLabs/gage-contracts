// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Collateral} from "../../src/types/Types.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {LoopRouter} from "../../src/loop/LoopRouter.sol";
import {IUniV3Factory, IV2FlashPool} from "../../src/interfaces/IUniV3.sol";
import {KyberForkArbSys} from "../utils/KyberForkArbSys.sol";

/// @dev The core as the loop router meets it, lending nothing: it escrows the listing and pays nothing out, so the
///      borrower's own USDG pays for the purchase.
contract KyberForkCore {
    IERC20 public immutable USDG;
    uint256 public listed;

    constructor(IERC20 usdg) {
        USDG = usdg;
    }

    function listFor(Collateral calldata c, uint128, uint128, uint32, uint40, bool, address)
        external
        returns (uint256)
    {
        IERC20(c.token).transferFrom(msg.sender, address(this), c.amountOrTokenId);
        listed = c.amountOrTokenId;
        return 1;
    }

    function withdrawUSDGFor(address) external {}
}

/// @dev The fill router as the loop router meets it: it names the core and funds nothing.
contract KyberForkFills {
    address public immutable CORE;

    constructor(address core) {
        CORE = core;
    }

    function fill(IntentQuoteVerifier.Plan calldata, bytes calldata, uint256[] calldata)
        external
        pure
        returns (bytes32)
    {
        return bytes32(0);
    }
}

/// @notice A real KyberSwap route through `loopVia` (D243) on a LOCAL fork of Robinhood Chain mainnet at its latest
/// block: a canonical USDG/WETH V3 pool lends (the 0.01% one, or the 0.05% one when the route passes through the first),
/// and KyberSwap's router and every pool and market maker its route takes do the rest.
/// The core and the fill router are stand-ins that escrow the listing and lend nothing: what is checked is the purchase.
/// @dev Skipped unless KYBER_FORK_URL is set (the public node, never a keyed one); KYBER_FORK_TOKEN names another token
/// than NVDA, KYBER_FORK_LENDERS other USDG/WETH lenders and KYBER_FORK_ROUTER=v2 MetaAggregationRouterV2's route
/// instead of Router V3's (D246). Needs `--ffi` for scripts/kyber-route.mjs, which asks KyberSwap's public API for the
/// route. Nothing is sent to any chain.
contract LoopRouterKyberForkTest is Test {
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IUniV3Factory internal constant V3_FACTORY = IUniV3Factory(0x1f7d7550B1b028f7571E69A784071F0205FD2EfA);
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    /// @dev The lenders, in order: the USDG/WETH V3 pools at 0.01% (main's cash-out flash pool, `nativeV2.flashPool` in
    ///      launch/live/4663.json) and at 0.05%.
    string internal constant LENDERS =
        "0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca,0x69BfaF19C9f377BB306a89aEd9F6B07e2c1a8d9a";
    /// @dev KyberSwap's two routers on 4663, both admitted as on mainnet (D246): Router V3 (KSAggregationRouterV3),
    ///      which scripts/kyber-route.mjs asks KyberSwap's API to route through unless KYBER_FORK_ROUTER is `v2`, and
    ///      MetaAggregationRouterV2 (D239), the valuation service's fallback.
    address internal constant KYBER_ROUTER_V3 = 0x6868D319c8c9A78F7d39DC3602C5c917315132D7;
    address internal constant KYBER_ROUTER_V2 = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    bytes32 internal constant PRICING = keccak256("kyber fork pricing");
    uint256 internal constant SPEND = 10_000e6;
    uint256 internal constant SLIPPAGE_BPS = 50;

    function test_loopVia_buysThroughKyberSwap() public {
        string memory url = vm.envOr("KYBER_FORK_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        assertEq(block.chainid, 4663, "mainnet");
        vm.etch(address(0x64), address(new KyberForkArbSys()).code);
        address token = vm.envOr("KYBER_FORK_TOKEN", NVDA);

        KyberForkCore core = new KyberForkCore(IERC20(USDG));
        LoopRouter looper = new LoopRouter(
            IntentFillRouter(address(new KyberForkFills(address(core)))), POOL_MANAGER, V3_FACTORY, address(this)
        );
        looper.setExecutor(KYBER_ROUTER_V3, true);
        looper.setExecutor(KYBER_ROUTER_V2, true);
        string memory asked = vm.envOr("KYBER_FORK_ROUTER", string("v3"));
        bool v2 = keccak256(bytes(asked)) == keccak256("v2");
        require(v2 || keccak256(bytes(asked)) == keccak256("v3"), "KYBER_FORK_ROUTER is v3 or v2");

        string[] memory cmd = new string[](9);
        (cmd[0], cmd[1], cmd[2], cmd[3]) = ("node", "../scripts/kyber-route.mjs", vm.toString(USDG), vm.toString(token));
        (cmd[4], cmd[5], cmd[6], cmd[7], cmd[8]) =
        (
            vm.toString(SPEND),
            vm.toString(address(looper)),
            vm.envOr("KYBER_FORK_LENDERS", string(LENDERS)),
            vm.toString(SLIPPAGE_BPS),
            asked
        );
        (address executor, bytes memory data, uint256 quoted, uint256 minOut, address lender) =
            abi.decode(vm.ffi(cmd), (address, bytes, uint256, uint256, address));
        assertEq(executor, v2 ? KYBER_ROUTER_V2 : KYBER_ROUTER_V3, "the KyberSwap router asked for");

        address borrower = makeAddr("kyber-borrower");
        deal(USDG, borrower, 2 * SPEND);
        vm.prank(borrower);
        IERC20(USDG).approve(address(looper), type(uint256).max);

        uint24 lenderFee = IV2FlashPool(lender).fee();
        uint256 fee = (SPEND * lenderFee + 1e6 - 1) / 1e6;
        LoopRouter.LoopVia memory l = LoopRouter.LoopVia({
            executor: executor,
            data: data,
            flashToken: WETH,
            flashFee: lenderFee,
            spend: SPEND,
            own: 0,
            buy: minOut,
            maxCost: SPEND + fee,
            fundingDeadline: uint40(block.timestamp + 1 days),
            withRewards: false,
            pricing: PRICING
        });
        IntentQuoteVerifier.Plan memory p;
        p.token = token;
        p.collateral = minOut;
        p.listingId = 1;
        p.evidence = looper.evidenceFor(borrower, PRICING);
        uint256 flashBefore = IERC20(USDG).balanceOf(lender);

        vm.prank(borrower);
        (uint256 id, uint256 cost) = looper.loopVia(l, p, "", new uint256[](0));

        uint256 surplus = IERC20(token).balanceOf(borrower);
        assertEq(id, 1, "the planned listing");
        assertEq(core.listed(), minOut, "the pledge listed");
        assertEq(IERC20(token).balanceOf(address(core)), minOut, "the pledge escrowed");
        assertLe(cost, SPEND + fee, "within the borrower's bound");
        assertEq(IERC20(USDG).balanceOf(lender), flashBefore + fee, "the flash repaid with its fee");
        assertEq(IERC20(token).balanceOf(address(looper)), 0, "router tokens");
        assertEq(IERC20(USDG).balanceOf(address(looper)), 0, "router USDG");
        console2.log("USDG spent, raw", cost - fee);
        console2.log("lender", lender);
        console2.log("flash fee, raw", fee);
        console2.log("tokens quoted, raw", quoted);
        console2.log("tokens pledged, raw", minOut);
        console2.log("tokens to the borrower beyond the pledge, raw", surplus);
    }
}

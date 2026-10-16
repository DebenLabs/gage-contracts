// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {GageV2CashoutRouter} from "../../src/v2/GageV2CashoutRouter.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {IV2FlashPool} from "../../src/interfaces/IUniV3.sol";
import {KyberForkArbSys} from "../utils/KyberForkArbSys.sol";

/// @dev The registry as the cash-out router meets it: it names the V3 factory.
contract KyberCashoutRegistry {
    address public immutable V3_FACTORY;

    constructor(address factory) {
        V3_FACTORY = factory;
    }
}

/// @dev The core as the cash-out router meets it, holding one ACTIVE loan: the holder's right, the loan, `reclaim` that
///      takes exactly the cap, and `withdrawCollateral` that releases exactly the collateral to the beneficiary.
contract KyberCashoutCore {
    IERC20 public immutable USDG;
    address public immutable FEE_RECIPIENT;
    KyberCashoutRegistry public immutable REGISTRY;
    address public constant REWARDS = address(0);
    address public constant ACCOUNT_IMPLEMENTATION = address(0);
    address public constant BRIDGE = address(0);
    address public constant SGAGE = address(0);
    address internal immutable HOLDER;
    V2Loan internal _loan;

    constructor(
        IERC20 usdg,
        address feeRecipient,
        address factory,
        address holder,
        address token,
        uint128 cap,
        uint256 amount
    ) {
        USDG = usdg;
        FEE_RECIPIENT = feeRecipient;
        REGISTRY = new KyberCashoutRegistry(factory);
        HOLDER = holder;
        _loan.token = token;
        _loan.cap = cap;
        _loan.collateral = amount;
        _loan.state = V2State.ACTIVE;
    }

    function ownerOf(uint256) external view returns (address) {
        return HOLDER;
    }

    function getLoan(uint256) external view returns (V2Loan memory) {
        return _loan;
    }

    function reclaim(uint256, address recipient) external {
        USDG.transferFrom(msg.sender, address(this), _loan.cap);
        _loan.state = V2State.REPAID;
        _loan.collateralBeneficiary = recipient;
    }

    function withdrawCollateral(uint256, address recipient) external {
        require(msg.sender == _loan.collateralBeneficiary, "beneficiary");
        IERC20(_loan.token).transfer(recipient, _loan.collateral);
    }
}

/// @notice A real KyberSwap sale through `cashOutVia` (D245) on a LOCAL fork of Robinhood Chain mainnet at its latest
/// block: a canonical USDG/WETH V3 pool lends the cap (the 0.01% one, or the 0.05% one when the route passes through the
/// first), and KyberSwap's router and every pool and market maker its route takes sell the whole collateral.
/// The core is a stand-in holding one active loan: what is checked is the sale, the repayment and the payout.
/// @dev Skipped unless KYBER_FORK_URL is set (the public node, never a keyed one); KYBER_FORK_TOKEN names another token
/// than NVDA, KYBER_FORK_AMOUNT another collateral (raw units) and KYBER_FORK_LENDERS other lenders (any canonical V3
/// pools pairing USDG, in order of preference), and KYBER_FORK_ROUTER=v2 sells through MetaAggregationRouterV2's route
/// instead of Router V3's (D246). Needs `--ffi` for scripts/kyber-route.mjs, which asks KyberSwap's public API for the
/// route. Nothing is sent to any chain. When the node's CDN challenges forge's HTTP client (403 "Just a
/// moment"), point KYBER_FORK_URL at a local, read-only, throttled relay to that same public node.
contract GageV2CashoutKyberForkTest is Test {
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    /// @dev The USDG/WETH V3 pool at 0.01%: the router's pinned flash source for `cashOutDetailed`.
    address internal constant FLASH_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    /// @dev The lenders, in order: the USDG/WETH V3 pools at 0.01% and at 0.05%.
    string internal constant LENDERS =
        "0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca,0x69BfaF19C9f377BB306a89aEd9F6B07e2c1a8d9a";
    /// @dev KyberSwap's two routers on 4663, both admitted as on mainnet (D246): Router V3 (KSAggregationRouterV3),
    ///      which scripts/kyber-route.mjs asks KyberSwap's API to route through unless KYBER_FORK_ROUTER is `v2`, and
    ///      MetaAggregationRouterV2 (D239), the valuation service's fallback.
    address internal constant KYBER_ROUTER_V3 = 0x6868D319c8c9A78F7d39DC3602C5c917315132D7;
    address internal constant KYBER_ROUTER_V2 = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    uint256 internal constant SLIPPAGE_BPS = 50;

    function test_cashOutVia_sellsThroughKyberSwap() public {
        string memory url = vm.envOr("KYBER_FORK_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        assertEq(block.chainid, 4663, "mainnet");
        vm.etch(address(0x64), address(new KyberForkArbSys()).code);
        address token = vm.envOr("KYBER_FORK_TOKEN", NVDA);
        uint256 amount = vm.envOr("KYBER_FORK_AMOUNT", uint256(10e18));
        address holder = makeAddr("kyber-holder");
        address fees = makeAddr("kyber-fees");

        // KyberSwap builds the route for the router as sender and recipient, and the router takes the core's address
        // at construction: this test deploys the core, then the router, so the router's address is predicted.
        address predictedRouter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        (address executor, bytes memory data, uint256 quoted, uint256 minOut, address lender) =
            _route(token, amount, predictedRouter);
        assertEq(executor, _askedV2() ? KYBER_ROUTER_V2 : KYBER_ROUTER_V3, "the KyberSwap router asked for");

        uint128 cap = uint128(minOut / 2);
        KyberCashoutCore core = new KyberCashoutCore(IERC20(USDG), fees, V3_FACTORY, holder, token, cap, amount);
        GageV2CashoutRouter router = new GageV2CashoutRouter(
            GageV2Vault(address(core)), IV2FlashPool(FLASH_POOL), POOL_MANAGER, WETH, address(this)
        );
        assertEq(address(router), predictedRouter, "the router the route was built for");
        router.setExecutor(KYBER_ROUTER_V3, true);
        router.setExecutor(KYBER_ROUTER_V2, true);
        deal(token, address(core), amount);
        assertEq(IERC20(token).balanceOf(address(core)), amount, "collateral escrowed");

        uint24 lenderFee = IV2FlashPool(lender).fee();
        uint256 fee = (uint256(cap) * lenderFee + 1e6 - 1) / 1e6;
        GageV2CashoutRouter.ExitVia memory x = GageV2CashoutRouter.ExitVia({
            loanId: 1,
            recipient: holder,
            minimumNet: 1,
            maxFinanceFee: fee,
            deadline: block.timestamp + 300,
            executor: executor,
            data: data,
            flashToken: _otherToken(lender),
            flashFee: lenderFee,
            minUsdgOut: minOut
        });
        uint256 lenderBefore = IERC20(USDG).balanceOf(lender);

        vm.recordLogs();
        vm.prank(holder);
        (uint256 gross, uint256 financeFee, uint256 platformFee, uint256 net) = router.cashOutVia(x);
        uint256 usdgOut = _soldVia(address(router));

        uint256 r = usdgOut - cap - fee;
        assertGe(usdgOut, minOut, "at least the calldata's minimum");
        assertEq(gross, usdgOut, "gross is the sale");
        assertEq(financeFee, fee, "the lender's fee on the cap");
        assertEq(platformFee, r * 50 / 10_000, "0.5% of the remainder");
        assertEq(net, r - r * 50 / 10_000, "net");
        assertEq(IERC20(USDG).balanceOf(lender), lenderBefore + fee, "the lender repaid with its fee");
        assertEq(IERC20(USDG).balanceOf(holder), net, "the holder paid net");
        assertEq(IERC20(USDG).balanceOf(fees), platformFee, "the fee recipient paid");
        assertEq(IERC20(USDG).balanceOf(address(core)), cap, "the cap repaid to the core");
        assertEq(IERC20(token).balanceOf(address(router)), 0, "router tokens");
        assertEq(IERC20(USDG).balanceOf(address(router)), 0, "router USDG");
        assertEq(IERC20(token).allowance(address(router), executor), 0, "no approval left behind");
        console2.log("token", token);
        console2.log("collateral sold, raw", amount);
        console2.log("lender", lender);
        console2.log("flash fee, raw", fee);
        console2.log("USDG quoted, raw", quoted);
        console2.log("USDG minimum, raw", minOut);
        console2.log("USDG the sale returned, raw", usdgOut);
        console2.log("cap, raw", cap);
        console2.log("net to the holder, raw", net);
    }

    function _route(address token, uint256 amount, address router)
        internal
        returns (address executor, bytes memory data, uint256 quoted, uint256 minOut, address lender)
    {
        string[] memory cmd = new string[](9);
        (cmd[0], cmd[1], cmd[2], cmd[3]) = ("node", "../scripts/kyber-route.mjs", vm.toString(token), vm.toString(USDG));
        (cmd[4], cmd[5], cmd[6], cmd[7], cmd[8]) =
        (
            vm.toString(amount),
            vm.toString(router),
            vm.envOr("KYBER_FORK_LENDERS", string(LENDERS)),
            vm.toString(SLIPPAGE_BPS),
            _askedV2() ? "v2" : "v3"
        );
        return abi.decode(vm.ffi(cmd), (address, bytes, uint256, uint256, address));
    }

    /// @dev KYBER_FORK_ROUTER: `v3` (the default) asks for Router V3's route, `v2` for MetaAggregationRouterV2's.
    function _askedV2() internal view returns (bool) {
        bytes32 asked = keccak256(bytes(vm.envOr("KYBER_FORK_ROUTER", string("v3"))));
        require(asked == keccak256("v2") || asked == keccak256("v3"), "KYBER_FORK_ROUTER is v3 or v2");
        return asked == keccak256("v2");
    }

    /// @dev The lender's token other than USDG: the USDG/WETH pools by default, any USDG pool KYBER_FORK_LENDERS names.
    function _otherToken(address lender) internal view returns (address) {
        address token0 = IV2FlashPool(lender).token0();
        return token0 == USDG ? IV2FlashPool(lender).token1() : token0;
    }

    /// @dev The `usdgOut` of the router's one `SoldVia`.
    function _soldVia(address router) internal returns (uint256 usdgOut) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == router && logs[i].topics[0] == GageV2CashoutRouter.SoldVia.selector) {
                (, usdgOut,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                found = true;
            }
        }
        assertTrue(found, "SoldVia");
    }
}

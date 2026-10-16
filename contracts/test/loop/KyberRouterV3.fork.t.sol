// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {KyberForkArbSys} from "../utils/KyberForkArbSys.sol";

/// @dev KSAggregationRouterV3's swap parameters (KyberNetwork/ks-aggregation-router, src/interfaces/
///      IKSAggregationRouterV3.sol), to read what KyberSwap's API builds.
interface IKSRouterV3 {
    struct InputTokenData {
        bytes permitData;
        address[] feeRecipients;
        uint256[] fees;
        address[] targets;
        uint256[] amounts;
    }

    struct OutputTokenData {
        uint256 minAmount;
        address[] feeRecipients;
        uint256[] fees;
    }

    struct SwapParams {
        address[] inputTokens;
        uint256[] inputAmounts;
        InputTokenData[] inputData;
        address[] outputTokens;
        OutputTokenData[] outputData;
        bytes permit2Data;
        address executor;
        bytes executorData;
        address recipient;
        uint256 deadline;
        bytes clientData;
    }

    function swap(SwapParams calldata params) external payable returns (uint256[] memory outputAmounts, uint256 gasUsed);
    function PERMIT2() external view returns (address);
    function EXECUTOR_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function paused() external view returns (bool);
    function defaultAdmin() external view returns (address);
}

/// @dev A cash-out's sale, as the cash-out router makes it through an admitted executor (D245): it holds the tokens,
///      approves the executor for exactly the amount sold, calls it with the built call, resets the approval and judges
///      the sale only by its own balances: every token sold, nothing else taken, at least `minOut` USDG back.
contract KyberV3Seller {
    using SafeERC20 for IERC20;

    error StrayBalance();
    error PartialSale(uint256 sold, uint256 amountIn);
    error ShortSale(uint256 got, uint256 minOut);

    function sell(address executor, bytes calldata data, IERC20 token, IERC20 usdg, uint256 amountIn, uint256 minOut)
        external
        returns (uint256 got)
    {
        uint256 tokens = token.balanceOf(address(this));
        uint256 cash = usdg.balanceOf(address(this));
        token.forceApprove(executor, amountIn);
        (bool ok, bytes memory reason) = executor.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
        token.forceApprove(executor, 0);
        uint256 tokensNow = token.balanceOf(address(this));
        uint256 cashNow = usdg.balanceOf(address(this));
        if (tokensNow > tokens || cashNow < cash) revert StrayBalance();
        if (tokens - tokensNow != amountIn) revert PartialSale(tokens - tokensNow, amountIn);
        got = cashNow - cash;
        if (got < minOut) revert ShortSale(got, minOut);
    }
}

/// @notice KyberSwap's Router V3 (KSAggregationRouterV3, D246) on a LOCAL fork of Robinhood Chain mainnet at its latest
/// block: the contract at its address is the verified one, and a real KyberSwap sale of a token for USDG, built by its
/// public API for that router, runs from a contract that approves the router for exactly the amount sold, as the
/// cash-out router's KyberSwap entry does (D245). LoopRouterKyber.fork.t.sol makes the purchase through `loopVia`.
/// @dev Skipped unless KYBER_FORK_URL is set (the public node, never a keyed one); KYBER_FORK_TOKEN sells another token
/// than NVDA and KYBER_SALE_AMOUNT another raw amount. The sale needs `--ffi` for scripts/kyber-route.mjs, which asks
/// KyberSwap's public API for the route. Nothing is sent to any chain.
contract KyberRouterV3ForkTest is Test {
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    /// @dev KSAggregationRouterV3, the same address on every chain KyberSwap lists it for.
    address internal constant ROUTER_V3 = 0x6868D319c8c9A78F7d39DC3602C5c917315132D7;
    /// @dev keccak256 of its runtime code: Sourcify's exact match on Ethereum mainnet (verified 9 September 2026), which
    ///      is also the code on Base, BSC and 4663; its one immutable is Permit2's address, the same everywhere.
    bytes32 internal constant ROUTER_V3_CODEHASH = 0x0495909c9f14bcdb7976b38e8f69c1b17e7a437fdc468fcc59f79ee46baf8b97;
    /// @dev KyberSwap's AggregationExecutorProxy, the one executor its Router V3 admitted at deployment.
    address internal constant EXECUTOR = 0x8F10B468b06c6FD214B65F87778827F7D113f996;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @dev About 10,000 USDG of NVDA on 13 October 2026.
    uint256 internal constant SALE = 44e18;
    uint256 internal constant SLIPPAGE_BPS = 50;

    function _fork() internal returns (bool) {
        string memory url = vm.envOr("KYBER_FORK_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(url);
        assertEq(block.chainid, 4663, "mainnet");
        return true;
    }

    /// @dev The swap parameters a built call carries, without its selector.
    function decodeSwap(bytes calldata data) external pure returns (IKSRouterV3.SwapParams memory) {
        return abi.decode(data[4:], (IKSRouterV3.SwapParams));
    }

    function test_routerV3_isTheVerifiedContract() public {
        if (!_fork()) return;
        IKSRouterV3 router = IKSRouterV3(ROUTER_V3);
        assertEq(ROUTER_V3.codehash, ROUTER_V3_CODEHASH, "the verified runtime code");
        assertEq(router.PERMIT2(), PERMIT2, "canonical Permit2");
        assertTrue(router.hasRole(router.EXECUTOR_ROLE(), EXECUTOR), "the executor is admitted");
        assertFalse(router.paused(), "not paused");
        console2.log("default admin", router.defaultAdmin());
    }

    function test_sale_throughKyberSwapRouterV3_exactApproval() public {
        if (!_fork()) return;
        vm.etch(address(0x64), address(new KyberForkArbSys()).code);
        address token = vm.envOr("KYBER_FORK_TOKEN", NVDA);
        uint256 amount = vm.envOr("KYBER_SALE_AMOUNT", SALE);
        KyberV3Seller seller = new KyberV3Seller();

        // A sale borrows nothing: the zero address stands for the lender the script picks off the route.
        string[] memory cmd = new string[](9);
        (cmd[0], cmd[1], cmd[2], cmd[3]) = ("node", "../scripts/kyber-route.mjs", vm.toString(token), vm.toString(USDG));
        (cmd[4], cmd[5], cmd[6], cmd[7], cmd[8]) =
        (vm.toString(amount), vm.toString(address(seller)), vm.toString(address(0)), vm.toString(SLIPPAGE_BPS), "v3");
        (address executor, bytes memory data, uint256 quoted, uint256 minOut,) =
            abi.decode(vm.ffi(cmd), (address, bytes, uint256, uint256, address));
        assertEq(executor, ROUTER_V3, "KyberSwap's Router V3");
        // The call's first four bytes, its selector.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(bytes4(data), IKSRouterV3.swap.selector, "Router V3's swap");

        // The call pulls the sale with the router's own transferFrom (a non-empty permitData, not Permit2), into the
        // admitted executor, charges no fee and pays the seller.
        IKSRouterV3.SwapParams memory p = this.decodeSwap(data);
        assertEq(p.inputTokens.length, 1, "one input");
        assertEq(p.inputTokens[0], token, "sells the token");
        assertEq(p.inputAmounts[0], amount, "the whole amount");
        assertGt(p.inputData[0].permitData.length, 0, "ERC-20 transferFrom by the router");
        assertTrue(p.inputData[0].permitData.length != 160 && p.inputData[0].permitData.length != 192, "no permit");
        assertEq(p.inputData[0].feeRecipients.length, 0, "no input fee");
        uint256 pulled;
        for (uint256 i; i < p.inputData[0].amounts.length; ++i) {
            pulled += p.inputData[0].amounts[i];
        }
        assertEq(pulled, amount, "pulls exactly the sale");
        assertEq(p.permit2Data.length, 0, "no Permit2 signature");
        assertEq(p.outputTokens[0], USDG, "buys USDG");
        assertEq(p.outputData[0].minAmount, minOut, "the slippage floor");
        assertEq(p.outputData[0].feeRecipients.length, 0, "no output fee");
        assertEq(p.executor, EXECUTOR, "the admitted executor");
        assertEq(p.recipient, address(seller), "pays the seller");

        deal(token, address(seller), amount);
        uint256 got = seller.sell(executor, data, IERC20(token), IERC20(USDG), amount, minOut);

        assertGe(got, minOut, "at least the floor");
        assertEq(IERC20(token).balanceOf(address(seller)), 0, "every token sold");
        assertEq(IERC20(token).allowance(address(seller), ROUTER_V3), 0, "approval reset");
        console2.log("tokens sold, raw", amount);
        console2.log("USDG quoted, raw", quoted);
        console2.log("USDG floor, raw", minOut);
        console2.log("USDG received, raw", got);
        console2.log("Router V3 token dust, raw", IERC20(token).balanceOf(ROUTER_V3));
        console2.log("Router V3 USDG dust, raw", IERC20(USDG).balanceOf(ROUTER_V3));
    }
}

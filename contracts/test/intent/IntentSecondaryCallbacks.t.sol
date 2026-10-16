// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IntentSecondaryBaseTest} from "./IntentSecondaryBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {IntentLenderMarket} from "../../src/intent/IntentLenderMarket.sol";
import {HybridReserveMock} from "../mocks/HybridReserveMock.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {unitsOf} from "../helpers/CoreUnits.sol";

using {unitsOf} for GageV2Vault;

/// @dev Whoever a callback hands control to: it holds its own USDG and records what each attempt did.
contract CallbackAttacker {
    IERC20 internal immutable USDG;
    bytes4 internal constant LOCKED = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    /// @dev The outcome of each attempt, in order: the revert selector, or zero when it succeeded.
    bytes4[] public outcomes;
    uint256 public sharesIn;

    constructor(IERC20 usdg) {
        USDG = usdg;
    }

    function outcomeCount() external view returns (uint256) {
        return outcomes.length;
    }

    function _try(address target, bytes memory data) internal returns (bool ok, bytes memory out) {
        (ok, out) = target.call(data);
        outcomes.push(ok ? bytes4(0) : bytes4(out));
    }

    /// @dev Enter an earlier contributor, try the vault mid-payment, the router, the listing and the market's sale.
    function strike(IntentVault earlier, IntentVault current, IntentFillRouter router, IntentLenderMarket market)
        external
    {
        USDG.approve(address(earlier), type(uint256).max);
        (bool ok, bytes memory out) = _try(address(earlier), abi.encodeCall(IntentVault.deposit, (100e6, 0)));
        if (ok) sharesIn = abi.decode(out, (uint256));
        _try(address(current), abi.encodeCall(IntentVault.deposit, (1e6, 0)));
        _try(address(current), abi.encodeCall(IntentVault.redeem, (1, 0)));
        IntentQuoteVerifier.SecondaryPlan memory none;
        _try(address(router), abi.encodeCall(IntentFillRouter.fillSecondary, (none, "")));
        _try(address(market), abi.encodeCall(IntentLenderMarket.cancel, (1)));
        _try(address(market), abi.encodeCall(IntentLenderMarket.list, (1, 1, 1, 100)));
    }

    function redeem(IntentVault vault) external returns (uint256) {
        return vault.redeem(sharesIn, 0);
    }
}

/// @dev The fixture reserve, with one armed callback while a named vault withdraws.
contract CallbackReserve is HybridReserveMock {
    address public hookVault;
    CallbackAttacker public attacker;
    IntentVault public earlier;
    IntentFillRouter public router;
    IntentLenderMarket public market;

    constructor(IERC20 asset_) HybridReserveMock(asset_) {}

    function arm(
        address vault,
        CallbackAttacker attacker_,
        IntentVault earlier_,
        IntentFillRouter router_,
        IntentLenderMarket market_
    ) external {
        hookVault = vault;
        attacker = attacker_;
        earlier = earlier_;
        router = router_;
        market = market_;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        if (msg.sender == hookVault) {
            hookVault = address(0);
            attacker.strike(earlier, IntentVault(msg.sender), router, market);
        }
        return super.withdraw(assets, receiver, owner);
    }
}

/// @dev The fixture USDG, with one armed callback at the moment the seller's market pays the core.
contract SaleHookUSDG is MockERC20 {
    address public hookFrom;
    address public hookTo;
    CallbackAttacker public attacker;
    IntentVault public earlier;
    IntentVault public current;
    IntentFillRouter public router;
    IntentLenderMarket public market;

    constructor() MockERC20("USDG", "USDG", 6) {}

    function arm(
        address from,
        address to,
        CallbackAttacker attacker_,
        IntentVault earlier_,
        IntentVault current_,
        IntentFillRouter router_,
        IntentLenderMarket market_
    ) external {
        (hookFrom, hookTo, attacker, earlier, current, router, market) =
        (from, to, attacker_, earlier_, current_, router_, market_);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (from == hookFrom && to == hookTo && hookFrom != address(0)) {
            hookFrom = address(0);
            attacker.strike(earlier, current, router, market);
        }
        return super.transferFrom(from, to, amount);
    }
}

/// @notice S9-05, SEC-09: a callback during a staged multi-vault purchase cannot change any participant's shares
/// while its purchase-second accounting is open.
contract IntentSecondaryCallbacksTest is IntentSecondaryBaseTest {
    /// @dev Three days into the review loan a vault sells at no less than book value plus half the interest still to
    /// come (Pashov L-01), an asking price of about 1,067 after the 1% trade fee and the seller's manager fee; the odd
    /// units exercise the per-quarter remainder rule.
    uint128 internal constant PRICE = 1070e6 + 3;
    bytes4 internal constant LOCKED = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    CallbackAttacker internal attacker;

    function setUp() public override {
        super.setUp();
        attacker = new CallbackAttacker(IERC20(address(usdg)));
        usdg.mint(address(attacker), 1000e6);
    }

    function test_reserveCallbackDuringTheLastBuyersPaymentFindsEveryOpenBookLocked() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory probe = _marketPlan(id, vaults, masks);
        IntentVault first_ = IntentVault(probe.allocations[0].vault);
        IntentVault last = IntentVault(probe.allocations[2].vault);
        // The last buyer pays from the reserve, whose withdrawal hands control to the attacker.
        uint256 idle = last.cash() - 1e6;
        vm.prank(fillers[0]);
        fills.investReserve(address(last), idle, 0);
        CallbackReserve hooked = new CallbackReserve(IERC20(address(usdg)));
        vm.etch(address(reserve), address(hooked).code);
        CallbackReserve(address(reserve)).arm(address(last), attacker, first_, fills, sellerMarket);
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        uint256 assetsBefore = first_.totalAssets();
        _buy(p);
        assertEq(attacker.outcomeCount(), 6);
        // The first contributor has finished paying, but its purchase-second share lock still applies.
        assertEq(attacker.outcomes(0), IntentVault.SaleTooSoon.selector, "no mint in an earlier contributor");
        // The vault mid-payment, the router mid-fill: locked.
        assertEq(attacker.outcomes(1), LOCKED, "no mint mid-payment");
        assertEq(attacker.outcomes(2), LOCKED, "no burn mid-payment");
        assertEq(attacker.outcomes(3), LOCKED, "no reentry into the fill");
        // The listing cannot be changed by anyone but its curator.
        assertEq(attacker.outcomes(4), IntentLenderMarket.NotCurator.selector);
        assertEq(attacker.outcomes(5), IntentLenderMarket.NotCurator.selector);
        assertEq(attacker.sharesIn(), 0, "no shares minted during the purchase");
        assertGe(first_.totalAssets() + 1, assetsBefore - p.allocations[0].executionFee);
        vm.warp(block.timestamp + 1);
        vm.prank(address(attacker));
        uint256 shares = first_.deposit(100e6, 0);
        vm.prank(address(attacker));
        assertLe(first_.redeem(shares, 0), 100e6, "later entry receives no purchase windfall");
    }

    function test_paymentCallbackAtTheSaleFindsTheSellerAndItsListingLocked() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        SaleHookUSDG hooked = new SaleHookUSDG();
        vm.etch(address(usdg), address(hooked).code);
        // Mid-sale: the market is paying the core; the seller's books are open until the sale returns.
        SaleHookUSDG(address(usdg))
            .arm(address(sellerMarket), address(core), attacker, buyerA, seller, fills, sellerMarket);
        _buy(p);
        assertEq(attacker.outcomes(0), IntentVault.SaleTooSoon.selector, "no mint in a booked buyer this second");
        assertEq(attacker.outcomes(1), LOCKED, "no mint in the selling vault");
        assertEq(attacker.outcomes(2), LOCKED, "no burn in the selling vault");
        assertEq(attacker.outcomes(3), LOCKED, "no reentry into the fill");
        assertEq(attacker.outcomes(4), LOCKED, "the listing cannot change mid-sale");
        assertEq(attacker.outcomes(5), LOCKED, "nor be relisted");
        assertEq(core.unitsOf(id, address(buyerA)), 2);
        assertEq(attacker.sharesIn(), 0, "no shares minted during the sale");
    }
}

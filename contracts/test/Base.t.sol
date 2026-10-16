// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CollateralRegistry} from "../src/CollateralRegistry.sol";
import {DealVault} from "../src/DealVault.sol";
import {FeeSink} from "../src/FeeSink.sol";
import {EntryRouter} from "../src/EntryRouter.sol";
import {IDealVault} from "../src/interfaces/IDealVault.sol";
import {Kind, Collateral} from "../src/types/Types.sol";
import {Lane} from "../src/interfaces/ICollateralRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "./mocks/MockFeeOnTransferERC20.sol";
import {MockUniversalRouter} from "./mocks/MockUniversalRouter.sol";

/// @notice Deploys the M1 system against mock tokens. Every test suite starts here.
abstract contract BaseTest is Test {
    uint48 internal constant GRACE = 48 hours;
    uint32 internal constant T7 = 7 days;
    uint32 internal constant T21 = 21 days;
    uint16 internal constant FEE_BPS = 50;
    uint256 internal constant ONE_USDG = 1e6;

    uint256 internal constant NVDA_MIN = 1e18;
    uint256 internal constant NVDA_MAX_DEAL = 1000e18;
    uint256 internal constant NVDA_MAX_OPEN = 5000e18;

    uint256 internal constant USDG_PER_ETH = 3000e6;

    address internal safe = makeAddr("safe");
    address internal treasury = makeAddr("treasury");
    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");
    address internal lender2 = makeAddr("lender2");
    address internal other = makeAddr("other");

    MockERC20 internal usdg;
    MockERC20 internal nvda;
    MockERC20 internal aapl;
    /// @dev A meme that trades against NVDAx on a v4 pool: same adapter, own lane and caps.
    MockERC20 internal meme;
    MockFeeOnTransferERC20 internal feeToken;

    CollateralRegistry internal registry;
    DealVault internal vault;
    FeeSink internal feeSink;
    MockUniversalRouter internal ur;
    EntryRouter internal router;

    function setUp() public virtual {
        // A fixed, non-zero clock so expiry arithmetic is deterministic.
        vm.warp(1_800_000_000);

        usdg = new MockERC20("Global Dollar", "USDG", 6);
        nvda = new MockERC20("NVIDIA Stock Token", "NVDAx", 18);
        aapl = new MockERC20("Apple Stock Token", "AAPLx", 18);
        meme = new MockERC20("NVIDIA Dog", "NVDOG", 18);
        feeToken = new MockFeeOnTransferERC20();

        uint32[] memory terms = new uint32[](2);
        terms[0] = T7;
        terms[1] = T21;
        registry = new CollateralRegistry(safe, terms, FEE_BPS);
        feeSink = new FeeSink(usdg, safe, treasury);
        vault = new DealVault(usdg, registry, address(feeSink), address(0), GRACE);
        ur = new MockUniversalRouter(usdg, USDG_PER_ETH);
        router = new EntryRouter(vault, usdg, ur);

        vm.startPrank(safe);
        feeSink.setVault(vault);
        registry.setERC20Allowed(address(nvda), true, Lane.STOCK, NVDA_MIN, NVDA_MAX_DEAL, NVDA_MAX_OPEN);
        registry.setERC20Allowed(address(aapl), true, Lane.STOCK, 1e18, 1000e18, 5000e18);
        registry.setERC20Allowed(address(meme), true, Lane.MEME, 1000e18, 100_000e18, 500_000e18);
        registry.setRouter(address(router), true);
        vm.stopPrank();

        _fund(borrower);
        _fund(lender);
        _fund(lender2);
        _fund(other);

        vm.label(address(usdg), "USDG");
        vm.label(address(nvda), "NVDAx");
        vm.label(address(aapl), "AAPLx");
        vm.label(address(meme), "NVDOG");
        vm.label(address(registry), "CollateralRegistry");
        vm.label(address(vault), "DealVault");
        vm.label(address(feeSink), "FeeSink");
        vm.label(address(router), "EntryRouter");
        vm.label(address(ur), "MockUniversalRouter");
    }

    // ----------------------------------------------------------------- helpers

    function _fund(address who) internal {
        nvda.mint(who, 10_000e18);
        aapl.mint(who, 10_000e18);
        meme.mint(who, 1_000_000e18);
        feeToken.mint(who, 10_000e18);
        usdg.mint(who, 10_000_000e6);
        vm.deal(who, 100 ether);
        vm.startPrank(who);
        nvda.approve(address(vault), type(uint256).max);
        aapl.approve(address(vault), type(uint256).max);
        meme.approve(address(vault), type(uint256).max);
        feeToken.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _collateral(address token, uint256 amount) internal pure returns (Collateral memory) {
        return Collateral({kind: Kind.ERC20, token: token, amountOrTokenId: amount});
    }

    function _listingExpiry() internal view returns (uint40) {
        return uint40(block.timestamp + 3 days);
    }

    function _list(address who, address token, uint256 amount, uint128 cap, uint32 term, uint128 minPrice)
        internal
        returns (uint256 dealId)
    {
        vm.prank(who);
        dealId = vault.list(_collateral(token, amount), cap, term, _listingExpiry(), minPrice);
    }

    /// @dev 100 NVDAx, cap 8,000 USDG, 7 days, no minimum price.
    function _listDefault() internal returns (uint256 dealId) {
        return _list(borrower, address(nvda), 100e18, 8000e6, T7, 0);
    }

    function _bid(address who, uint256 dealId, uint128 price) internal returns (uint256 bidId) {
        vm.prank(who);
        bidId = vault.bid(dealId, price, uint40(block.timestamp + 1 days), who);
    }

    /// @dev Default listing funded by `lender` at 7,960 USDG.
    function _fundDeal() internal returns (uint256 dealId, uint256 bidId) {
        dealId = _listDefault();
        bidId = _bid(lender, dealId, 7960e6);
        vm.prank(borrower);
        vault.accept(dealId, bidId);
    }

    function _fee(uint128 price) internal pure returns (uint128) {
        return uint128((uint256(price) * FEE_BPS) / 10_000);
    }
}

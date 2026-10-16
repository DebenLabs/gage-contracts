// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {CollateralRegistry} from "../src/CollateralRegistry.sol";
import {DealVault} from "../src/DealVault.sol";
import {FeeSink} from "../src/FeeSink.sol";
import {EntryRouter} from "../src/EntryRouter.sol";
import {Kind, Collateral} from "../src/types/Types.sol";
import {DealState, Deal, BidState, Bid} from "../src/interfaces/IDealVault.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice End-to-end run of the M1 product against a live deployment, as three real accounts sending real
///         transactions: a stock deal through the reclaim branch, fee collection and sweep, a meme deal through the
///         reclaim branch, a cancelled listing with a withdrawn bid, a bid placed through EntryRouter with ETH, and a
///         1-day deal left FUNDED so the walk-away branch can be claimed on-chain once expiry + grace has passed.
/// @dev Env: GAGE_DEPLOYMENT (path to the deployment json), TESTNET_DEPLOYER_KEY, BORROWER_KEY, LENDER_KEY.
///      Every step checks the resulting state with `require`, so a wrong balance fails the simulation before
///      anything is broadcast.
contract E2E is Script {
    DealVault internal vault;
    CollateralRegistry internal registry;
    FeeSink internal feeSink;
    EntryRouter internal router;
    MockERC20 internal usdg;
    MockERC20 internal nvda;
    MockERC20 internal meme;

    uint256 internal deployerKey;
    uint256 internal borrowerKey;
    uint256 internal lenderKey;
    address internal borrower;
    address internal lender;

    uint256 public dealA;
    uint256 public dealB;
    uint256 public dealC;
    uint256 public dealD;
    uint256 public dealE;

    function run() external {
        _load();
        _approve();
        _stepStockReclaim();
        _stepFees();
        _stepMemeReclaim();
        _stepCancel();
        _stepRouterBidAndLeaveFunded();
        _stepFundAtAsk();
        _log();
    }

    // ---------------------------------------------------------------- steps

    /// @dev Stock deal: two bids, the higher accepted, the other withdrawn, proceeds withdrawn, early reclaim.
    function _stepStockReclaim() internal {
        uint256 lenderUSDG0 = usdg.balanceOf(lender);
        uint256 borrowerUSDG0 = usdg.balanceOf(borrower);

        dealA = _list(nvda, 100e18, 8000e6, 7 days);
        uint256 bidA1 = _bid(dealA, 7960e6);
        uint256 bidA2 = _bid(dealA, 7900e6);
        _accept(dealA, bidA1);

        Deal memory a = vault.getDeal(dealA);
        require(a.state == DealState.FUNDED && a.lender == lender && a.price == 7960e6, "A not funded");
        uint128 feeA = _fee(7960e6);
        require(vault.balanceUSDG(borrower) == 7960e6 - feeA, "A borrower proceeds");
        require(vault.balanceUSDG(address(feeSink)) == feeA, "A fee credited");

        vm.startBroadcast(lenderKey);
        vault.withdrawBid(bidA2);
        vault.withdrawUSDG();
        vm.stopBroadcast();
        require(vault.getBid(bidA2).state == BidState.WITHDRAWN, "A2 not withdrawn");

        vm.startBroadcast(borrowerKey);
        vault.withdrawUSDG();
        vault.reclaim(dealA);
        vault.withdrawERC20(address(nvda));
        vm.stopBroadcast();
        require(vault.getDeal(dealA).state == DealState.RECLAIMED, "A not reclaimed");
        require(vault.balanceUSDG(lender) == 8000e6, "A lender owed cap");
        require(vault.openRaw(address(nvda)) == 0, "A openRaw");

        vm.startBroadcast(lenderKey);
        vault.withdrawUSDG();
        vm.stopBroadcast();
        require(usdg.balanceOf(lender) == lenderUSDG0 - 7960e6 + 8000e6, "A lender net");
        require(usdg.balanceOf(borrower) == borrowerUSDG0 + 7960e6 - feeA - 8000e6, "A borrower net");
    }

    /// @dev Anyone collects the credited fee from the vault and sweeps it to the treasury.
    function _stepFees() internal {
        address treasury = feeSink.treasury();
        uint256 treasury0 = usdg.balanceOf(treasury);
        uint256 credited = vault.balanceUSDG(address(feeSink));
        require(credited > 0, "no fee credited");
        vm.startBroadcast(deployerKey);
        feeSink.collect();
        feeSink.sweep();
        vm.stopBroadcast();
        require(usdg.balanceOf(treasury) == treasury0 + credited, "fee not swept");
        require(vault.balanceUSDG(address(feeSink)) == 0, "fee balance not cleared");
    }

    /// @dev Meme lane: same adapter, own caps, reclaim branch.
    function _stepMemeReclaim() internal {
        dealB = _list(meme, 50_000e18, 3500e6, 7 days);
        uint256 bidB = _bid(dealB, 3400e6);
        _accept(dealB, bidB);
        uint256 memeBefore = meme.balanceOf(borrower);
        vm.startBroadcast(borrowerKey);
        vault.reclaim(dealB);
        vault.withdrawERC20(address(meme));
        vault.withdrawUSDG();
        vm.stopBroadcast();
        require(meme.balanceOf(borrower) == memeBefore + 50_000e18, "B meme not returned");
        require(vault.getDeal(dealB).state == DealState.RECLAIMED, "B not reclaimed");
        require(vault.openRaw(address(meme)) == 0, "B openRaw");
    }

    /// @dev Cancelled listing: collateral back to the borrower, the open bid withdrawable by the lender.
    function _stepCancel() internal {
        dealC = _list(nvda, 10e18, 800e6, 21 days);
        uint256 bidC = _bid(dealC, 700e6);
        vm.startBroadcast(borrowerKey);
        vault.cancel(dealC);
        vault.withdrawCollateral(dealC);
        vm.stopBroadcast();
        vm.startBroadcast(lenderKey);
        vault.withdrawBid(bidC);
        vault.withdrawUSDG();
        vm.stopBroadcast();
        require(vault.getDeal(dealC).state == DealState.CANCELLED, "C not cancelled");
        require(vault.getBid(bidC).state == BidState.WITHDRAWN, "C bid not withdrawn");
        require(vault.openRaw(address(nvda)) == 0, "C openRaw");
    }

    /// @dev Bid with ETH through EntryRouter on a 1-day deal, accept it, and leave it FUNDED for the claim branch.
    function _stepRouterBidAndLeaveFunded() internal {
        dealD = _list(nvda, 1e18, 10e6, 1 days);
        vm.startBroadcast(lenderKey);
        uint256 bidD = router.bidWithETH{value: 0.003 ether}(
            dealD, 8e6, uint40(block.timestamp + 2 days), "", new bytes[](0), block.timestamp + 1 hours
        );
        vm.stopBroadcast();
        Bid memory bd = vault.getBid(bidD);
        require(bd.lender == lender && bd.price == 8e6 && bd.state == BidState.OPEN, "D router bid");
        require(usdg.balanceOf(address(router)) == 0 && address(router).balance == 0, "router not empty");
        _accept(dealD, bidD);
        require(vault.getDeal(dealD).state == DealState.FUNDED, "D not funded");
    }

    /// @dev D43: an open-ended listing with an asking price, funded in one step, then reclaimed.
    function _stepFundAtAsk() internal {
        vm.startBroadcast(borrowerKey);
        dealE = vault.list(
            Collateral({kind: Kind.ERC20, token: address(nvda), amountOrTokenId: 2e18}), 200e6, 7 days, 0, 199e6
        );
        vm.stopBroadcast();
        require(vault.getDeal(dealE).listingExpiry == 0, "E not open-ended");
        vm.startBroadcast(lenderKey);
        uint256 bidE = vault.fund(dealE, lender);
        vm.stopBroadcast();
        Deal memory e = vault.getDeal(dealE);
        require(e.state == DealState.FUNDED && e.price == 199e6 && e.lender == lender, "E not funded at ask");
        require(vault.getBid(bidE).state == BidState.ACCEPTED, "E synthetic bid");
        vm.startBroadcast(borrowerKey);
        vault.reclaim(dealE);
        vm.stopBroadcast();
        require(vault.getDeal(dealE).state == DealState.RECLAIMED, "E not reclaimed");
    }

    // ---------------------------------------------------------------- helpers

    function _load() internal {
        string memory json = vm.readFile(vm.envString("GAGE_DEPLOYMENT"));
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "deployment is for another chain");
        vault = DealVault(vm.parseJsonAddress(json, ".DealVault"));
        registry = CollateralRegistry(vm.parseJsonAddress(json, ".CollateralRegistry"));
        feeSink = FeeSink(vm.parseJsonAddress(json, ".FeeSink"));
        router = EntryRouter(payable(vm.parseJsonAddress(json, ".EntryRouter")));
        usdg = MockERC20(vm.parseJsonAddress(json, ".USDG"));
        nvda = MockERC20(vm.parseJsonAddress(json, ".NVDAx"));
        meme = MockERC20(vm.parseJsonAddress(json, ".NVDOG"));
        deployerKey = vm.envUint("TESTNET_DEPLOYER_KEY");
        borrowerKey = vm.envUint("BORROWER_KEY");
        lenderKey = vm.envUint("LENDER_KEY");
        borrower = vm.addr(borrowerKey);
        lender = vm.addr(lenderKey);
    }

    function _approve() internal {
        vm.startBroadcast(borrowerKey);
        nvda.approve(address(vault), type(uint256).max);
        meme.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vm.stopBroadcast();
        vm.startBroadcast(lenderKey);
        usdg.approve(address(vault), type(uint256).max);
        vm.stopBroadcast();
    }

    function _list(MockERC20 token, uint256 amount, uint128 cap, uint32 term) internal returns (uint256 id) {
        vm.startBroadcast(borrowerKey);
        id = vault.list(
            Collateral({kind: Kind.ERC20, token: address(token), amountOrTokenId: amount}),
            cap,
            term,
            uint40(block.timestamp + 3 days),
            0
        );
        vm.stopBroadcast();
        require(vault.getDeal(id).state == DealState.LISTED, "not listed");
    }

    function _bid(uint256 dealId, uint128 price) internal returns (uint256 id) {
        vm.startBroadcast(lenderKey);
        id = vault.bid(dealId, price, uint40(block.timestamp + 2 days), lender);
        vm.stopBroadcast();
        require(vault.getBid(id).state == BidState.OPEN, "bid not open");
    }

    function _accept(uint256 dealId, uint256 bidId) internal {
        vm.startBroadcast(borrowerKey);
        vault.accept(dealId, bidId);
        vm.stopBroadcast();
    }

    function _fee(uint128 price) internal view returns (uint128) {
        return uint128((uint256(price) * registry.feeBps()) / 10_000);
    }

    function _log() internal view {
        console2.log("dealA (stock, reclaimed)      ", dealA);
        console2.log("dealB (meme, reclaimed)       ", dealB);
        console2.log("dealC (cancelled)             ", dealC);
        console2.log("dealD (funded via EntryRouter)", dealD);
        console2.log("dealD claimable by lender at  ", vault.claimableAt(dealD));
        console2.log("vault USDG balance            ", usdg.balanceOf(address(vault)));
        console2.log("vault NVDAx balance           ", nvda.balanceOf(address(vault)));
    }
}

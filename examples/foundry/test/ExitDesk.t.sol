// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Exit desk: gage's IntentExitDesk and each partner vault's IntentLenderMarket on a fork of Robinhood Chain mainnet.
//
// It checks that every generation's factory names the manifest's exit desk, reads each partner vault's market and the
// desk's views of it, then, as a depositor of a USDG partner vault, commits shares to an exit, shows why nothing is
// listed while the vault can pay (no shortfall), cancels, and leaves by an ordinary redemption. A sale of an exit
// listing is bought by partner vaults through the fill router, on a plan signed by gage's rates service and sent by
// gage's keeper, the only filler: the test stops before that step.
//
// Run from examples/foundry: forge test --match-path test/ExitDesk.t.sol -vv

import {MainnetFork} from "./MainnetFork.sol";
import {console2} from "forge-std/console2.sol";

interface IExitDesk {
    function CURATOR_FLOOR_BPS() external view returns (uint256);
    function START_KEEP_BPS() external view returns (uint256);
    function EXIT_LIFE() external view returns (uint256);
    function exits(address vault, address owner) external view returns (uint256 shares, uint256 id, uint64 nonce);
    function listings(address vault, uint256 id) external view returns (address owner, uint64 nonce);
    function committedAt(address vault, address owner) external view returns (uint256);
    function owed(address asset, address owner) external view returns (uint256);
    function exitNow(address vault, uint256 shares, uint256 id) external;
    function list(address vault, address owner, uint256 id) external;
    function cancel(address vault) external;
    function withdraw(address asset) external returns (uint256 amount);
    function floorBps(address vault, uint256 id) external view returns (uint256 floor);
    function floorOf(address vault, uint256 id, address owner) external view returns (uint256);
    function exitDebit(address vault, uint256 id) external view returns (address owner, uint256 debit);
    function shortfall(address vault, address owner) external view returns (uint256);
    function pendingSettlements(address vault) external view returns (uint256[] memory ids);
}

/// @dev IntentVault, a partner vault: the ERC-4626 surface and the reads used here.
interface IPartnerVault {
    function asset() external view returns (address);
    function VAULT() external view returns (address);
    function PROTOCOL_SOURCE() external view returns (address);
    function LENDER_MARKET() external view returns (address);
    function paused() external view returns (bool);
    function earliestMaturity() external view returns (uint40);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function freeLiquidity() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 shares) external returns (bool);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function deposit(uint256 assets, uint256 minShares) external returns (uint256 shares);
    function redeem(uint256 shares, uint256 minAssets) external returns (uint256 assets);
}

interface ILenderMarket {
    function SELLER() external view returns (address);
    function CORE() external view returns (address);
    function USDG() external view returns (address);
    function FACTORY() external view returns (address);
    function START_KEEP_BPS() external view returns (uint256);
    function AUCTION_SPAN() external view returns (uint256);
    function CURATOR_FLOOR_BPS() external view returns (uint256);
    function EXIT_GRACE() external view returns (uint256);
    function asks(uint256 id)
        external
        view
        returns (uint40 listedAt, uint40 deadline, uint16 maxFeeBps, uint8 slots, uint64 nonce, bool exit);
    function keepBps(uint256 id) external view returns (uint256);
    function list(uint256 id, uint40 deadline, uint16 maxFeeBps) external returns (uint64 nonce);
    function cancel(uint256 id) external;
    function buySplit(
        uint256 id,
        uint64 nonce,
        uint128 price,
        address[4] calldata recipients,
        uint128[4] calldata minRewards
    ) external returns (uint256 proceeds);
}

interface IFactory {
    function exitDesk() external view returns (address);
    function count() external view returns (uint256);
    function vaults(uint256 index) external view returns (address);
    function isVault(address vault) external view returns (bool);
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract ExitDeskTest is MainnetFork {
    error NotOwner();
    error InvalidAmount();
    error NoExit();
    error NoShortfall();
    error NothingToPay();
    error NotCurator();
    error StaleAsk();

    event ExitCommitted(address indexed vault, address indexed owner, uint256 shares);
    event ExitCancelled(address indexed vault, address indexed owner);

    IExitDesk internal desk;

    function setUp() public override {
        super.setUp();
        desk = IExitDesk(addressOf("intentV1.exitDesk"));
    }

    /// @notice One desk serves every generation; each partner vault's market names its vault, its factory and the
    ///         desk's falling-price rules.
    function test_desksAndMarkets() public view {
        assertEq(desk.CURATOR_FLOOR_BPS(), 5000);
        assertEq(desk.START_KEEP_BPS(), 9900);
        assertEq(desk.EXIT_LIFE(), 1 days);
        string[4] memory gens = ["intentV1", "intentV1Assets.GLD", "intentV1Assets.NVDA", "intentV1Assets.HIMS"];
        for (uint256 g; g < gens.length; ++g) {
            if (!has(string.concat(gens[g], ".exitDesk"))) continue;
            assertEq(
                addressOf(string.concat(gens[g], ".exitDesk")), address(desk), "each generation names the same desk"
            );
            IFactory factory = IFactory(addressOf(string.concat(gens[g], ".factory")));
            // A factory that names no desk (zero) has exits closed; the one it names is the manifest's.
            address named = factory.exitDesk();
            assertTrue(named == address(desk) || named == address(0), "factory's desk");
            uint256 n = factory.count();
            console2.log(gens[g], "partner vaults", n);
            for (uint256 i; i < n && i < 10; ++i) {
                _checkMarket(factory, IPartnerVault(factory.vaults(i)));
            }
        }
    }

    function _checkMarket(IFactory factory, IPartnerVault vault) internal view {
        ILenderMarket market = ILenderMarket(vault.LENDER_MARKET());
        assertEq(market.SELLER(), address(vault));
        assertEq(market.FACTORY(), address(factory));
        assertEq(market.CORE(), vault.VAULT());
        assertEq(market.USDG(), vault.asset(), "the market is paid in the vault's asset");
        assertEq(market.START_KEEP_BPS(), 9900);
        assertEq(market.AUCTION_SPAN(), 10 minutes);
        assertEq(market.CURATOR_FLOOR_BPS(), 5000);
        assertEq(market.EXIT_GRACE(), 1 minutes);
        uint256[] memory pending = desk.pendingSettlements(address(vault));
        console2.log("  vault", address(vault), "market", address(market));
        console2.log("  free liquidity", vault.freeLiquidity(), "records awaiting settle", pending.length);
    }

    /// @notice A depositor commits shares to an exit while the vault can pay them: the desk lists nothing (no
    ///         shortfall), the exit is cancelled, and the depositor leaves by redeeming.
    function test_commitCancelAndRedeem() public {
        IPartnerVault vault = _usdgVault();
        address holder = makeAddr("holder");
        uint256 assets = 100e6; // 100 USDG, six decimals

        // Deposit. You may end up holding the collateral instead of USDG.
        deal(vault.asset(), holder, assets);
        vm.startPrank(holder);
        IERC20(vault.asset()).approve(address(vault), assets);
        uint256 shares = vault.deposit(assets, 1);
        vm.stopPrank();
        assertEq(vault.balanceOf(holder), shares);

        // The desk takes a commitment only for shares the holder approved to it.
        vm.prank(holder);
        vm.expectRevert(InvalidAmount.selector);
        desk.exitNow(address(vault), shares, 0);

        vm.startPrank(holder);
        vault.approve(address(desk), shares);
        vm.expectEmit(address(desk));
        emit ExitCommitted(address(vault), holder, shares);
        desk.exitNow(address(vault), shares, 0); // id 0: commit, list nothing yet
        vm.stopPrank();
        (uint256 committed, uint256 listed, uint64 nonce) = desk.exits(address(vault), holder);
        assertEq(committed, shares);
        assertEq(listed, 0);
        assertEq(nonce, 0);
        assertEq(desk.committedAt(address(vault), holder), block.timestamp);

        // The vault holds enough outside its loans to pay these shares: no shortfall, so the desk lists nothing, and
        // a listing for this exit would stop where every listing starts.
        assertEq(desk.shortfall(address(vault), holder), 0);
        assertEq(desk.floorOf(address(vault), 1, holder), desk.START_KEEP_BPS());
        vm.prank(holder);
        vm.expectRevert(NoShortfall.selector);
        desk.list(address(vault), holder, 1);
        // Only the holder, or a filler the factory admits, lists for an exit.
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(NotOwner.selector);
        desk.list(address(vault), holder, 1);
        // A holding with no exit listing has the curator's floor.
        assertEq(desk.floorBps(address(vault), 1), desk.CURATOR_FLOOR_BPS());

        // Withdraw the commitment; nothing was sold, so nothing is owed.
        vm.startPrank(holder);
        vm.expectEmit(address(desk));
        emit ExitCancelled(address(vault), holder);
        desk.cancel(address(vault));
        vm.expectRevert(NoExit.selector);
        desk.cancel(address(vault));
        address asset = vault.asset();
        vm.expectRevert(NothingToPay.selector);
        desk.withdraw(asset);

        // Leave the ordinary way: a redemption, paid at once up to the vault's free liquidity.
        assertGe(vault.maxRedeem(holder), shares);
        uint256 quoted = vault.previewRedeem(shares);
        uint256 paid = vault.redeem(shares, quoted);
        vm.stopPrank();
        assertEq(paid, quoted);
        assertEq(IERC20(asset).balanceOf(holder), paid);
        console2.log("deposited", assets, "redeemed", paid);
    }

    /// @notice A vault's market lists and cancels only for its curator or the desk, and sells only a live listing.
    function test_marketRefusesStrangers() public {
        IPartnerVault vault = _usdgVault();
        ILenderMarket market = ILenderMarket(vault.LENDER_MARKET());
        (uint40 listedAt,,,,,) = market.asks(1);
        if (listedAt == 0) assertEq(market.keepBps(1), 0, "no listing, no price");
        vm.startPrank(makeAddr("stranger"));
        vm.expectRevert(NotCurator.selector);
        market.list(1, uint40(block.timestamp + 1 hours), 0);
        vm.expectRevert(NotCurator.selector);
        market.cancel(1);
        if (listedAt == 0) {
            address[4] memory recipients;
            uint128[4] memory minRewards;
            vm.expectRevert(StaleAsk.selector);
            market.buySplit(1, 1, 1, recipients, minRewards);
        }
        vm.stopPrank();
    }

    /// @dev The USDG generation's first partner vault, open to deposits now; skip when none is.
    function _usdgVault() internal returns (IPartnerVault vault) {
        IFactory factory = IFactory(addressOf("intentV1.factory"));
        if (factory.count() == 0 || factory.exitDesk() != address(desk)) vm.skip(true);
        vault = IPartnerVault(factory.vaults(0));
        if (vault.paused() || block.timestamp >= vault.earliestMaturity()) vm.skip(true);
    }
}

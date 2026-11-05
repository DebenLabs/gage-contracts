// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// What this shows: gage's LP lane on a fork of Robinhood Chain mainnet.
//   1. The registry: which adapters and pools new loans may use, the terms, the fee and the caps.
//   2. The borrower's permissionless steps against a Uniswap v3 WETH/USDG position: mint it in an admitted pool, read
//      it through its adapter, approve the core. `borrow` then needs a quote signed by gage's rates service, so with
//      no signature it reverts and the position never leaves the wallet.
//   3. The rest of a loan's life, with two stand-ins for gage's parts, labelled where they happen: the registry owner
//      lets a curator open a vault and names a test key as the quote signer, and that key signs the quotes gage's
//      rates service would. Everything else is the reader's own role: deposit, borrow, collect, repay, take the
//      position back, redeem; or let the term end unpaid, settle it late as anyone may, and claim the bonus.
// Run from examples/foundry:  forge test --match-path test/LPLane.t.sol -vv

import {MainnetFork} from "./MainnetFork.sol";
import {console2} from "forge-std/console2.sol";

// ---- Types, as in src/lp/LPTypes.sol ----------------------------------------------------------------------------

struct PositionFacts {
    address pool;
    address token0;
    address token1;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
}

enum LoanState {
    NONE,
    ACTIVE,
    REPAID,
    DEFAULTED,
    ABANDONED,
    ROLLED
}

struct Loan {
    address borrower;
    address vault;
    address adapter;
    address escrow;
    address pool;
    uint256 tokenId;
    uint128 principal;
    uint128 repayment;
    uint40 start;
    uint40 end;
    LoanState state;
    bool positionReturned;
}

struct LoanQuote {
    address borrower;
    address vault;
    address adapter;
    uint256 tokenId;
    uint128 liquidity;
    int24 tickLower;
    int24 tickUpper;
    uint128 collateralValue;
    uint128 principal;
    uint128 repayment;
    uint32 term;
    uint16 feeBps;
    uint64 deadline;
}

struct SaleQuote {
    address vault;
    uint256 loanId;
    address token;
    uint256 amountIn;
    uint256 minOut;
    address executor;
    uint64 deadline;
}

struct PoolConfig {
    bool allowed;
    uint24 minHalfWidthTicks;
    uint128 minLoanPrincipal;
    uint128 maxLoanPrincipal;
    uint128 maxOutstanding;
}

struct PoolRef {
    address adapter;
    address pool;
}

struct Lot {
    uint128 amount;
    uint40 since;
    bool writtenOff;
}

// ---- Minimal interfaces: only the functions called, signatures as in src/lp/ -------------------------------------

interface ILPCore {
    function REGISTRY() external view returns (address);
    function USDG() external view returns (address);
    function nextLoanId() external view returns (uint256);
    function loan(uint256 loanId) external view returns (Loan memory);
    function credit(address account, address token) external view returns (uint256);
    function loanQuoteDigest(LoanQuote calldata quote) external view returns (bytes32);
    function borrow(LoanQuote calldata quote, bytes calldata signature) external returns (uint256 loanId);
    function collectFees(uint256 loanId) external returns (uint256 amount0, uint256 amount1);
    function repay(uint256 loanId) external;
    function returnPosition(uint256 loanId) external;
    function settleDefaultLate(uint256 loanId) external;
    function withdraw(address token) external returns (uint256 amount);
}

interface ILPRegistry {
    function owner() external view returns (address);
    function feeBps() external view returns (uint16);
    function ltvCapBps() external view returns (uint16);
    function lateUnwindDelay() external view returns (uint32);
    function newLoansPaused() external view returns (bool);
    function quoteSigner() external view returns (address);
    function dailyOriginationCap() external view returns (uint128);
    function terms() external view returns (uint32[] memory);
    function termAllowed(uint32 term) external view returns (bool);
    function adapterAllowed(address adapter) external view returns (bool);
    function vaultAllowed(address vault) external view returns (bool);
    function executorAllowed(address executor) external view returns (bool);
    function poolConfig(address adapter, address pool) external view returns (PoolConfig memory);
    function vaultFactory() external view returns (address);
    function openCreation() external view returns (bool);
    function mayOpenVault(address account) external view returns (bool);
    function setQuoteSigner(address signer) external;
    function setCurator(address curator, bool allowed) external;
}

interface ILPAdapter {
    function positionManager() external view returns (address);
    function core() external view returns (address);
    function facts(uint256 tokenId) external view returns (PositionFacts memory);
    function rewardTokens() external view returns (address[] memory);
}

interface ILPVaultFactory {
    function vaultCount() external view returns (uint256);
    function vaultsFrom(uint256 start, uint256 count) external view returns (address[] memory page);
    function create(string calldata name, uint16 performanceFeeBps, uint128 maxLoanPrincipal, PoolRef[] calldata pools)
        external
        returns (address vault);
}

interface ILPVault {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function funds(address adapter, address pool) external view returns (bool);
    function impaired() external view returns (bool);
    function openLoans() external view returns (uint256[] memory);
    function lot(uint256 loanId, address token) external view returns (Lot memory);
    function bonusClaimable(uint256 loanId, address account) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function saleQuoteDigest(SaleQuote calldata quote) external view returns (bytes32);
    function deposit(uint256 assets, address receiver, uint256 minShares) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner, uint256 minAssets)
        external
        returns (uint256 assets);
    function sell(SaleQuote calldata quote, bytes calldata signature) external returns (uint256 amountOut);
    function claimBonus(uint256 loanId) external returns (uint256 amount);
}

/// @notice Uniswap v3's NonfungiblePositionManager: the calls this example makes.
interface INonfungiblePositionManager {
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

    function factory() external view returns (address);
    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function approve(address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function tickSpacing() external view returns (int24);
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract LPLaneTest is MainnetFork {
    ILPCore internal core;
    ILPRegistry internal registry;
    ILPVaultFactory internal factory;
    address internal usdg;
    address internal weth;

    // The Uniswap v3 WETH/USDG 0.05% pool and the adapter it is admitted under.
    address internal adapter;
    address internal pool;
    INonfungiblePositionManager internal nfpm;

    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");
    address internal curator = makeAddr("curator");
    address internal anyone = makeAddr("anyone");

    function setUp() public override {
        super.setUp();
        if (!has("lpLane.core")) vm.skip(true);
        core = ILPCore(addressOf("lpLane.core"));
        registry = ILPRegistry(addressOf("lpLane.registry"));
        factory = ILPVaultFactory(addressOf("lpLane.vaultFactory"));
        usdg = addressOf("USDG");
        weth = addressOf("WETH");
        (adapter, pool) = _uniswapV3WethUsdg();
        nfpm = INonfungiblePositionManager(ILPAdapter(adapter).positionManager());
    }

    /// The registry: every adapter and pool the manifest lists, as new loans may use them now.
    function test_readTheRegistry() public view {
        assertEq(core.REGISTRY(), address(registry), "the core answers to the manifest's registry");
        assertEq(core.USDG(), usdg, "the core lends USDG");
        assertEq(registry.vaultFactory(), address(factory), "the registry trusts the manifest's vault factory");

        uint32[] memory terms = registry.terms();
        for (uint256 i; i < terms.length; ++i) {
            console2.log("term (days)", terms[i] / 1 days);
        }
        console2.log("origination fee (bps)", registry.feeBps());
        console2.log("loan cap (bps of the signed collateral value)", registry.ltvCapBps());
        console2.log("late unwind opens after the end (s)", registry.lateUnwindDelay());
        console2.log("daily origination cap (raw USDG)", registry.dailyOriginationCap());
        console2.log("new loans paused", registry.newLoansPaused());

        for (uint256 i; has(_key("lpLane.adapters", i, "address")); ++i) {
            ILPAdapter a = ILPAdapter(addressOf(_key("lpLane.adapters", i, "address")));
            assertEq(a.core(), address(core), "every adapter answers to the core");
            assertEq(a.positionManager(), addressOf(_key("lpLane.adapters", i, "positionManager")));
            console2.log("adapter", address(a), registry.adapterAllowed(address(a)) ? "allowed" : "not allowed");
            console2.log("  reward tokens", a.rewardTokens().length);
        }
        for (uint256 i; has(_key("lpLane.pools", i, "pool")); ++i) {
            address a = addressOf(_key("lpLane.pools", i, "adapter"));
            address p = addressOf(_key("lpLane.pools", i, "pool"));
            PoolConfig memory c = registry.poolConfig(a, p);
            console2.log("pool", p, c.allowed ? "admitted" : "not admitted");
            console2.log("  least and most loan (raw USDG)", c.minLoanPrincipal, c.maxLoanPrincipal);
            console2.log("  most outstanding (raw USDG)", c.maxOutstanding);
        }
        for (uint256 i; has(_key("lpLane.executors", i, "address")); ++i) {
            address e = addressOf(_key("lpLane.executors", i, "address"));
            console2.log("executor", e, registry.executorAllowed(e) ? "allowed" : "not allowed");
        }
        console2.log("vaults the factory opened", factory.vaultCount());
        console2.log("open vault creation", registry.openCreation());
        console2.log("loans opened so far", core.nextLoanId() - 1);
    }

    /// A borrower's own steps: mint a position in an admitted pool, read it through its adapter, approve the core.
    /// The borrow itself takes a quote signed by gage's rates service, so with no signature it stops there.
    function test_borrowStopsAtTheSignedQuote() public {
        (uint256 tokenId, uint256 value) = _mintPosition(borrower);
        PositionFacts memory f = ILPAdapter(adapter).facts(tokenId);
        assertEq(f.pool, pool, "the adapter names the position's pool");
        assertEq(f.token0, weth);
        assertEq(f.token1, usdg);
        PoolConfig memory c = registry.poolConfig(adapter, pool);
        if (!c.allowed) vm.skip(true);
        assertGe(int256(f.tickUpper) - int256(f.tickLower), 2 * int256(uint256(c.minHalfWidthTicks)), "wide enough");

        vm.prank(borrower);
        nfpm.approve(address(core), tokenId);

        // A vault the registry allows, if a curator has opened one; the zero address otherwise.
        address vault = _firstAllowedVault();
        LoanQuote memory q = _quote(tokenId, f, value, vault);
        // Signed by a key of the reader's own: only the registry's quote signer (gage's rates service) is accepted.
        (, uint256 ownKey) = makeAddrAndKey("not the quote signer");
        bytes memory signature = _sign(ownKey, core.loanQuoteDigest(q));
        vm.prank(borrower);
        if (vault == address(0)) {
            // No LP vault funds loans yet: the core refuses the vault before it reads the signature.
            vm.expectRevert(abi.encodeWithSignature("VaultNotAllowed(address)", address(0)));
        } else {
            vm.expectRevert(abi.encodeWithSignature("InvalidSignature()"));
        }
        core.borrow(q, signature);
        assertEq(nfpm.ownerOf(tokenId), borrower, "nothing moved: the position is still the borrower's");
    }

    /// A whole loan, repaid before its end. Stand-ins for gage's parts are labelled.
    function test_loanRepaidAndPositionTakenBack() public {
        (address vault, uint256 signerKey) = _standInsAndVault();
        uint256 shares = _deposit(vault, 10_000e6);

        (uint256 tokenId, uint256 value) = _mintPosition(borrower);
        PositionFacts memory f = ILPAdapter(adapter).facts(tokenId);
        LoanQuote memory q = _quote(tokenId, f, value, vault);
        bytes memory signature = _sign(signerKey, core.loanQuoteDigest(q));

        // The borrower: approve the position to the core, borrow on the signed quote, take the USDG credit.
        vm.startPrank(borrower);
        nfpm.approve(address(core), tokenId);
        uint256 loanId = core.borrow(q, signature);
        uint256 fee = uint256(q.principal) * q.feeBps / 10_000;
        assertEq(core.credit(borrower, usdg), q.principal - fee, "credited the principal less the origination fee");
        assertEq(core.withdraw(usdg), q.principal - fee);
        vm.stopPrank();

        Loan memory l = core.loan(loanId);
        assertEq(uint8(l.state), uint8(LoanState.ACTIVE));
        assertEq(l.vault, vault);
        assertEq(l.pool, pool);
        assertEq(l.end, block.timestamp + q.term);
        assertEq(nfpm.ownerOf(tokenId), l.escrow, "the position waits in the loan's own escrow");

        // A day in: collect the position's fees (credited per token on the core), then repay before the end.
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(borrower);
        (uint256 fees0, uint256 fees1) = core.collectFees(loanId);
        console2.log("fees collected (raw WETH, raw USDG)", fees0, fees1);
        deal(usdg, borrower, IERC20(usdg).balanceOf(borrower) + (q.repayment - (q.principal - fee)));
        IERC20(usdg).approve(address(core), q.repayment);
        core.repay(loanId);
        core.returnPosition(loanId);
        vm.stopPrank();
        assertEq(uint8(core.loan(loanId).state), uint8(LoanState.REPAID));
        assertEq(nfpm.ownerOf(tokenId), borrower, "the position is back");

        // The lender: the loan's return accrues over its original term; redeem once it has run out.
        vm.warp(l.end);
        uint256 assets = ILPVault(vault).previewRedeem(shares);
        vm.prank(lender);
        uint256 paid = ILPVault(vault).redeem(shares, lender, lender, assets * 9_950 / 10_000);
        assertEq(paid, assets);
        assertGt(paid, 10_000e6, "the deposit came back with the loan's net return");
    }

    /// Not repaid by its end: after the late-unwind delay anyone settles it, the position's tokens go to the vault,
    /// the vault sells them on a signed sale quote, and what they bring above the loan's book value is its lenders'.
    function test_endOfTermUnwoundForTheVault() public {
        (address vault, uint256 signerKey) = _standInsAndVault();
        _deposit(vault, 10_000e6);
        (uint256 loanId, uint256 tokenId) = _openLoan(vault, signerKey);
        Loan memory l = core.loan(loanId);

        // At the end the loan is past its term: repaying is refused, and the vault waits on its settlement.
        vm.warp(l.end);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("PastTerm(uint256)", loanId));
        core.repay(loanId);
        assertTrue(ILPVault(vault).impaired(), "deposits, redemptions and funding wait for the settlement");

        // gage's keeper settles on an unwind quote from the end (`settleDefault`); without one, anyone may once
        // the late-unwind delay has passed, with no minimums.
        uint256 opensAt = uint256(l.end) + registry.lateUnwindDelay();
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSignature("LateUnwindNotOpen(uint256)", opensAt));
        core.settleDefaultLate(loanId);
        vm.warp(opensAt);
        vm.prank(anyone);
        core.settleDefaultLate(loanId);
        assertEq(uint8(core.loan(loanId).state), uint8(LoanState.DEFAULTED));
        assertEq(ILPAdapter(adapter).facts(tokenId).liquidity, 0, "the liquidity was removed into the vault");

        // The WETH waits in the vault as a lot until it is sold for USDG on a signed sale quote.
        uint256 out = _sellLot(vault, signerKey, loanId, weth);
        console2.log("WETH sold for (raw USDG)", out);
        assertEq(ILPVault(vault).lot(loanId, weth).amount, 0);
        assertFalse(ILPVault(vault).impaired(), "the vault takes deposits and pays out again");

        // The position was worth more than the loan: the rest is a bonus for the lenders who were in.
        uint256 bonus = ILPVault(vault).bonusClaimable(loanId, lender);
        console2.log("bonus claimable by the lender (raw USDG)", bonus);
        if (bonus != 0) {
            vm.prank(lender);
            assertEq(ILPVault(vault).claimBonus(loanId), bonus);
        }
    }

    // ---- helpers ------------------------------------------------------------------------------------------------

    /// @dev `lpLane.<list>[i].<field>`, a key `addressOf` and `has` read.
    function _key(string memory list, uint256 i, string memory field) internal pure returns (string memory) {
        return string.concat(list, "[", vm.toString(i), "].", field);
    }

    /// @dev The manifest's WETH/USDG 0.05% pool under the lane's first adapter (Uniswap v3's position manager).
    function _uniswapV3WethUsdg() internal view returns (address a, address p) {
        address v3 = addressOf("lpLane.adapters[0].address");
        for (uint256 i; has(_key("lpLane.pools", i, "pool")); ++i) {
            if (addressOf(_key("lpLane.pools", i, "adapter")) != v3) continue;
            if (addressOf(_key("lpLane.pools", i, "token0")) != weth) continue;
            if (addressOf(_key("lpLane.pools", i, "token1")) != usdg) continue;
            if (vm.parseJsonUint(manifest, string.concat(".", _key("lpLane.pools", i, "fee"))) != 500) continue;
            return (v3, addressOf(_key("lpLane.pools", i, "pool")));
        }
        revert("no Uniswap v3 WETH/USDG 0.05% pool in the manifest");
    }

    /// @dev The executor that sells `token` for USDG, and the pool it sells into.
    function _executorFor(address token) internal view returns (address executor, address executorPool) {
        for (uint256 i; has(_key("lpLane.executors", i, "address")); ++i) {
            if (addressOf(_key("lpLane.executors", i, "token")) != token) continue;
            return (
                addressOf(_key("lpLane.executors", i, "address")),
                addressOf(string.concat(_key("lpLane.executors", i, "pools"), "[0]"))
            );
        }
        revert("no executor for this token");
    }

    function _firstAllowedVault() internal view returns (address) {
        uint256 n = factory.vaultCount();
        address[] memory vaults = factory.vaultsFrom(0, n);
        for (uint256 i; i < vaults.length; ++i) {
            if (registry.vaultAllowed(vaults[i]) && ILPVault(vaults[i]).funds(adapter, pool)) return vaults[i];
        }
        return address(0);
    }

    /// @dev Deals `owner` 0.2 WETH and 1,000 USDG and mints a position about 10% either side of the pool's price.
    /// Returns its id and its worth in raw USDG at the pool's price (what the rates service would value).
    function _mintPosition(address owner) internal returns (uint256 tokenId, uint256 value) {
        (uint160 sqrtPriceX96, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 spacing = IUniswapV3Pool(pool).tickSpacing();
        int24 lower = (tick - 1000) / spacing * spacing;
        int24 upper = (tick + 1000) / spacing * spacing;
        deal(weth, owner, 0.2e18);
        deal(usdg, owner, 1_000e6);
        vm.startPrank(owner);
        IERC20(weth).approve(address(nfpm), 0.2e18);
        IERC20(usdg).approve(address(nfpm), 1_000e6);
        uint256 amount0;
        uint256 amount1;
        (tokenId,, amount0, amount1) = nfpm.mint(
            INonfungiblePositionManager.MintParams({
                token0: weth,
                token1: usdg,
                fee: 500,
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: 0.2e18,
                amount1Desired: 1_000e6,
                amount0Min: 0,
                amount1Min: 0,
                recipient: owner,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        value = amount1 + _token0InToken1(amount0, sqrtPriceX96);
    }

    /// @dev `amount0` of a pool's token0 in its token1 at `sqrtPriceX96` (raw units, rounded down).
    function _token0InToken1(uint256 amount0, uint160 sqrtPriceX96) internal pure returns (uint256) {
        return amount0 * sqrtPriceX96 / (1 << 96) * sqrtPriceX96 / (1 << 96);
    }

    /// @dev A quote as the rates service builds one: the position's exact range and liquidity, a loan at 90% of the
    /// registry's cap, a fixed cost of 0.50% of the principal for 7 days, the registry's fee, two minutes to use it.
    function _quote(uint256 tokenId, PositionFacts memory f, uint256 value, address vault)
        internal
        returns (LoanQuote memory q)
    {
        PoolConfig memory c = registry.poolConfig(adapter, pool);
        uint128 principal = uint128(value * registry.ltvCapBps() * 9 / 100_000);
        if (principal < c.minLoanPrincipal) vm.skip(true);
        // Field by field: a struct literal this wide is too deep for the default compiler settings.
        q.borrower = borrower;
        q.vault = vault;
        q.adapter = adapter;
        q.tokenId = tokenId;
        q.liquidity = f.liquidity;
        q.tickLower = f.tickLower;
        q.tickUpper = f.tickUpper;
        q.collateralValue = uint128(value);
        q.principal = principal;
        q.repayment = principal + principal * 50 / 10_000;
        q.term = registry.termAllowed(7 days) ? 7 days : registry.terms()[0];
        q.feeBps = registry.feeBps();
        q.deadline = uint64(block.timestamp + 120);
    }

    /// @dev The two stand-ins for gage's parts, then a vault opened by the reader's own curator wallet.
    function _standInsAndVault() internal returns (address vault, uint256 signerKey) {
        if (registry.newLoansPaused()) vm.skip(true);
        address signer;
        (signer, signerKey) = makeAddrAndKey("stand-in rates signer");
        address owner = registry.owner();
        // Stand-in for gage's registry owner: it names the test key as the quote signer (on mainnet it is gage's
        // rates service's key) and allows the curator (on mainnet it allows curators one by one).
        vm.startPrank(owner);
        registry.setQuoteSigner(signer);
        registry.setCurator(curator, true);
        vm.stopPrank();

        // The curator: one vault, a 10% performance fee, loans up to 1,000 USDG, the one pool in its mandate.
        PoolRef[] memory pools = new PoolRef[](1);
        pools[0] = PoolRef({adapter: adapter, pool: pool});
        vm.prank(curator);
        vault = factory.create("Example WETH/USDG LP vault", 1_000, 1_000e6, pools);
        assertTrue(registry.vaultAllowed(vault), "the factory's vaults fund loans unless the owner removes one");
        assertTrue(ILPVault(vault).funds(adapter, pool), "a pool named at creation funds at once");
        assertEq(ILPVault(vault).decimals(), 18, "gLP shares have 18 decimals");
    }

    /// @dev The lender deposits `assets` USDG, at most 0.5% fewer shares than previewed.
    function _deposit(address vault, uint256 assets) internal returns (uint256 shares) {
        deal(usdg, lender, assets);
        uint256 minShares = ILPVault(vault).previewDeposit(assets) * 9_950 / 10_000;
        vm.startPrank(lender);
        IERC20(usdg).approve(vault, assets);
        shares = ILPVault(vault).deposit(assets, lender, minShares);
        vm.stopPrank();
        assertEq(ILPVault(vault).balanceOf(lender), shares);
    }

    /// @dev The borrower mints a position, borrows on a quote the stand-in key signed and takes the USDG.
    function _openLoan(address vault, uint256 signerKey) internal returns (uint256 loanId, uint256 tokenId) {
        uint256 value;
        (tokenId, value) = _mintPosition(borrower);
        LoanQuote memory q = _quote(tokenId, ILPAdapter(adapter).facts(tokenId), value, vault);
        bytes memory signature = _sign(signerKey, core.loanQuoteDigest(q));
        vm.startPrank(borrower);
        nfpm.approve(address(core), tokenId);
        loanId = core.borrow(q, signature);
        core.withdraw(usdg);
        vm.stopPrank();
    }

    /// @dev Sells a defaulted loan's whole lot of `token` through its executor, at most 5% under the executor pool's
    /// price. Stand-in for gage's rates service: the test key signs the sale's floor. gage's keeper submits it; so may
    /// anyone holding the signed quote.
    function _sellLot(address vault, uint256 signerKey, uint256 loanId, address token) internal returns (uint256) {
        Lot memory lot = ILPVault(vault).lot(loanId, token);
        assertGt(lot.amount, 0);
        (address executor, address executorPool) = _executorFor(token);
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(executorPool).slot0();
        SaleQuote memory s;
        s.vault = vault;
        s.loanId = loanId;
        s.token = token;
        s.amountIn = lot.amount;
        s.minOut = _token0InToken1(lot.amount, sqrtPriceX96) * 9_500 / 10_000;
        s.executor = executor;
        s.deadline = uint64(block.timestamp + 120);
        bytes memory signature = _sign(signerKey, ILPVault(vault).saleQuoteDigest(s));
        vm.prank(anyone);
        return ILPVault(vault).sell(s, signature);
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}

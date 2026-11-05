// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Borrowing directly against gage's USDG core on a fork of Robinhood Chain mainnet: approve an admitted token, list
// it, check the listing waits for funding, cancel it and take the collateral back; then, where a loan is running,
// repay it as the holder of its reclaim right and take its collateral back. Funding a listing is gage's part (its
// keeper fills it through the fill router on a plan its rates service signs), so this example never funds one: it
// shows that a wallet cannot.
//
//   cd examples/foundry && forge test --match-path test/Borrowing.t.sol -vv
//
// See docs/integrate/borrowing.md.

import {MainnetFork} from "./MainnetFork.sol";
import {console} from "forge-std/console.sol";

/// @dev `kind` 0 is an ERC-20, the only kind the token-only cores take; `amountOrTokenId` is in raw token units.
struct Collateral {
    uint8 kind;
    address token;
    uint256 amountOrTokenId;
}

struct V2Loan {
    address originator;
    address account;
    address token;
    address collateralBeneficiary;
    uint8 kind;
    uint8 state;
    uint8 filled;
    uint32 term;
    uint40 fundingDeadline;
    uint40 fundedAt;
    uint40 closedAt;
    uint128 principal;
    uint128 cap;
    uint128 originationFee;
    uint128 borrowerReward;
    uint128 lenderReward;
    uint256 collateral;
    bytes32 exposureKey;
    uint256 exposureAmount;
}

struct ERC20Config {
    bool allowed;
    uint8 lane;
    uint256 minAmount;
    uint256 maxDealRaw;
    uint256 maxOpenRaw;
}

/// @dev The parts of src/v2/GageV2Vault.sol this example calls, signatures as in the source.
interface ICore {
    error NotAuthorized();

    function list(
        Collateral calldata c,
        uint128 principal,
        uint128 cap,
        uint32 term,
        uint40 fundingDeadline,
        bool withRewards
    ) external returns (uint256 id);
    function fund(uint256 id, uint8 units) external;
    function cancelFunding(uint256 id) external;
    function reclaim(uint256 id, address recipient) external;
    function withdrawCollateral(uint256 id, address recipient) external;
    function getLoan(uint256 id) external view returns (V2Loan memory);
    function loanCount() external view returns (uint256);
    function lenders(uint256 id) external view returns (address[4] memory);
    function cashCredit(address account) external view returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
    function openExposure(bytes32 key) external view returns (uint256);
    function USDG() external view returns (address);
    function REGISTRY() external view returns (address);
    function GRACE() external view returns (uint32);
}

interface IRegistry {
    function getERC20Config(address token) external view returns (ERC20Config memory);
    function isTermAllowed(uint32 term) external view returns (bool);
    function feeBps() external view returns (uint16);
    function newDealsPaused() external view returns (bool);
}

/// @dev src/v2/GageV2Rewards.sol: the core asks it before recording any lender.
interface IRewards {
    error NotFunder();
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract BorrowingTest is MainnetFork {
    uint8 constant FUNDING = 1;
    uint8 constant ACTIVE = 2;
    uint8 constant REPAID = 3;
    uint8 constant CANCELLED = 5;

    /// List WETH on the USDG core, see it wait for funding, cancel it and withdraw the collateral.
    function test_listCancelAndWithdraw() public {
        ICore core = ICore(addressOf("intentV1.core"));
        IRegistry registry = IRegistry(core.REGISTRY());
        address weth = addressOf("WETH");
        ERC20Config memory cfg = registry.getERC20Config(weth);
        if (registry.newDealsPaused() || !cfg.allowed || !registry.isTermAllowed(7 days)) vm.skip(true);

        // Twice the token's minimum, within its per-loan cap and the room left under its open cap (raw units).
        uint256 amount = cfg.minAmount * 2;
        if (amount > cfg.maxDealRaw) amount = cfg.maxDealRaw;
        if (core.openExposure(keccak256(abi.encode(uint8(0), weth))) + amount > cfg.maxOpenRaw) vm.skip(true);
        // 100 USDG borrowed, 100.50 USDG to repay: a fixed cost of 0.50 USDG, 0.50% for 7 days. USDG has 6 decimals.
        uint128 principal = 100e6;
        uint128 cap = 100_500_000;
        uint40 deadline = uint40(block.timestamp + 1 days);

        address borrower = makeAddr("borrower");
        deal(weth, borrower, amount);
        uint256 expectedId = core.loanCount() + 1;

        vm.startPrank(borrower);
        IERC20(weth).approve(address(core), amount);
        uint256 id = core.list(Collateral(0, weth, amount), principal, cap, 7 days, deadline, false);
        vm.stopPrank();

        assertEq(id, expectedId, "ids run from 1, one per listing");
        V2Loan memory l = core.getLoan(id);
        assertEq(l.state, FUNDING, "waits for partner vaults");
        assertEq(l.originator, borrower);
        assertEq(l.filled, 0);
        assertEq(l.fundingDeadline, deadline);
        assertEq(l.originationFee, uint256(principal) * registry.feeBps() / 10_000, "fee fixed at listing");
        assertEq(core.ownerOf(id), borrower, "the reclaim right is minted to the borrower");
        assertEq(IERC20(weth).balanceOf(l.account), amount, "collateral sits in the loan's own account");
        assertEq(IERC20(weth).balanceOf(borrower), 0);

        // Only partner vaults lend on this core: a wallet's `fund` is refused by the core's rewards ledger.
        address lender = makeAddr("lender");
        vm.expectRevert(IRewards.NotFunder.selector);
        vm.prank(lender);
        core.fund(id, 4);

        // Before the funding deadline only the borrower may cancel; after it, anyone may.
        vm.expectRevert(ICore.NotAuthorized.selector);
        vm.prank(lender);
        core.cancelFunding(id);

        vm.startPrank(borrower);
        core.cancelFunding(id);
        l = core.getLoan(id);
        assertEq(l.state, CANCELLED);
        assertEq(l.collateralBeneficiary, borrower);
        // Pull, never push: the collateral waits until its beneficiary withdraws it.
        assertEq(IERC20(weth).balanceOf(borrower), 0);
        core.withdrawCollateral(id, borrower);
        vm.stopPrank();
        assertEq(IERC20(weth).balanceOf(borrower), amount, "the whole collateral is back");
    }

    /// Repay a running loan as the holder of its reclaim right: approve the cap, `reclaim`, then withdraw the
    /// collateral. The newest running loan of the USDG core, else of the previous USDG generation's core, which
    /// settles the loans it holds. Skips when neither has a loan running inside its window.
    function test_repayARunningLoan() public {
        string[2] memory keys = ["intentV1.core", "intentV1Previous[0].intentV1.core"];
        for (uint256 i; i < keys.length; ++i) {
            if (!has(keys[i])) continue;
            ICore core = ICore(addressOf(keys[i]));
            uint256 count = core.loanCount();
            for (uint256 id = count; id > 0 && id + 50 > count; --id) {
                V2Loan memory l = core.getLoan(id);
                if (l.state != ACTIVE || block.timestamp >= uint256(l.fundedAt) + l.term + core.GRACE()) continue;
                _repay(core, id, l);
                return;
            }
        }
        vm.skip(true);
    }

    function _repay(ICore core, uint256 id, V2Loan memory l) internal {
        // The holder of the reclaim right repays; it starts as the borrower and moves only through the core's sale.
        address holder = core.ownerOf(id);
        IERC20 asset = IERC20(core.USDG());
        address[4] memory slots = core.lenders(id);
        uint256[4] memory creditBefore;
        for (uint256 q; q < 4; ++q) {
            creditBefore[q] = core.cashCredit(slots[q]);
        }
        uint256 tokensBefore = IERC20(l.token).balanceOf(holder);
        console.log("repaying loan", id, "on core", address(core));
        console.log("  cap (raw)", l.cap);

        // Repaying takes exactly the cap, in the core's asset, from the caller.
        deal(address(asset), holder, l.cap);
        vm.startPrank(holder);
        asset.approve(address(core), l.cap);
        core.reclaim(id, holder);
        assertEq(core.getLoan(id).state, REPAID);
        assertEq(core.getLoan(id).collateralBeneficiary, holder);
        core.withdrawCollateral(id, holder);
        vm.stopPrank();

        assertEq(IERC20(l.token).balanceOf(holder) - tokensBefore, l.collateral, "the whole collateral is back");
        // Each lender's quarter of the cap is credited to it on the core, for it to withdraw.
        uint256 credited;
        for (uint256 q; q < 4; ++q) {
            bool first = true;
            for (uint256 p; p < q; ++p) {
                if (slots[p] == slots[q]) first = false;
            }
            if (first) credited += core.cashCredit(slots[q]) - creditBefore[q];
        }
        assertEq(credited, l.cap, "the lenders are credited the whole cap");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Lending through a gage partner vault, on a fork of Robinhood Chain mainnet: pick a live vault of the USDG factory,
// deposit USDG with a slippage bound, check the shares and `totalAssets`, redeem within `freeLiquidity`, and read the
// vault's mandate and its collateral list.
//
// Run from examples/foundry:
//   forge test --match-path test/PartnerVaults.t.sol -vv
//
// The depositor is a fresh address funded with `deal`. Nothing here acts for gage or for a vault's manager.
// A depositor may end up holding the collateral instead of USDG: a loan its vault funds may end with the borrower
// walking away, and the vault then holds the collateral.

import {MainnetFork} from "./MainnetFork.sol";
import {Vm} from "forge-std/Vm.sol";

interface IERC20Min {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @dev The part of `IntentFactory` (src/intent/IntentFactory.sol) used here.
interface IIntentFactoryMin {
    function count() external view returns (uint256);
    function vaults(uint256 index) external view returns (address);
    function isVault(address vault) external view returns (bool);
    function nameOf(address vault) external view returns (string memory);
    function CORE() external view returns (address);
}

/// @dev The part of `IntentVault` (src/intent/IntentVault.sol) used here. Enum arguments are `uint8` in the ABI.
interface IPartnerVault {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function freeLiquidity() external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function maxDeposit(address receiver) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function paused() external view returns (bool);
    function earliestMaturity() external view returns (uint40);
    function deposit(uint256 assets, uint256 minShares) external returns (uint256 shares);
    function redeem(uint256 shares, uint256 minAssets) external returns (uint256 assets);
    // The mandate and the manager's settings.
    function CURATOR() external view returns (address);
    function MAX_TERM() external view returns (uint32);
    function feeBps() external view returns (uint16);
    function CATEGORY_MASK() external view returns (uint8);
    function categoryWeightBps(uint8 category) external view returns (uint16);
    function MIN_GRADE_FLOOR() external view returns (uint8);
    function minGrade() external view returns (uint8);
    function minRateGrade() external view returns (uint8);
    function maxLoanPrincipal() external view returns (uint128);
    function maxAssetBps() external view returns (uint16);
    function bufferBps() external view returns (uint16);
    function executionCapBps() external view returns (uint16);
    function fillersOpen() external view returns (bool);
    function ASSET_POLICY() external view returns (address);
}

/// @dev The part of `IntentAssetPolicy` (src/intent/IntentAssetPolicy.sol) used here.
interface IAssetPolicyMin {
    function picked(address token) external view returns (bool);
    function SECONDARY_ONLY() external view returns (bool);
    function LIMIT_LOOSEN_DELAY() external view returns (uint256);
}

contract PartnerVaultsTest is MainnetFork {
    IIntentFactoryMin internal factory;
    IERC20Min internal usdg;
    address internal depositor;

    function setUp() public override {
        super.setUp();
        factory = IIntentFactoryMin(addressOf("intentV1.factory"));
        usdg = IERC20Min(addressOf("USDG"));
        depositor = makeAddr("depositor");
    }

    /// @dev The first vault of the USDG factory that takes deposits now: not paused, and no loan past its end waiting
    /// for `settle` (from `earliestMaturity()` until then, deposits and redemptions revert `SettlementDue`).
    function _liveVault() internal view returns (IPartnerVault) {
        uint256 n = factory.count();
        for (uint256 i; i < n; ++i) {
            IPartnerVault v = IPartnerVault(factory.vaults(i));
            if (!v.paused() && block.timestamp < v.earliestMaturity()) return v;
        }
        return IPartnerVault(address(0));
    }

    function test_DepositAndRedeemWithinFreeLiquidity() public {
        IPartnerVault v = _liveVault();
        if (address(v) == address(0)) {
            vm.skip(true); // no vault takes deposits right now
            return;
        }
        assertTrue(factory.isVault(address(v)));
        assertEq(v.asset(), address(usdg), "a USDG factory vault lends USDG");

        // 100 USDG in raw units (6 decimals). The smallest deposit is one whole unit of the asset, 1 USDG here.
        uint256 amount = 100 * 10 ** usdg.decimals();
        if (v.maxDeposit(depositor) < amount) {
            vm.skip(true);
            return;
        }
        deal(address(usdg), depositor, amount);

        uint256 assetsBefore = v.totalAssets();
        uint256 quoted = v.previewDeposit(amount);
        uint256 minShares = quoted - quoted * 50 / 10_000; // 0.5% slippage bound, as gage-sdk's default

        vm.startPrank(depositor);
        usdg.approve(address(v), amount);
        uint256 shares = v.deposit(amount, minShares);
        vm.stopPrank();

        assertEq(shares, quoted, "same block, same price");
        assertEq(v.balanceOf(depositor), shares);
        assertEq(v.totalAssets(), assetsBefore + amount, "a deposit adds its assets to cash");
        emit log_named_string("vault", factory.nameOf(address(v)));
        emit log_named_uint("shares minted (18 decimals)", shares);
        emit log_named_uint("raw USDG per whole share", v.convertToAssets(1e18));

        // Redeem what free liquidity covers: cash plus what the reserve can pay now. Lent principal stays in loans.
        uint256 toRedeem = v.maxRedeem(depositor);
        if (toRedeem > shares) toRedeem = shares;
        assertGt(toRedeem, 0);
        uint256 out = v.previewRedeem(toRedeem);
        assertLe(out, v.freeLiquidity(), "a redemption is paid from free liquidity only");
        uint256 minAssets = out - out * 50 / 10_000;

        vm.prank(depositor);
        uint256 paid = v.redeem(toRedeem, minAssets);

        assertEq(paid, out);
        assertEq(usdg.balanceOf(depositor), paid);
        if (toRedeem == shares) assertApproxEqAbs(paid, amount, 1, "the round trip loses at most a raw unit");
    }

    function test_ReadMandate() public {
        IPartnerVault v = _liveVault();
        if (address(v) == address(0)) {
            vm.skip(true);
            return;
        }
        // Bounds the vault's constructor and its asset policy hold every setting to.
        uint16 fee = v.feeBps();
        assertGe(fee, 500);
        assertLe(fee, 1500);
        assertLe(v.executionCapBps(), 5000);
        assertLe(v.minRateGrade(), 4); // 0 none, 1 D, 2 C, 3 B, 4 A
        assertLe(v.minGrade(), 10); // collateral grade rank, 0 none to 10 AAA
        assertGe(v.minGrade(), v.MIN_GRADE_FLOOR());
        assertLe(v.maxAssetBps(), 10_000);
        assertLe(v.bufferBps(), 10_000);
        assertLe(uint256(v.maxLoanPrincipal()), 1_000_000_000 * 10 ** usdg.decimals());

        // One universe: STOCK (bit 0) and COMMODITY (bit 3), or MEME (bit 1) and RH_ECOSYSTEM (bit 2).
        uint8 mask = v.CATEGORY_MASK();
        bool rwa = mask & 0x09 != 0;
        bool rhEco = mask & 0x06 != 0;
        assertTrue(rwa != rhEco, "a vault lends against one universe");
        for (uint8 c; c < 4; ++c) {
            if (mask & (1 << c) == 0) {
                assertEq(v.categoryWeightBps(c), 0, "a category outside the universe stays closed");
            }
        }

        IAssetPolicyMin policy = IAssetPolicyMin(v.ASSET_POLICY());
        assertEq(policy.LIMIT_LOOSEN_DELAY(), 3 hours);

        emit log_named_string("vault", factory.nameOf(address(v)));
        emit log_named_address("curator", v.CURATOR());
        emit log_named_uint("longest term (s)", v.MAX_TERM());
        emit log_named_uint("performance fee (bps)", fee);
        emit log_named_uint("category mask", mask);
        emit log_named_uint("Loan grade floor", v.minRateGrade());
        emit log_named_uint("most per loan (raw USDG)", v.maxLoanPrincipal());
        emit log_named_uint("most per token (bps)", v.maxAssetBps());
        emit log_named_uint("cash kept free (bps)", v.bufferBps());
        emit log_named_uint("execution cap (bps of a purchase's return)", v.executionCapBps());
        emit log_named_string("funds new listings", policy.SECONDARY_ONLY() ? "no (buys running loans only)" : "yes");

        // The collateral list: `AssetSet(token, true)` at creation or on activation, `AssetSet(token, false)` on
        // removal. `picked(token)` on the asset policy is the current answer.
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("AssetSet(address,bool)");
        uint256 from = vm.parseJsonUint(manifest, ".intentV1.startBlock");
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(from, block.number, address(v), topics);
        uint256 picked;
        for (uint256 i; i < logs.length; ++i) {
            address token = address(uint160(uint256(logs[i].topics[1])));
            if (abi.decode(logs[i].data, (bool)) && policy.picked(token)) {
                ++picked;
                emit log_named_address("lends against", token);
            }
        }
        emit log_named_uint("tokens picked", picked);
    }
}

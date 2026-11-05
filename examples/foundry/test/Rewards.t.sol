// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// What it shows: sGAGE rewards on loans. Each core has its own rewards ledger (`GageV2Rewards`): the USDG core's is
// backed by its legacy adapter, the lend-asset cores' are unbridged and reached by a rewards bridge
// (`LendRewardsBridge`), which each generation's fee processor forwards its fees to. The tests read each ledger and
// bridge, follow a live loan's allocation along its quadratic clock, and claim a partner vault's sGAGE as a depositor
// of the reader's own. The bridges are found from the manifest's fee processors (`forwardTo()`), not hard-coded.
// Run from examples/foundry: forge test --match-path test/Rewards.t.sol -vv

import {console2} from "forge-std/console2.sol";
import {MainnetFork} from "./MainnetFork.sol";

/// @dev The parts of `src/v2/GageV2Rewards.sol` this example uses.
interface IGageV2Rewards {
    struct Allocation {
        address borrower;
        uint40 start;
        uint40 end;
        uint32 term;
        uint128 borrowerTotal;
        uint128 lenderTotal;
        uint128 borrowerAccounted;
        address[4] lenders;
    }

    error InvalidTransfer();

    function VAULT() external view returns (address);
    function SGAGE() external view returns (address);
    function BRIDGE() external view returns (address);
    function freeBudget() external view returns (uint256);
    function funderGate() external view returns (address);
    function fund(uint256 amount) external;
    function allocation(uint256 id) external view returns (Allocation memory);
    function claimable(uint256 id, address account) external view returns (uint256);
    function claim(uint256 id, address recipient) external;
}

/// @dev The parts of `src/v2/GageV2Vault.sol` (a core) this example uses; `V2Loan` as in `src/v2/V2Types.sol`.
interface ICore {
    enum Kind {
        ERC20,
        UNIV4_POSITION,
        UNIV3_POSITION
    }

    enum V2State {
        NONE,
        FUNDING,
        ACTIVE,
        REPAID,
        DEFAULTED,
        CANCELLED
    }

    struct V2Loan {
        address originator;
        address account;
        address token;
        address collateralBeneficiary;
        Kind kind;
        V2State state;
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

    function REWARDS() external view returns (address);
    function BRIDGE() external view returns (address);
    function loanCount() external view returns (uint256);
    function getLoan(uint256 id) external view returns (V2Loan memory);
}

/// @dev The parts of `src/intent/LendRewardsBridge.sol` this example uses.
interface ILendRewardsBridge {
    error NotKeeper(address caller);

    function CORE() external view returns (address);
    function CORE_REWARDS() external view returns (address);
    function USDG() external view returns (address);
    function SGAGE() external view returns (address);
    function VAULT() external view returns (address);
    function REWARDS() external view returns (address);
    function DRIP() external view returns (address);
    function FEE_ROUTER() external view returns (address);
    function LENDER() external view returns (address);
    function batchCount() external view returns (uint256);
    function availableUSDG() external view returns (uint256);
    function mirrorBudget(uint256 weight) external view returns (uint256);
    function mirror(uint256[] calldata loanIds, uint256 minReward) external returns (uint256 firstBatch);
    function payVault(uint256 batchId, address vault) external returns (uint256 amount);
    function claim(uint256[] calldata batchIds, address to) external returns (uint256 total);
}

/// @dev The fee processor's forward target: `DealFeeRouter`, or the generation's rewards bridge once it is wired.
interface IFeeProcessor {
    function forwardTo() external view returns (address);
}

/// @dev The parts of `src/intent/IntentVault.sol` (a partner vault) this example uses.
interface IPartnerVault {
    function PROTOCOL_SOURCE() external view returns (address);
    function deposit(uint256 assets, uint256 minShares) external returns (uint256 shares);
    function harvestRewards(uint256[] calldata ids) external;
    function rewardClaimable(address who) external view returns (uint256);
    function claimRewards() external returns (uint256 amount);
    function earliestMaturity() external view returns (uint40);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract RewardsTest is MainnetFork {
    /// The USDG core's ledger: created by the core, backed by its legacy adapter (`BRIDGE`), lending only to the USDG
    /// factory's vaults. A bridged ledger keeps no budget of its own and refuses donations.
    function test_usdgCoreLedgerIsBridged() public {
        address core = addressOf("intentV1.core");
        IGageV2Rewards ledger = IGageV2Rewards(ICore(core).REWARDS());
        uint256 i = _engineIndex(core);
        string memory at = string.concat("nativeV2.engines[", vm.toString(i), "]");
        assertEq(address(ledger), addressOf(string.concat(at, ".rewards")), "manifest rewards");
        assertEq(ledger.VAULT(), core);
        assertEq(ledger.SGAGE(), addressOf("sGAGE"));
        assertEq(ledger.BRIDGE(), ICore(core).BRIDGE());
        assertEq(ledger.BRIDGE(), addressOf(string.concat(at, ".bridge")), "legacy adapter");
        assertEq(ledger.freeBudget(), 0);
        assertEq(ledger.funderGate(), addressOf("intentV1.factory"), "only the factory's vaults lend");

        deal(addressOf("sGAGE"), address(this), 1e18);
        IERC20(addressOf("sGAGE")).approve(address(ledger), 1e18);
        vm.expectRevert(IGageV2Rewards.InvalidTransfer.selector);
        ledger.fund(1e18);
    }

    /// Each lend-asset core's ledger is unbridged; its funder gate is the generation's factory.
    function test_lendAssetLedgers() public view {
        string[] memory symbols = vm.parseJsonKeys(manifest, ".intentV1Assets");
        for (uint256 s; s < symbols.length; ++s) {
            string memory at = string.concat("intentV1Assets.", symbols[s]);
            address core = addressOf(string.concat(at, ".core"));
            IGageV2Rewards ledger = IGageV2Rewards(addressOf(string.concat(at, ".engine.rewards")));
            assertEq(ICore(core).REWARDS(), address(ledger), symbols[s]);
            assertEq(ledger.BRIDGE(), address(0), "unbridged");
            assertEq(ledger.funderGate(), addressOf(string.concat(at, ".factory")), "funder gate");
            console2.log(symbols[s], "ledger free budget (raw sGAGE):", ledger.freeBudget());
        }
    }

    /// The rewards bridges: one per lend-asset core, found as its fee processor's forward target. Only gage's keeper
    /// mirrors loans and pays vaults; borrowers claim their own part of each batch.
    function test_rewardsBridges() public {
        string[] memory symbols = vm.parseJsonKeys(manifest, ".intentV1Assets");
        for (uint256 s; s < symbols.length; ++s) {
            string memory at = string.concat("intentV1Assets.", symbols[s]);
            address target = IFeeProcessor(addressOf(string.concat(at, ".feeProcessor"))).forwardTo();
            if (target == addressOf("DealFeeRouter")) {
                console2.log(symbols[s], "has no rewards bridge: fees go to DealFeeRouter");
                continue;
            }
            ILendRewardsBridge bridge = ILendRewardsBridge(target);
            assertEq(bridge.CORE(), addressOf(string.concat(at, ".core")), "core");
            assertEq(bridge.CORE_REWARDS(), addressOf(string.concat(at, ".engine.rewards")), "core ledger");
            assertEq(bridge.USDG(), addressOf("USDG"));
            assertEq(bridge.SGAGE(), addressOf("sGAGE"));
            assertEq(bridge.VAULT(), addressOf("DealVault"), "mirror deals on the V1 vault");
            assertEq(bridge.REWARDS(), addressOf("DealRewards"));
            assertEq(bridge.DRIP(), addressOf("Drip"));
            assertEq(bridge.FEE_ROUTER(), addressOf("DealFeeRouter"));
            assertGt(bridge.LENDER().code.length, 0, "the mirror deals' lender, created by the bridge");
            assertLe(bridge.mirrorBudget(1e18), bridge.availableUSDG(), "a call never spends more than is held");
            console2.log(symbols[s], "bridge:", target);
            console2.log("  batches:", bridge.batchCount(), "USDG waiting:", bridge.availableUSDG());

            // gage's keeper alone mirrors and pays vaults.
            uint256[] memory none = new uint256[](0);
            vm.expectRevert(abi.encodeWithSelector(ILendRewardsBridge.NotKeeper.selector, address(this)));
            bridge.mirror(none, 0);
            vm.expectRevert(abi.encodeWithSelector(ILendRewardsBridge.NotKeeper.selector, address(this)));
            bridge.payVault(1, address(this));
            // A borrower's claim names its batches; with none it pays nothing.
            assertEq(bridge.claim(none, address(this)), 0);
        }
    }

    /// A live loan's allocation, its quadratic clock, and what the borrower can still claim.
    function test_liveLoanAllocation() public {
        (ICore core, uint256 id) = _liveRewardedLoan();
        if (address(core) == address(0)) vm.skip(true);
        ICore.V2Loan memory loan = core.getLoan(id);
        IGageV2Rewards ledger = IGageV2Rewards(core.REWARDS());
        IGageV2Rewards.Allocation memory a = ledger.allocation(id);
        assertEq(a.start, loan.fundedAt, "starts at activation");
        assertEq(a.term, loan.term);
        assertEq(a.borrowerTotal, loan.borrowerReward);
        assertEq(a.lenderTotal, loan.lenderReward);
        assertEq(a.end, 0, "still running");

        uint256 elapsed = block.timestamp - a.start;
        uint256 earned = _curve(a.borrowerTotal, elapsed, a.term);
        uint256 now_ = ledger.claimable(id, a.borrower);
        assertLe(now_, earned, "claimable never exceeds the curve");
        console2.log("loan", id, "on core", address(core));
        console2.log("  borrower earned so far (raw sGAGE):", earned, "of", a.borrowerTotal);

        // At the end of the term the whole allocation has accrued: the borrower's claimable rises by exactly the rest.
        vm.warp(uint256(a.start) + a.term);
        assertEq(ledger.claimable(id, a.borrower) - now_, a.borrowerTotal - earned, "quadratic clock");
    }

    /// A depositor of a partner vault claims the vault's sGAGE: deposit, wait, harvest (anyone), `claimRewards`.
    function test_claimAsVaultDepositor() public {
        (ICore core, uint256 id) = _liveRewardedLoan();
        if (address(core) == address(0)) vm.skip(true);
        IGageV2Rewards ledger = IGageV2Rewards(core.REWARDS());
        IPartnerVault vault = IPartnerVault(ledger.allocation(id).lenders[0]);
        if (address(vault).code.length == 0) vm.skip(true);
        try vault.PROTOCOL_SOURCE() returns (address) {}
        catch {
            vm.skip(true);
        }

        address usdg = addressOf("USDG");
        uint256 assets = 1_000e6; // 1,000 USDG, raw six-decimal units
        deal(usdg, address(this), assets);
        IERC20(usdg).approve(address(vault), assets);
        try vault.deposit(assets, 1) {}
        catch { // paused, settling or full: nothing to show
            vm.skip(true);
        }

        // Stay before the vault's next loan end, when share moves stop until `settle`.
        uint256 wait = (uint256(vault.earliestMaturity()) - block.timestamp) / 2;
        if (wait > 1 days) wait = 1 days;
        vm.warp(block.timestamp + wait);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vault.harvestRewards(ids);
        uint256 owed = vault.rewardClaimable(address(this));
        if (owed == 0) vm.skip(true);

        uint256 before = IERC20(addressOf("sGAGE")).balanceOf(address(this));
        assertEq(vault.claimRewards(), owed);
        assertEq(IERC20(addressOf("sGAGE")).balanceOf(address(this)) - before, owed);
        console2.log("claimed (raw sGAGE) after", wait, "seconds:", owed);
    }

    // ------------------------------------------------------------------ helpers

    /// The manifest's `nativeV2.engines` entry for `core`.
    function _engineIndex(address core) internal view returns (uint256 i) {
        for (;; ++i) {
            string memory key = string.concat("nativeV2.engines[", vm.toString(i), "].engine");
            require(has(key), "core not in nativeV2.engines");
            if (addressOf(key) == core) return i;
        }
    }

    /// The newest ACTIVE loan with a lender reward, on the newest core of `nativeV2.engines` that has one.
    function _liveRewardedLoan() internal view returns (ICore core, uint256 id) {
        uint256 n;
        while (has(string.concat("nativeV2.engines[", vm.toString(n), "].engine"))) ++n;
        for (uint256 e = n; e > 0; --e) {
            core = ICore(addressOf(string.concat("nativeV2.engines[", vm.toString(e - 1), "].engine")));
            uint256 count = core.loanCount();
            for (uint256 j = count; j > 0 && j + 64 > count; --j) {
                ICore.V2Loan memory l = core.getLoan(j);
                if (l.state == ICore.V2State.ACTIVE && l.lenderReward != 0 && block.timestamp < l.fundedAt + l.term) {
                    return (core, j);
                }
            }
        }
        return (ICore(address(0)), 0);
    }

    /// `GageV2Rewards._curve`: amount * min(elapsed, term)^2 / term^2.
    function _curve(uint256 amount, uint256 elapsed, uint256 term) internal pure returns (uint256) {
        if (elapsed > term) elapsed = term;
        return amount * elapsed * elapsed / (term * term);
    }
}

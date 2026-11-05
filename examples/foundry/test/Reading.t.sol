// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Reading gage's cores on a fork of Robinhood Chain mainnet: where each core is in the manifest, its loan count, the
// latest loan's record, and its registry's settings for one token. Read-only: nothing is sent.
//
//   cd examples/foundry && forge test --match-path test/Reading.t.sol -vv
//
// See docs/integrate/reading.md.

import {MainnetFork} from "./MainnetFork.sol";
import {console} from "forge-std/console.sol";

/// @dev `Collateral.kind` and `V2Loan.kind`: 0 is an ERC-20, the only kind the token-only cores take.
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

/// @dev `ICollateralRegistry.ERC20Config`; `lane` is 0 STOCK, 1 ETH, 2 MEME and is informational only.
struct ERC20Config {
    bool allowed;
    uint8 lane;
    uint256 minAmount;
    uint256 maxDealRaw;
    uint256 maxOpenRaw;
}

/// @dev The parts of src/v2/GageV2Vault.sol this example reads.
interface ICore {
    function loanCount() external view returns (uint256);
    function getLoan(uint256 id) external view returns (V2Loan memory);
    function lenders(uint256 id) external view returns (address[4] memory);
    function USDG() external view returns (address);
    function REGISTRY() external view returns (address);
    function REWARDS() external view returns (address);
    function GRACE() external view returns (uint32);
}

/// @dev The parts of src/v2/GageV2TokenRegistry.sol this example reads.
interface IRegistry {
    function getERC20Config(address token) external view returns (ERC20Config memory);
    function allowedTerms() external view returns (uint32[] memory);
    function feeBps() external view returns (uint16);
    function newDealsPaused() external view returns (bool);
}

interface IERC20Metadata {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

contract ReadingTest is MainnetFork {
    uint8 constant FUNDING = 1;
    uint8 constant ACTIVE = 2;
    uint8 constant REPAID = 3;
    uint8 constant DEFAULTED = 4;
    uint8 constant CANCELLED = 5;

    /// The USDG core is `intentV1.core`, also the newest entry of `nativeV2.engines`; each lend asset's core is
    /// `intentV1Assets.<SYMBOL>.core`, and its `USDG()` returns the asset it lends.
    function test_findTheCores() public view {
        ICore usdgCore = ICore(addressOf("intentV1.core"));
        assertEq(usdgCore.USDG(), addressOf("USDG"), "the USDG core lends USDG");
        assertEq(usdgCore.GRACE(), 0, "repayment closes at the end of the term");

        // The engines list runs oldest first; the newest is the core new USDG loans are listed on.
        uint256 n;
        while (has(string.concat("nativeV2.engines[", vm.toString(n), "].engine"))) ++n;
        assertGt(n, 0);
        string memory newest = string.concat("nativeV2.engines[", vm.toString(n - 1), "]");
        assertEq(addressOf(string.concat(newest, ".engine")), address(usdgCore), "newest engine is intentV1.core");
        assertEq(addressOf(string.concat(newest, ".registry")), usdgCore.REGISTRY());
        assertEq(addressOf(string.concat(newest, ".rewards")), usdgCore.REWARDS());

        ICore nvdaCore = ICore(addressOf("intentV1Assets.NVDA.core"));
        assertEq(nvdaCore.USDG(), addressOf("intentV1Assets.NVDA.lendAsset.token"), "the NVDA core lends NVDA");
        assertEq(nvdaCore.REGISTRY(), addressOf("intentV1Assets.NVDA.engine.registry"));
        assertEq(nvdaCore.REWARDS(), addressOf("intentV1Assets.NVDA.engine.rewards"));
        console.log("USDG core", address(usdgCore), "loans", usdgCore.loanCount());
        console.log("NVDA core", address(nvdaCore), "loans", nvdaCore.loanCount());
    }

    /// The latest loan of the USDG core, the NVDA core and the previous USDG generation's core, whichever have one.
    /// Ids run from 1 to `loanCount()` on each core, cancelled and closed loans included.
    function test_latestLoan() public {
        string[3] memory keys = [
            "intentV1.core",
            "intentV1Assets.NVDA.core",
            // An earlier USDG core: it takes no new loans and settles the ones it holds.
            "intentV1Previous[0].intentV1.core"
        ];
        uint256 read;
        for (uint256 i; i < keys.length; ++i) {
            if (!has(keys[i])) continue;
            ICore core = ICore(addressOf(keys[i]));
            uint256 id = core.loanCount();
            if (id == 0) {
                console.log("no loan yet on", address(core));
                continue;
            }
            _check(core, id, core.getLoan(id));
            ++read;
        }
        if (read == 0) vm.skip(true);
    }

    /// A token's admission on a core's registry, the terms it allows and its fee. The registry is the core's
    /// `REGISTRY()`; its settings gate new listings and fundings only, never a loan already open.
    function test_registryConfig() public view {
        _registry(ICore(addressOf("intentV1.core")), addressOf("WETH"));
        // The tokens a lend asset's generation lends against are its `collateral` list in the manifest.
        _registry(ICore(addressOf("intentV1Assets.NVDA.core")), addressOf("intentV1Assets.NVDA.collateral[0].token"));
    }

    function _check(ICore core, uint256 id, V2Loan memory l) internal view {
        uint8 decimals = IERC20Metadata(core.USDG()).decimals();
        console.log("core", address(core), "loan", id);
        console.log("  state", l.state, "term (s)", l.term);
        console.log("  principal (raw)", l.principal, "decimals", decimals);
        console.log("  cap (raw)", l.cap);
        console.log("  collateral (raw)", l.collateral, IERC20Metadata(l.token).symbol());

        assertTrue(l.state >= FUNDING && l.state <= CANCELLED, "a listed loan is never NONE");
        assertEq(l.kind, 0, "token collateral");
        assertGe(l.principal, 4, "four lender quarters");
        assertGe(l.cap, l.principal, "the cap repays at least the principal");
        assertTrue(l.account != address(0), "every loan has its own collateral account");
        // The fee is fixed at listing from the registry's feeBps, at most 2%.
        assertLe(uint256(l.originationFee) * 10_000, uint256(l.principal) * 200);

        if (l.state == FUNDING) {
            assertEq(l.fundedAt, 0);
            assertEq(l.closedAt, 0);
        } else if (l.state == ACTIVE) {
            assertEq(l.filled, 4, "all four quarters sold");
            assertGt(l.fundedAt, 0);
            assertEq(l.closedAt, 0);
            console.log("  repayment closes at", uint256(l.fundedAt) + l.term + core.GRACE());
            address[4] memory slots = core.lenders(id);
            for (uint256 q; q < 4; ++q) {
                assertTrue(slots[q] != address(0), "every quarter has a lender");
            }
        } else if (l.state == REPAID || l.state == DEFAULTED) {
            assertGt(l.fundedAt, 0);
            assertGe(l.closedAt, l.fundedAt);
        } else {
            // CANCELLED: never funded, the collateral is the borrower's to withdraw.
            assertEq(l.fundedAt, 0);
            assertEq(l.collateralBeneficiary, l.originator);
        }
    }

    function _registry(ICore core, address token) internal view {
        IRegistry registry = IRegistry(core.REGISTRY());
        ERC20Config memory cfg = registry.getERC20Config(token);
        uint32[] memory terms = registry.allowedTerms();
        console.log("registry", address(registry), "token", IERC20Metadata(token).symbol());
        console.log("  allowed", cfg.allowed, "lane", cfg.lane);
        console.log("  minimum (raw)", cfg.minAmount);
        console.log("  fee (bps)", registry.feeBps(), "new loans paused", registry.newDealsPaused());

        // The registry's own bounds: at most 2% fee, one to eight terms of 1 to 30 days.
        assertLe(registry.feeBps(), 200);
        assertTrue(terms.length >= 1 && terms.length <= 8);
        for (uint256 i; i < terms.length; ++i) {
            assertTrue(terms[i] >= 1 days && terms[i] <= 30 days);
            console.log("  term (s)", terms[i]);
        }
        if (cfg.allowed) {
            assertGt(cfg.minAmount, 0);
            assertGe(cfg.maxDealRaw, cfg.minAmount);
            assertGe(cfg.maxOpenRaw, cfg.maxDealRaw);
        }
    }
}

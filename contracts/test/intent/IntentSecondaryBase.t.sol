// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IntentPlanBaseTest} from "./IntentPlanBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentPreflight} from "./IntentPreflight.sol";
import {IntentAssetPolicy} from "../../src/intent/IntentAssetPolicy.sol";
import {IntentLenderMarket} from "../../src/intent/IntentLenderMarket.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {V2Loan, V2LenderAsk} from "../../src/v2/V2Types.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {remainingLenderReward} from "../helpers/RemainingReward.sol";

using {remainingLenderReward} for GageV2Rewards;

/// @notice S9 planning helpers: a seller vault holding a whole loan, three opted-in buyer vaults too small to take the
/// whole listing alone, and the plan an honest signer would produce. Model rates, ceilings, prices and deposits are
/// fixture values, not launch values. The concrete fixture names the router.
abstract contract IntentSecondaryPlanner is IntentPlanBaseTest {
    /// @dev The model's annual requirement for the fixture position, and the buyers' own extra.
    uint32 internal constant MODEL_BPS = 1000;
    uint16 internal constant EXTRA_BPS = 300;
    uint16 internal constant BUY_CAP_BPS = 2000;

    /// @dev The model requirement the fixture signer uses; tests raise it to exercise the floor.
    uint32 internal modelBps = MODEL_BPS;
    address internal payout = address(0xFA11);
    IntentVault internal buyerA;
    IntentVault internal buyerB;
    IntentVault internal buyerC;
    IntentVault internal seller;
    IntentLenderMarket internal sellerMarket;
    /// @dev Who runs the three buyers: never the seller's curator, whose own vaults the verifier refuses as buyers
    /// (L-01).
    address internal buyerCurator;

    /// @dev The seller and three buyers; call once the factory, verifier and router stand.
    function _standSecondary() internal {
        seller = first;
        sellerMarket = seller.LENDER_MARKET();
        buyerCurator = makeAddr("buyer curator");
        buyerA = _buyer(600e6);
        buyerB = _buyer(300e6);
        buyerC = _buyer(300e6);
    }

    // ---------------------------------------------------------------- fixture

    function _buyer(uint256 deposit) internal returns (IntentVault vault) {
        return _buyerRunBy(buyerCurator, deposit);
    }

    /// @dev A vault run by `who`, admitted as a creator if it is not, buying existing positions from the start and
    /// holding `deposit` of carol's.
    function _buyerRunBy(address who, uint256 deposit) internal returns (IntentVault vault) {
        if (!partnerFactory.isCreator(who)) partnerFactory.setCreator(who, true);
        mandate.curator = who;
        mandate.feeBps = 1000;
        mandate.minRateGrade = 0;
        mandate.executionCapBps = BUY_CAP_BPS;
        vm.prank(who);
        vault = IntentVault(partnerFactory.create(mandate, true, EXTRA_BPS, "Test vault"));
        mandate.curator = curator;
        vm.prank(carol);
        usdg.approve(address(vault), MAX);
        vm.prank(carol);
        vault.deposit(deposit, 0);
    }

    /// @dev The fill router the fixture deploys.
    function _secondaryRouter() internal view virtual returns (IntentFillRouter);

    /// @dev A review loan funded whole by the seller vault, three days into its term, listed for `price`.
    function _onSale(uint128 price) internal returns (uint256 id) {
        // Modeled costs are published with a lifetime; the seller's origination needs a fresh one.
        _modeled(address(nvda), COST_BPS);
        id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(seller, 4);
        _fill(_plan(id, vaults, counts));
        vm.warp(_startOf(id) + 3 days);
        uint40 deadline = uint40(_maturity(id));
        vm.prank(curator);
        sellerMarket.list(id, price, deadline, 100);
    }

    function _twoOneOne() internal view returns (IntentVault[] memory vaults, uint8[] memory masks) {
        vaults = new IntentVault[](3);
        masks = new uint8[](3);
        (vaults[0], masks[0]) = (buyerA, 5);
        (vaults[1], masks[1]) = (buyerB, 2);
        (vaults[2], masks[2]) = (buyerC, 8);
    }

    /// @dev The plan an honest signer would produce for the seller vault's market listing now.
    function _marketPlan(uint256 id, IntentVault[] memory vaults, uint8[] memory masks)
        internal
        view
        returns (IntentQuoteVerifier.SecondaryPlan memory p)
    {
        (uint128 price,,, uint8 slots, uint64 nonce) = sellerMarket.asks(id);
        p.seller = address(seller);
        p.market = address(sellerMarket);
        p.slots = slots;
        p.price = price;
        p.nonce = nonce;
        p.maxFeeBps = 100;
        _complete(p, id, vaults, masks);
    }

    /// @dev The plan for a wallet's native core ask, a listing the verifier refuses (`MARKET_MISMATCH`).
    function _askPlan(uint256 id, address wallet, IntentVault[] memory vaults, uint8[] memory masks)
        internal
        view
        returns (IntentQuoteVerifier.SecondaryPlan memory p)
    {
        V2LenderAsk memory ask = core.getLenderAsk(id, wallet);
        p.seller = wallet;
        p.slots = ask.slots;
        p.price = ask.price;
        p.nonce = ask.nonce;
        p.maxFeeBps = ask.feeBps;
        _complete(p, id, vaults, masks);
    }

    function _complete(
        IntentQuoteVerifier.SecondaryPlan memory p,
        uint256 id,
        IntentVault[] memory vaults,
        uint8[] memory masks
    ) internal view {
        V2Loan memory l = core.getLoan(id);
        p.engine = address(core);
        p.loanId = id;
        p.filler = fillers[0];
        p.token = l.token;
        p.collateral = l.collateral;
        p.principal = l.principal;
        p.cap = l.cap;
        p.maturity = uint40(uint256(l.fundedAt) + l.term);
        p.modelAnnualBps = modelBps;
        p.policyVersion = verifier.SECONDARY_POLICY_VERSION();
        p.epoch = verifier.epoch();
        p.valuedAt = uint40(block.timestamp);
        p.issuedAt = uint40(block.timestamp);
        p.expiry = uint40(block.timestamp + 90);
        p.evidence = keccak256("secondary fixture evidence");
        for (uint8 q; q < 4; ++q) {
            if (p.slots & (1 << q) != 0) {
                p.minRewards[q] = uint128(coreRewards.remainingLenderReward(id, uint8(1 << q)));
            }
        }
        (vaults, masks) = _sorted(vaults, masks);
        p.allocations = new IntentQuoteVerifier.SecondaryAllocation[](vaults.length);
        for (uint256 i; i < vaults.length; ++i) {
            p.allocations[i] = _allocation(p, vaults[i], masks[i]);
        }
    }

    function _allocation(IntentQuoteVerifier.SecondaryPlan memory p, IntentVault vault, uint8 mask)
        internal
        view
        returns (IntentQuoteVerifier.SecondaryAllocation memory a)
    {
        a.vault = address(vault);
        a.slots = mask;
        for (uint8 q; q < 4; ++q) {
            if (mask & (1 << q) == 0) continue;
            a.price += uint128(verifier.quarterPrice(p.price, p.slots, q));
            a.repayment += uint128(p.cap / 4 + (q < p.cap % 4 ? 1 : 0));
        }
        IntentAssetPolicy policy = vault.ASSET_POLICY();
        a.policyRevision = policy.secondaryRevision();
        a.extraBps = policy.minExtraAnnualReturnBps();
        a.capBps = vault.executionCapBps();
        a.managerBps = vault.feeBps();
        a.minimum = uint128(
            IntentFeeMath.secondaryMinimum(a.price, uint256(p.modelAnnualBps) + a.extraBps, p.maturity - p.issuedAt)
        );
        (, uint256 fee) = IntentFeeMath.executionFee(a.repayment - a.price, a.minimum, a.capBps);
        a.executionFee = uint128(fee);
        a.maxReserveShares = uint128(IERC4626(address(vault.RESERVE())).previewWithdraw(a.price + fee));
    }

    /// @dev Ascending vault order, each mask travelling with its vault.
    function _sorted(IntentVault[] memory vaults, uint8[] memory masks)
        internal
        pure
        returns (IntentVault[] memory, uint8[] memory)
    {
        for (uint256 i = 1; i < vaults.length; ++i) {
            for (uint256 j = i; j > 0 && address(vaults[j]) < address(vaults[j - 1]); --j) {
                (vaults[j], vaults[j - 1]) = (vaults[j - 1], vaults[j]);
                (masks[j], masks[j - 1]) = (masks[j - 1], masks[j]);
            }
        }
        return (vaults, masks);
    }

    function _signSecondary(IntentQuoteVerifier.SecondaryPlan memory p) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, verifier.secondaryPlanHash(p));
        return abi.encodePacked(r, s, v);
    }

    function _buy(IntentQuoteVerifier.SecondaryPlan memory p) internal returns (bytes32) {
        bytes memory signature = _signSecondary(p);
        IntentFillRouter router_ = _secondaryRouter();
        vm.prank(p.filler);
        return router_.fillSecondary(p, signature);
    }

    /// @dev The plan's preflight answer, with nothing consumed.
    function _secondaryReason(IntentQuoteVerifier.SecondaryPlan memory p)
        internal
        returns (IntentQuoteVerifier.Refusal reason)
    {
        reason = IntentPreflight.secondaryReason(verifier, p, _signSecondary(p), p.filler);
    }

    function _assertSecondaryRefused(IntentQuoteVerifier.SecondaryPlan memory p, IntentQuoteVerifier.Refusal expected)
        internal
    {
        assertEq(uint8(_secondaryReason(p)), uint8(expected), "check");
        bytes memory signature = _signSecondary(p);
        IntentFillRouter router_ = _secondaryRouter();
        vm.prank(p.filler);
        vm.expectRevert(abi.encodeWithSelector(IntentQuoteVerifier.Refused.selector, expected));
        router_.fillSecondary(p, signature);
    }

    function _loanOf(IntentVault vault, uint256 id) internal view returns (LoanView memory v) {
        (,,, v.maturity,, v.settled,, v.repaid,, v.principal,, v.interest, v.rate,, v.executionFee, v.executionEarned) =
            vault.loans(id);
    }

    function _maxOf(IntentQuoteVerifier.SecondaryPlan memory p) internal pure returns (uint256 most) {
        for (uint256 i; i < p.allocations.length; ++i) {
            IntentQuoteVerifier.SecondaryAllocation memory a = p.allocations[i];
            if (a.price > most) most = a.price;
        }
    }
}

/// @notice S9 fixture: the secondary planner on the real fill router and verifier.
abstract contract IntentSecondaryBaseTest is IntentSecondaryPlanner {
    IntentFillRouter internal fills;

    function _deployRouter() internal override returns (address) {
        fills = new IntentFillRouter(IntentQuoteVerifier(address(verifier)), IERC20(address(usdg)));
        return address(fills);
    }

    function _secondaryRouter() internal view override returns (IntentFillRouter) {
        return fills;
    }

    function setUp() public virtual override {
        super.setUp();
        partnerFactory.setFiller(fillers[0], true);
        _standSecondary();
    }

    function _shares(uint256 count) internal pure returns (uint256[] memory limits) {
        limits = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            limits[i] = type(uint256).max;
        }
    }

    function _fill(IntentQuoteVerifier.Plan memory p) internal virtual override {
        bytes memory signature = _sign(p);
        vm.prank(p.filler);
        fills.fill(p, signature, _shares(p.allocations.length));
    }
}

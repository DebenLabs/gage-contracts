// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IntentPlanBaseTest} from "./IntentPlanBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {V2State} from "../../src/v2/V2Types.sol";

/// @notice The two cost floors of a primary plan, through the production fill router. A plan signs the model's cost of
/// its exact loan (`costBps`), from which the verifier recomputes the signed minimum and caps the execution fee. The
/// vault holds its own floor against the grade registry's cost for the token and term, and reads it only when its
/// rate grade is not zero (S3-QUOTE-POLICY section 2, AUDIT-SCOPE section 1.3).
contract IntentSignedCostBoundaryTest is IntentPlanBaseTest {
    IntentFillRouter internal fills;

    function _deployRouter() internal override returns (address) {
        fills = new IntentFillRouter(IntentQuoteVerifier(address(verifier)), IERC20(address(usdg)));
        return address(fills);
    }

    function setUp() public override {
        super.setUp();
        partnerFactory.setFiller(fillers[0], true);
    }

    // ---------------------------------------------------------------- fixture

    function _shares(uint256 count) internal pure returns (uint256[] memory limits) {
        limits = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            limits[i] = type(uint256).max;
        }
    }

    function _fill(IntentQuoteVerifier.Plan memory p) internal override {
        bytes memory signature = _sign(p);
        vm.prank(p.filler);
        fills.fill(p, signature, _shares(p.allocations.length));
    }

    function _assertRefused(IntentQuoteVerifier.Plan memory p, IntentQuoteVerifier.Refusal expected) internal override {
        assertEq(uint8(_reason(p)), uint8(expected), "check");
        bytes memory signature = _sign(p);
        vm.prank(p.filler);
        vm.expectRevert(abi.encodeWithSelector(IntentQuoteVerifier.Refused.selector, expected));
        fills.fill(p, signature, _shares(p.allocations.length));
    }

    // ---------------------------------------------------------------- the signed cost

    /// @dev Pashov M-51. A plan's `costBps` is the model's cost of the exact loan, not the registry's `modeledCostOf`.
    /// With the registry's cost withdrawn, a vault with no rate grade signs a zero minimum at any cost, and the plan
    /// signed at the model's cost funds the whole listing. Only an unpriced plan is refused, and the rate service
    /// never signs one.
    function testAZeroRateGradeVaultFundsWhenTheRegistryHasNoCost() public {
        _modeled(address(nvda), 0);
        assertEq(grades.modeledCostOf(address(nvda), T21), 0, "no registry cost");
        IntentVault open = _vault(1000, 0);
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(open, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        assertEq(p.costBps, COST_BPS, "signed at the model's cost");
        assertEq(p.allocations[0].minimum, 0, "no rate grade, no signed minimum");
        IntentQuoteVerifier.Plan memory unpriced = _plan(id, vaults, counts);
        unpriced.costBps = 0;
        _assertRefused(unpriced, IntentQuoteVerifier.Refusal.NO_MODELED_COST);
        assertEq(uint8(_reason(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        _fill(p);
        assertTrue(verifier.consumed(verifier.planHash(p)));
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.ACTIVE));
        assertEq(_executionFeeOf(open, id), p.allocations[0].executionFee);
    }

    /// @dev Pashov M-47, the lower-cost leg. With the registry's cost cut to 1 bps, the vault's own floor would let a
    /// fee one unit above the signed one through, but the verifier caps the fee at the interest less the signed
    /// minimum, and the router requires each vault to hand over exactly the signed fee. The signed plan fills and
    /// keeps its signed minimum.
    function testALowerRegistryCostCannotLetAFillKeepLessThanTheSignedMinimum() public {
        IntentVault strict = first.minRateGrade() == 3 ? first : second;
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(strict, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        IntentQuoteVerifier.Allocation memory a = p.allocations[0];
        // Grade B keeps 90% of the 10% cost on 1,000 USDG; the room under the 20% ceiling sets the fee.
        assertEq(a.minimum, 90e6);
        assertEq(a.executionFee, 10e6);
        _modeled(address(nvda), 1);
        IntentQuoteVerifier.Plan memory greedy = _plan(id, vaults, counts);
        greedy.allocations[0].executionFee = a.executionFee + 1;
        uint256 registryFloor = IntentFeeMath.minimumInterest(a.principal, grades.modeledCostOf(address(nvda), T21), 3);
        assertLt(registryFloor, a.interest - greedy.allocations[0].executionFee, "the vault's floor alone admits it");
        assertLe(
            greedy.allocations[0].executionFee, IntentFeeMath.executionCap(a.interest, a.capBps), "and its ceiling"
        );
        _assertRefused(greedy, IntentQuoteVerifier.Refusal.FEE_ABOVE_CEILING);
        _fill(p);
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.ACTIVE));
        uint128 fee = _executionFeeOf(strict, id);
        assertEq(fee, a.executionFee);
        assertGe(a.interest - fee, a.minimum, "kept at least the signed minimum");
    }
}

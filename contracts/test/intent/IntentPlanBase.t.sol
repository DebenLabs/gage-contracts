// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentAccountingBaseTest} from "./IntentAccountingBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentPreflight} from "./IntentPreflight.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {Kind} from "../../src/types/Types.sol";
import {IntentDemoPlanRouter} from "../../src/testnet/IntentDemoPlanRouter.sol";
import {TestnetOnly} from "../../src/testnet/TestnetOnly.sol";

/// @notice Fixture for signed funding plans: a verifier, a signer, two vaults on different terms, and the plan an
/// honest signer would produce for a listing as it stands. Ceilings, grades and costs are fixture values.
abstract contract IntentPlanBaseTest is IntentAccountingBaseTest {
    uint256 internal constant SIGNER_KEY = 0xA11CE5161;
    uint16 internal constant CAP_BPS = 2000;
    uint32 internal constant COST_BPS = 1000;
    bytes32 internal constant GOLDEN_DIGEST = 0x798628c8a541936a3695fe131c9942505b17b8ae4844f478f2cc20bab7e9e53e;

    IntentQuoteVerifier internal verifier;
    IntentDemoPlanRouter internal quoted;

    /// @dev The router the factory names. The verifier suite funds through the testnet fixture.
    function _deployRouter() internal virtual returns (address) {
        quoted = new IntentDemoPlanRouter(verifier);
        return address(quoted);
    }

    /// @dev This suite's router is the first the factory names, and so the one it binds.
    function _namesStandInRouter() internal pure override returns (bool) {
        return false;
    }
    address internal signer;
    IntentVault internal first;
    IntentVault internal second;

    function setUp() public virtual override {
        super.setUp();
        signer = vm.addr(SIGNER_KEY);
        verifier = new IntentQuoteVerifier(partnerFactory);
        partnerFactory.setFillRouter(_deployRouter());
        partnerFactory.setQuoteSigner(signer);
        // Grade C keeps 75% of the modeled cost; the registry's own copy of that cost backs the vault's floor.
        _modeled(address(nvda), COST_BPS);
        IntentVault a = _vault(1000, 2);
        IntentVault b = _vault(1500, 3);
        (first, second) = address(a) < address(b) ? (a, b) : (b, a);
    }

    // ---------------------------------------------------------------- fixture

    function _modeled(address token, uint32 bps) internal {
        address[] memory tokens = new address[](1);
        uint32[] memory terms = new uint32[](1);
        uint32[] memory costs = new uint32[](1);
        tokens[0] = token;
        terms[0] = T21;
        costs[0] = bps;
        grades.setModeledCosts(tokens, terms, costs);
    }

    function _vault(uint16 feeBps, uint8 minRateGrade) internal returns (IntentVault vault) {
        mandate.feeBps = feeBps;
        mandate.minRateGrade = minRateGrade;
        mandate.executionCapBps = CAP_BPS;
        vm.prank(curator);
        vault = IntentVault(partnerFactory.create(mandate, false, 0, "Test vault"));
        vm.prank(alice);
        usdg.approve(address(vault), MAX);
        vm.prank(alice);
        vault.deposit(10_000e6, 0);
    }

    function _listing() internal returns (uint256) {
        return _list(borrower, address(nvda), 100e18, uint128(REVIEW_PRINCIPAL), uint128(REVIEW_CAP), T21);
    }

    function _one(IntentVault vault, uint8 units)
        internal
        pure
        returns (IntentVault[] memory vaults, uint8[] memory counts)
    {
        vaults = new IntentVault[](1);
        counts = new uint8[](1);
        vaults[0] = vault;
        counts[0] = units;
    }

    function _two(uint8 a, uint8 b) internal view returns (IntentVault[] memory vaults, uint8[] memory counts) {
        vaults = new IntentVault[](2);
        counts = new uint8[](2);
        vaults[0] = first;
        vaults[1] = second;
        counts[0] = a;
        counts[1] = b;
    }

    /// @dev The plan an honest signer would produce now: live terms, live empty units, the reference fee.
    function _plan(uint256 id, IntentVault[] memory vaults, uint8[] memory counts)
        internal
        view
        returns (IntentQuoteVerifier.Plan memory p)
    {
        V2Loan memory l = core.getLoan(id);
        p.engine = address(core);
        p.listingId = id;
        p.filler = fillers[0];
        p.token = l.token;
        p.kind = uint8(l.kind);
        p.collateral = l.collateral;
        p.principal = l.principal;
        p.cap = l.cap;
        p.term = l.term;
        p.costBps = COST_BPS;
        p.feePolicy = verifier.FEE_POLICY_VERSION();
        p.epoch = verifier.epoch();
        p.issuedAt = uint40(block.timestamp);
        p.expiry = uint40(block.timestamp + 90);
        p.evidence = keccak256("fixture evidence");
        p.allocations = new IntentQuoteVerifier.Allocation[](vaults.length);
        address[4] memory lenders = core.lenders(id);
        uint8 next;
        for (uint256 i; i < vaults.length; ++i) {
            IntentQuoteVerifier.Allocation memory a = p.allocations[i];
            a.vault = address(vaults[i]);
            a.units = counts[i];
            uint256 owed;
            for (uint8 left = counts[i]; next < 4 && left != 0; ++next) {
                if (lenders[next] != address(0)) continue;
                a.principal += uint128(l.principal / 4 + (next < l.principal % 4 ? 1 : 0));
                owed += l.cap / 4 + (next < l.cap % 4 ? 1 : 0);
                --left;
            }
            a.interest = uint128(owed - a.principal);
            a.minRateGrade = vaults[i].minRateGrade();
            a.capBps = vaults[i].executionCapBps();
            a.managerBps = vaults[i].feeBps();
            a.minimum = uint128(IntentFeeMath.minimumInterest(a.principal, p.costBps, a.minRateGrade));
            (, uint256 fee) = IntentFeeMath.executionFee(a.interest, a.minimum, a.capBps);
            a.executionFee = uint128(fee);
            a.maxReserveShares = uint128(vaults[i].RESERVE().previewWithdraw(uint256(a.principal) + fee));
        }
    }

    function _sign(IntentQuoteVerifier.Plan memory p) internal view returns (bytes memory) {
        return _signWith(SIGNER_KEY, p);
    }

    function _signWith(uint256 key, IntentQuoteVerifier.Plan memory p) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, verifier.planHash(p));
        return abi.encodePacked(r, s, v);
    }

    /// @dev The plan's preflight answer, with nothing consumed.
    function _reason(IntentQuoteVerifier.Plan memory p) internal returns (IntentQuoteVerifier.Refusal reason) {
        reason = IntentPreflight.reason(verifier, p, _sign(p), p.filler);
    }

    function _assertRefused(IntentQuoteVerifier.Plan memory p, IntentQuoteVerifier.Refusal expected) internal virtual {
        assertEq(uint8(_reason(p)), uint8(expected), "check");
        bytes memory signature = _sign(p);
        vm.prank(p.filler);
        vm.expectRevert(abi.encodeWithSelector(IntentQuoteVerifier.Refused.selector, expected));
        quoted.fill(p, signature);
    }

    function _fill(IntentQuoteVerifier.Plan memory p) internal virtual {
        bytes memory signature = _sign(p);
        vm.prank(p.filler);
        quoted.fill(p, signature);
    }

    function _executionFeeOf(IntentVault vault, uint256 id) internal view returns (uint128 fee) {
        (,,,,,,,,,,,,,, fee,) = vault.loans(id);
    }
}

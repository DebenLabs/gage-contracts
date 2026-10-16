// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IntentVault, IntentCategory} from "../../src/intent/IntentVault.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentVaultCode} from "../helpers/IntentVaultCode.sol";
import {MorphoV2ReserveLens} from "../../src/intent/MorphoV2ReserveLens.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {IntentAccountingRouter} from "./IntentAccountingBase.t.sol";

/// @notice Opt-in local fork of Robinhood testnet 46630: the S2 factory, vault and Morpho lens deployed in the fork
/// VM against the live zero-grace core, the live Morpho Vault V2 reserve, the live registry and test USDG, then the
/// whole S2 lifecycle. It never broadcasts, signs nothing, and is skipped unless INTENT_S2_FORK_RPC is set, so normal
/// runs use no RPC. Addresses are the S0 candidate manifest's (docs/intent-v1/evidence/s0-candidate-46630.json).
/// @dev The router is the test-only forwarding fixture: no quote, cap, floor or atomic completion (S3/S4). Grade
/// floors are zero because testnet pricing fixtures expire by design; the mandate checks under test are S1's.
contract IntentS2TestnetForkTest is Test {
    GageV2Vault internal constant CORE = GageV2Vault(0xecaD68382359B92bf9Ed4CFC06036121b61a043c);
    IERC4626 internal constant RESERVE = IERC4626(0x23f70efcD18c83Daf442563f2B189Fa39c471Db6);
    IERC20 internal constant USDG = IERC20(0x445b73572C94287D0334375E4589A5d9EEd81b7f);
    address internal constant NVDAX = 0x153c8D62895B82314f50d83499E5EE50eAC61dB3;
    address internal constant GRADES = 0x2cA2106706E687c246B54f28Ba7a18Df152d8631;
    address internal constant FEE_FLOOR = 0xc0DDA77ed245Ce78B7A8E7506c4cBcaE1a2A87e4;
    /// @dev The testnet's DealFeeRouter: the only kind of address the factory accepts for the protocol's USDG (S7).
    address internal constant FEE_PROCESSOR = 0x15ff6F47076306E03aF8315BECf6137298D28446;
    uint32 internal constant T21 = 21 days;
    uint8 internal constant UNITS = 4;

    address internal curator = makeAddr("s2-fork-curator");
    address internal filler = makeAddr("s2-fork-filler");
    address internal borrower = makeAddr("s2-fork-borrower");
    address internal alice = makeAddr("s2-fork-alice");
    address internal bob = makeAddr("s2-fork-bob");

    IntentFactory internal factory;
    IntentVault internal vault;
    IntentAccountingRouter internal router;
    MorphoV2ReserveLens internal lens;

    function setUp() public {
        string memory rpc = vm.envOr("INTENT_S2_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // A pinned block keeps the reference still. Only the fork VM is mutated.
        vm.createSelectFork(rpc, vm.envUint("INTENT_S2_FORK_BLOCK"));
        assertEq(block.chainid, 46_630, "testnet only");
        assertEq(CORE.GRACE(), 0);
        assertEq(address(CORE.USDG()), address(USDG));
        assertEq(RESERVE.asset(), address(USDG));

        lens = new MorphoV2ReserveLens();
        IntentVaultCode store_ = new IntentVaultCode();
        factory = new IntentFactory(
            IntentFactory.Params({
                core: address(CORE),
                reserve: address(RESERVE),
                reserveLens: address(lens),
                grades: GRADES,
                protocolRecipient: FEE_PROCESSOR,
                initialOwner: address(this),
                codeA: store_.CHUNK_A(),
                codeB: store_.CHUNK_B()
            })
        );
        factory.assignCategory(NVDAX, IntentCategory.STOCK);
        factory.setCreator(curator, true);
        address[] memory picks = new address[](1);
        picks[0] = NVDAX;
        // Read before prank: the getter must not consume the one-call manager impersonation.
        uint16 executionCap = IntentFeeMath.MAX_EXECUTION_CAP_BPS;
        vm.prank(curator);
        vault = IntentVault(factory.create(_mandate(picks, executionCap), false, 0, "Test vault"));
        router = new IntentAccountingRouter(factory);
        factory.setFillRouter(address(router));
        factory.setQuoteSigner(address(0x5151));
        factory.setFiller(filler, true);

        // Local fork balances only: nothing is minted, fauceted or transferred on the chain itself.
        deal(address(USDG), alice, 100_000e6);
        deal(address(USDG), bob, 100_000e6);
        deal(address(USDG), borrower, 100_000e6);
        vm.prank(alice);
        USDG.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        USDG.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        USDG.approve(address(CORE), type(uint256).max);
    }

    /// @dev Fixture values, not launch defaults. Built apart from `setUp` to keep its IR stack shallow.
    function _mandate(address[] memory picks, uint16 executionCap) private view returns (IntentVault.Mandate memory) {
        return IntentVault.Mandate({
            curator: curator,
            categoryWeights: [uint16(10_000), 0, 0, 0],
            assets: picks,
            maxLoanTerm: T21,
            feeBps: 1000,
            minGrade: 0,
            minRateGrade: 0,
            maxLoanPrincipal: 5000e6,
            maxAssetBps: 10_000,
            bufferBps: 0,
            executionCapBps: executionCap
        });
    }

    function testThreeHourAssetDelayOnLiveTestnetCore() public {
        _enter(alice, 10_000e6);
        uint256 id = _list(1000e6, 1100e6);
        vm.startPrank(curator);
        vault.setAsset(NVDAX, false);
        vault.setAsset(NVDAX, true);
        vm.stopPrank();
        uint256 eta = vault.ASSET_POLICY().readyAt(NVDAX);
        assertEq(eta, block.timestamp + 3 hours);
        vm.prank(filler);
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        router.fund(vault, id, UNITS, 0);
        vm.warp(eta - 1);
        vm.expectRevert(IntentVault.InvalidConfiguration.selector);
        vault.resolveAssetAddition(NVDAX, true);
        vm.warp(eta);
        vault.resolveAssetAddition(NVDAX, true);
        _fund(id, 0);
        assertEq(vault.performingPrincipal(), 1000e6);
        vm.prank(curator);
        vault.setAsset(NVDAX, false);
        assertFalse(vault.ASSET_POLICY().picked(NVDAX));
        assertEq(vault.performingPrincipal(), 1000e6, "removal preserves existing loans");
    }

    function _list(uint128 principal, uint128 cap) internal returns (uint256 id) {
        ICollateralRegistry.ERC20Config memory config =
            ICollateralRegistry(address(CORE.REGISTRY())).getERC20Config(NVDAX);
        assertTrue(config.allowed, "NVDAx is admitted on the live registry");
        deal(NVDAX, borrower, config.minAmount);
        vm.startPrank(borrower);
        IERC20(NVDAX).approve(address(CORE), config.minAmount);
        id = CORE.list(
            Collateral(Kind.ERC20, NVDAX, config.minAmount),
            principal,
            cap,
            T21,
            uint40(block.timestamp + 1 days),
            false
        );
        vm.stopPrank();
    }

    function _fund(uint256 id, uint256 executionFee) internal returns (uint256 gas) {
        vm.prank(filler);
        router.fund(vault, id, UNITS, executionFee);
        gas = vm.lastCallGas().gasTotalUsed;
    }

    function _enter(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(assets, 0);
    }

    function _exit(address who, uint256 shares) internal returns (uint256 assets) {
        vm.prank(who);
        assets = vault.redeem(shares, 0);
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _maturity(uint256 id) internal view returns (uint256) {
        V2Loan memory l = CORE.getLoan(id);
        return uint256(l.fundedAt) + l.term;
    }

    /// @dev The live reserve reports zero max views and still pays: the lens, not the view, is the measurement.
    function testLensMeasuresTheLiveMorphoReserve() public {
        _enter(alice, 10_000e6);
        vm.prank(filler);
        router.investReserve(vault, 6000e6);
        assertEq(RESERVE.maxWithdraw(address(vault)), 0, "zero by design");
        uint256 measured = lens.withdrawable(address(RESERVE), address(vault));
        emit log_named_uint("lens: live reserve can pay, USDG raw", measured);
        assertGe(measured, 6000e6 - 1, "what was just deposited is payable");
        assertApproxEqAbs(vault.freeLiquidity(), 10_000e6, 2);
        // The whole position leaves through the real reserve.
        uint256 out = _exit(alice, vault.balanceOf(alice));
        assertApproxEqAbs(out, 10_000e6, 3);
        assertLe(vault.reserveShares(), 1e12, "only share-conversion dust remains in the reserve");
    }

    /// @dev S2-A1 on the live core: neither order of entry and repayment captures paid interest.
    function testNoCaptureAroundAnEarlyRepaymentOnTheLiveCore() public {
        _enter(alice, 10_000e6);
        uint256 id = _list(1000e6, 1100e6);
        _fund(id, 0);
        assertEq(uint8(CORE.getLoan(id).state), uint8(V2State.ACTIVE));
        vm.warp(block.timestamp + 3 days);
        uint256 shares = _enter(bob, 10_000e6);
        vm.prank(borrower);
        CORE.reclaim(id, borrower);
        vault.settle(_ids(id));
        assertLe(_exit(bob, shares), 10_000e6, "entered before the repayment");
        shares = _enter(bob, 10_000e6);
        assertLe(_exit(bob, shares), 10_000e6, "entered after it");
        assertEq(vault.pocketClaimable(1, bob), 0, "no claim for an entrant around the repayment");
        assertEq(vault.pocketLiability(address(USDG)), 90e6 - 90e6 * 3 days / T21, "the rest of the 90 is the claim");
    }

    /// @dev The whole lifecycle with the live core and the live reserve, and its gas on this chain's state (D51).
    function testLifecycleWithExecutionFeeEarlyRepaymentAndClaim() public {
        vm.prank(alice);
        vault.deposit(10_000e6, 0);
        uint256 depositGas = vm.lastCallGas().gasTotalUsed;
        vm.prank(filler);
        router.investReserve(vault, 9500e6);
        uint256 id = _list(1000e6, 1100e6);
        // Cash is 500, so the fill draws the rest from the live Morpho reserve.
        uint256 fundGas = _fund(id, 20e6);
        assertEq(vault.executionFees(), 20e6, "earned: the fill completed the listing");
        assertApproxEqAbs(vault.totalAssets(), 10_000e6 - 20e6, 2, "the fee left priced assets once");

        vm.warp(block.timestamp + 3 days);
        vm.prank(borrower);
        CORE.reclaim(id, borrower);
        uint256 before_ = vault.totalAssets();
        vault.settle(_ids(id));
        uint256 bookGas = vm.lastCallGas().gasTotalUsed;
        assertApproxEqAbs(vault.totalAssets(), before_, 1, "booking the early repayment moved no priced assets");
        // 100 of interest less 10% of the 80 the execution fee left is 92; what the clock had not counted is the claim.
        assertEq(vault.pocketLiability(address(USDG)), 92e6 - 92e6 * 3 days / T21);
        assertEq(vault.curatorFees(), 7.2e6);
        assertEq(vault.protocolFees(), 0.8e6);

        vm.warp(_maturity(id));
        vault.settle(_ids(id));
        uint256 releaseGas = vm.lastCallGas().gasTotalUsed;
        uint256 claimed;
        vm.prank(alice);
        claimed = vault.claimPocket(1);
        // The reserve earned a little over the three weeks; the loan added exactly 92 less the 20 fee.
        assertGe(vault.totalAssets() + claimed, 10_000e6 - 20e6 + 92e6 - 2);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.redeem(shares, 0);
        uint256 redeemGas = vm.lastCallGas().gasTotalUsed;
        assertGe(out + claimed, 10_072e6 - 3);
        assertEq(vault.totalSupply(), 0);
        uint256 processorBefore = USDG.balanceOf(FEE_PROCESSOR);
        uint256 floorBefore = USDG.balanceOf(FEE_FLOOR);
        vault.claimFees();
        assertGe(USDG.balanceOf(FEE_PROCESSOR) - processorBefore, 0.8e6, "the protocol's share reaches the processor");
        assertEq(USDG.balanceOf(FEE_FLOOR), floorBefore, "and never the floor");
        // What is left is the earned execution fee, which S4 will pay out, and conversion dust.
        assertApproxEqAbs(USDG.balanceOf(address(vault)), 20e6, 5);

        emit log_named_uint("gas: deposit", depositGas);
        emit log_named_uint("gas: fund 4 units through the live reserve", fundGas);
        emit log_named_uint("gas: settle, booking the early repayment", bookGas);
        emit log_named_uint("gas: settle at term end, after the booking", releaseGas);
        emit log_named_uint("gas: last-holder redeem through the live reserve", redeemGas);
        emit log_named_uint("block gas limit reported by the chain", block.gaslimit);
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {Kind} from "../../src/types/Types.sol";
import {LoopRouter} from "../../src/loop/LoopRouter.sol";
import {IUniV3Factory} from "../../src/interfaces/IUniV3.sol";

/// @dev The testnet's assets are mocks with a public mint.
interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice The loop router against the audit-remediation generation `staging-audit-r3-20261001` on Robinhood Chain
/// testnet 46630, on a LOCAL fork: the published core (bridged, zero grace), factory, verifier, fill router, the three
/// vaults that pick NVDAx, and the published NVDAx/USDG v4 pool. Nothing is sent to any chain.
/// What only the fork has: the router itself, admitted by the generation's admin (the registry's `setRouter`, the
/// factory's `setFiller`), a quote signer the admin names (the hosted signer's key is held by nobody), the depositor's
/// USDG in the three vaults (the generation was activated without a seed) and the borrower's NVDAx, both minted from
/// the mocks.
/// @dev Skipped unless INTENT_TESTNET_FORK_URL is set (the public node). INTENT_TESTNET_FORK_BLOCK pins a block.
contract LoopRouterTestnetForkTest is Test {
    uint256 internal constant CHAIN_ID = 46_630;
    uint256 internal constant SIGNER_KEY = 0x100F;
    uint32 internal constant T21 = 21 days;

    IntentFactory internal constant FACTORY = IntentFactory(0x1d29eBbeB375c228D59918B35B3323795Ba47C98);
    GageV2Vault internal constant CORE = GageV2Vault(0xf34884284A50E0f1F31A3c58b325EdB37DED9fcF);
    IntentFillRouter internal constant FILLS = IntentFillRouter(0xb89f33D24C26459b6802986d2A74d0f20e23A061);
    IntentQuoteVerifier internal constant VERIFIER = IntentQuoteVerifier(0xa9A3d436c47D94db7e0DE6b269Bc43e0c448c3eb);
    GageV2TokenRegistry internal constant REGISTRY = GageV2TokenRegistry(0x12D736bb358dAf38d0C7aed5277De738ffFC2d44);
    address internal constant ADMIN = 0xcC102337e3B6e2F8Ee13364c1C2fE7cAe599CE14;
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x751562f1BD14925769E8641436fcFaCf51fF5740);
    /// @dev The testnet's own Uniswap V3 factory (`V3Factory` in launch/live/46630.json), for `loopV3` (D242).
    IUniV3Factory internal constant V3_FACTORY = IUniV3Factory(0x89d32476023C4432568d41BEbb9A8591b7935A49);
    address internal constant USDG = 0x445b73572C94287D0334375E4589A5d9EEd81b7f;
    address internal constant NVDAX = 0x153c8D62895B82314f50d83499E5EE50eAC61dB3;
    /// @dev The generation's NVDAx vaults in address order: `stocks` (1,500 per loan), `nvda-high-fee` and
    /// `nvda-low-fee` (750 each).
    IntentVault internal constant STOCKS = IntentVault(payable(0x33479b35CFbc3F32aa6E0Ea112d3b0FFe6e0476a));
    IntentVault internal constant NVDA_HIGH = IntentVault(payable(0xC6d41254E28dA50838DB9226F29Dfe5ebf0CB151));
    IntentVault internal constant NVDA_LOW = IntentVault(payable(0xEAD3B7c3bBBdF882385fa4A8318082bfc201bD5A));

    /// @dev Five NVDAx of the borrower's and ten bought at about 179 USDG each: about 2,680 USDG of collateral against
    /// 2,000 lent for 21 days at 0.5%, above the registry's modeled cost for the token and term.
    uint256 internal constant OWN = 5e18;
    uint256 internal constant BUY = 10e18;
    uint256 internal constant MAX_COST = 1900e6;
    uint128 internal constant PRINCIPAL = 2000e6;
    uint128 internal constant CAP = 2010e6;
    uint32 internal constant COST_BPS = 40;
    bytes32 internal constant PRICING = keccak256("fork loop pricing");

    LoopRouter internal looper;
    PoolKey internal key;
    address internal user = makeAddr("fork-looper");
    address internal depositor = makeAddr("fork-depositor");

    function setUp() public {
        string memory url = vm.envOr("INTENT_TESTNET_FORK_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pin = vm.envOr("INTENT_TESTNET_FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, pin);
        assertEq(block.chainid, CHAIN_ID, "testnet");
        assertEq(address(FILLS.CORE()), address(CORE), "router's core");
        assertEq(FACTORY.fillRouter(), address(FILLS), "factory's router");

        key = PoolKey({
            currency0: Currency.wrap(NVDAX),
            currency1: Currency.wrap(USDG),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        looper = new LoopRouter(FILLS, POOL_MANAGER, V3_FACTORY, address(this));

        vm.startPrank(ADMIN);
        REGISTRY.setRouter(address(looper), true);
        FACTORY.setFiller(address(looper), true);
        FACTORY.setQuoteSigner(vm.addr(SIGNER_KEY));
        vm.stopPrank();

        IMintable(USDG).mint(depositor, 6000e6);
        _deposit(STOCKS, 2000e6);
        _deposit(NVDA_HIGH, 2000e6);
        _deposit(NVDA_LOW, 2000e6);

        IMintable(NVDAX).mint(user, OWN);
        IMintable(USDG).mint(user, 100e6);
        vm.startPrank(user);
        IERC20(NVDAX).approve(address(looper), type(uint256).max);
        IERC20(USDG).approve(address(looper), type(uint256).max);
        vm.stopPrank();
    }

    function _deposit(IntentVault vault, uint256 assets) internal {
        vm.startPrank(depositor);
        IERC20(USDG).approve(address(vault), assets);
        vault.deposit(assets, 0);
        vm.stopPrank();
    }

    /// @dev What the hosted signer would sign ahead of the listing: two units from `stocks`, one from each NVDA vault.
    function _plan() internal view returns (IntentQuoteVerifier.Plan memory p) {
        IntentVault[3] memory vaults = [STOCKS, NVDA_HIGH, NVDA_LOW];
        uint8[3] memory counts = [uint8(2), 1, 1];
        p.engine = address(CORE);
        p.listingId = CORE.loanCount() + 1;
        p.filler = address(looper);
        p.token = NVDAX;
        p.kind = uint8(Kind.ERC20);
        p.collateral = OWN + BUY;
        p.principal = PRINCIPAL;
        p.cap = CAP;
        p.term = T21;
        p.costBps = COST_BPS;
        p.feePolicy = VERIFIER.FEE_POLICY_VERSION();
        p.epoch = VERIFIER.epoch();
        p.issuedAt = uint40(block.timestamp);
        p.expiry = uint40(block.timestamp + 30);
        p.evidence = looper.evidenceFor(user, PRICING);
        p.allocations = new IntentQuoteVerifier.Allocation[](3);
        uint8 next;
        for (uint256 i; i < 3; ++i) {
            IntentQuoteVerifier.Allocation memory a = p.allocations[i];
            a.vault = address(vaults[i]);
            a.units = counts[i];
            uint256 owed;
            for (uint8 left = counts[i]; left != 0; --left) {
                a.principal += uint128(PRINCIPAL / 4 + (next < PRINCIPAL % 4 ? 1 : 0));
                owed += CAP / 4 + (next < CAP % 4 ? 1 : 0);
                ++next;
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

    function _loop() internal view returns (LoopRouter.Loop memory l) {
        l.key = key;
        l.own = OWN;
        l.buy = BUY;
        l.maxCost = MAX_COST;
        l.fundingDeadline = uint40(block.timestamp + 1 days);
        l.withRewards = true;
        l.pricing = PRICING;
    }

    function _shares() internal pure returns (uint256[] memory limits) {
        limits = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            limits[i] = type(uint256).max;
        }
    }

    function test_fork_loopOnR3() public {
        IntentQuoteVerifier.Plan memory p = _plan();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, VERIFIER.planHash(p));
        uint256 usdgBefore = IERC20(USDG).balanceOf(user);

        vm.prank(user);
        (uint256 id, uint256 cost) = looper.loop(_loop(), p, abi.encodePacked(r, s, v), _shares());

        V2Loan memory l = CORE.getLoan(id);
        assertEq(uint8(l.state), uint8(V2State.ACTIVE), "active through the bridge");
        assertEq(l.originator, user, "borrower of record");
        assertEq(CORE.ownerOf(id), user, "reclaim right");
        assertEq(l.collateral, OWN + BUY, "collateral");
        assertEq(IERC20(NVDAX).balanceOf(l.account), OWN + BUY, "escrowed");
        assertEq(IERC20(USDG).balanceOf(user), usdgBefore + PRINCIPAL - l.originationFee - cost, "net cash");
        assertEq(IERC20(NVDAX).balanceOf(address(looper)), 0, "router NVDAx");
        assertEq(IERC20(USDG).balanceOf(address(looper)), 0, "router USDG");
        emit log_named_uint("listing id", id);
        emit log_named_decimal_uint("purchase cost (USDG)", cost, 6);
        emit log_named_decimal_uint("origination fee (USDG)", l.originationFee, 6);
        emit log_named_decimal_uint("borrower net cash (USDG)", usdgBefore + PRINCIPAL - l.originationFee - cost, 6);

        // The borrower repays the cap before maturity and takes every token back: the loop is theirs.
        IMintable(USDG).mint(user, CAP);
        vm.startPrank(user);
        IERC20(USDG).approve(address(CORE), CAP);
        CORE.reclaim(id, user);
        CORE.withdrawCollateral(id, user);
        vm.stopPrank();
        assertEq(IERC20(NVDAX).balanceOf(user), OWN + BUY, "collateral back");
    }
}

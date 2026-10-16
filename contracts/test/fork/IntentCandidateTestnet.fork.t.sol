// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IntentVault, IntentCategory, IReserveLens} from "../../src/intent/IntentVault.sol";
import {IIntentVaultD29} from "../intent/legacy/IIntentVaultD29.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentVaultCode} from "../helpers/IntentVaultCode.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentPreflight} from "../intent/IntentPreflight.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {MorphoV2ReserveLens} from "../../src/intent/MorphoV2ReserveLens.sol";
import {GradeRegistry} from "../../src/earn/GradeRegistry.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {DealFeeRouter} from "../../src/token/DealFeeRouter.sol";
import {unitsOf} from "../helpers/CoreUnits.sol";

using {unitsOf} for GageV2Vault;

/// @dev The testnet's assets are mocks with a public mint.
interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @dev The published factory's view of its stored vault creation code; this source's factory no longer has it.
interface IStoredVaultCode {
    function vaultCreationCode() external view returns (bytes memory);
}

/// @dev The published factory's creation entry points and creator record; this source's one `create` also takes the
/// secondary policy, and its factory records only `isVault` (the creator is the vault's curator).
interface ILegacyIntentCreate {
    function create(IntentVault.Mandate calldata mandate) external returns (address);

    function createWithSecondary(IntentVault.Mandate calldata mandate, bool secondaryEnabled, uint16 secondaryExtraBps)
        external
        returns (address);

    function creatorOf(address vault) external view returns (address);
}

/// @dev The published vault's creation ceilings and floors and its limit setter; this source keeps none of the bounds
/// and moves its limits through the asset policy, tightening at once and loosening after three hours (D53).
interface ILegacyIntentBounds {
    function categoryCeilingBps(IntentCategory lane) external view returns (uint16);

    function setCategoryWeight(IntentCategory lane, uint16 bps) external;

    function setMinRateGrade(uint8 rank) external;

    function MIN_RATE_GRADE_FLOOR() external view returns (uint8);

    function MAX_LOAN_PRINCIPAL() external view returns (uint128);

    function MAX_ASSET_BPS() external view returns (uint16);

    function MIN_BUFFER_BPS() external view returns (uint16);

    function setLimits(uint128 maxLoanPrincipal, uint16 maxAssetBps, uint16 bufferBps) external;
}

/// @dev The published vault's router entry point, interest-clock view and pass-through views of its asset policy;
/// this source's vault has `purchase`, no `accrualRate`, and leaves the asset list to its policy.
interface ILegacyIntentVault {
    function fund(uint256 id, uint8 units, uint256 maxReserveShares, uint256 executionFee) external;

    function accrualRate() external view returns (uint256);

    function pickedAssets() external view returns (uint256);

    function assetPicked(address token) external view returns (bool);
}

/// @dev The published factory's and vaults' settings extension, which runs the vaults' curator settings; this source
/// folds them back into the vault (IV-a-01) and has no extension.
interface ILegacySettings {
    function SETTINGS() external view returns (address);
}

/// @dev The published factory's filler payout record and three-argument admission; this source's factory admits
/// fillers only (D49).
interface ILegacyFillerPayout {
    function fillerPayout(address filler) external view returns (address);

    function setFiller(address filler, bool allowed, address payout) external;
}

/// @dev The published router's filler share, locked at zero (D49), and its setter; this source's router has no filler
/// share.
interface ILegacyFillRouter {
    error NotOwner();

    function MAX_FILLER_SHARE_BPS() external view returns (uint16);

    function fillerShareBps() external view returns (uint16);

    function setFillerShare(uint16 bps) external;
}

/// @dev A registry's pause of new deals, as its owner moves it.
interface IDealsPause {
    function owner() external view returns (address);
    function newDealsPaused() external view returns (bool);
    function pauseNewDeals(bool paused) external;
}

/// @dev The legacy V1 vault behind the bridged core, as far as its registry.
interface ILegacyDealVault {
    function REGISTRY() external view returns (address);
}

/// @notice S8: the money lifecycle on the SAME Intent candidate that is published on Robinhood Chain testnet 46630:
/// the audit freeze's generation `staging-freeze-r1-20260925` (factory, quote verifier, fill router, vault code store,
/// the bridged zero-grace core and the six vaults the admitted managers created), on a LOCAL fork of that testnet at
/// one pinned block. Every call goes to the published contracts. The scenarios need a money state of their own (sole
/// depositors, loans of known shape, one early repayment), which no live state provides: the generation was published
/// with funding and deposits not yet opened, and once they are, testers' deposits and loans are not the test's. So the
/// fork stages the money first (`_stage`), through the published contracts only, as the hosted keeper and users
/// would: in each published vault that still stands as published at the pin, and otherwise in a twin its own manager
/// creates through the published factory from the mandate it was published with (`_fixtureVault`). Time, callers and
/// balances are the fork VM's (`vm.warp`, `vm.prank`, the mocks' public `mint`). Nothing is ever sent to any chain:
/// no key signs a transaction and nothing is broadcast.
/// @dev Skipped unless INTENT_TESTNET_FORK_URL is set (the public node; it is not ROBINHOOD_TESTNET_RPC_URL on
/// purpose). INTENT_TESTNET_FORK_BLOCK pins the block; unset, the head less a margin is taken, rounded down so tests
/// running side by side agree, and recorded. Every test starts from that pinned state again, so the scenarios are
/// independent; the last test replays all of them between state snapshots of one fork and writes the evidence, so
/// every number in it comes from one block.
/// The generation was built from the r1 source (audit/intent-v1-r1), before this source's reductions and D51. Calls
/// to what it has and this source does not go through the local legacy interfaces above. Its identity and bytecode
/// checks (`_identities`) compare it with this build, so they fail until a generation of this source is published.
/// Addresses are the published ones of launch/staging/staging-freeze-r1-20260925.publication.json (factory, router,
/// verifier, vault code store, core, reserve, lens, grade registry, admin, sole filler, the creation-code hashes and
/// the six vaults), which docs/intent-v1/evidence/audit-freeze.json checks against this source (`testnet`), and the
/// foundation it names (USDG, DealFeeRouter, FeeFloor, NVDAx, TSLAx, MSFTx, MOON). They are constants because the test
/// may read no file but its own evidence.
/// What only the fork has, each said again where it is used: a quote signer the factory's owner names (the hosted
/// signer's key is held by nobody), grades and modeled costs republished as they stand by the grade registry's own
/// publisher (so a stopped publisher cannot age them out of a run), the twin of any fixture vault that no longer
/// stands as published, the fork's depositor and borrower, their deposits and listings, the four loans the admitted
/// filler funds through the published router with plans that signer signs, one early repayment booked an hour before
/// any scenario starts, the reserve investments of the admitted filler, and one fresh vault an admitted manager
/// creates.
contract IntentCandidateTestnetForkTest is Test {
    string internal constant EVIDENCE = "../docs/intent-v1/evidence/s8-testnet-fork-lifecycle.json";
    uint256 internal constant CHAIN_ID = 46_630;
    /// @dev A lagging backend of the public node may not have the very last blocks yet.
    uint256 internal constant HEAD_MARGIN = 16;
    /// @dev About a minute of this chain's blocks: tests of one run that pin for themselves land on one block.
    uint256 internal constant PIN_GRAIN = 256;
    string internal constant GENERATION = "staging-freeze-r1-20260925";

    IntentFactory internal constant FACTORY = IntentFactory(0x3C6E3F1fAf7EF5737cAb03084C08ca3A7097b702);
    IntentQuoteVerifier internal constant VERIFIER = IntentQuoteVerifier(0x0827dD49DE276402C42726908D3fdE3c931E99E4);
    IntentFillRouter internal constant ROUTER = IntentFillRouter(0x4f879c3ed48a7Bd24D231C1d77480379d727b238);
    /// @dev The store the factory reads the vault's creation code from (`vaultCode` in the publication).
    IntentVaultCode internal constant VAULT_CODE = IntentVaultCode(0xaF984001D1935aD19d1c4064FCcC2B580cBc7E2a);
    GageV2Vault internal constant CORE = GageV2Vault(0xd3Ee90E66366B0b83282E908bAaB0AdF55b3A957);
    IERC4626 internal constant RESERVE = IERC4626(0x23f70efcD18c83Daf442563f2B189Fa39c471Db6);
    IReserveLens internal constant LENS = IReserveLens(0xB00B46A450f1A972a4f83ecbE27fE19b270E56BF);
    GradeRegistry internal constant GRADES = GradeRegistry(0xCe54fB35E34f0D53d930255B80fBf8F3b71adaC7);
    address internal constant ADMIN = 0xcC102337e3B6e2F8Ee13364c1C2fE7cAe599CE14;
    IERC20 internal constant USDG = IERC20(0x445b73572C94287D0334375E4589A5d9EEd81b7f);
    DealFeeRouter internal constant DEAL_FEE_ROUTER =
        DealFeeRouter(payable(0x15ff6F47076306E03aF8315BECf6137298D28446));
    address internal constant FEE_FLOOR = 0xc0DDA77ed245Ce78B7A8E7506c4cBcaE1a2A87e4;
    address internal constant NVDAX = 0x153c8D62895B82314f50d83499E5EE50eAC61dB3;
    address internal constant TSLAX = 0x0438Fc4B830091828582A3cCBbeF8abeEDFcFE20;
    address internal constant MSFTX = 0x9Ba1A162c3825a5962A56DDb5eAC862544753b14;
    address internal constant MOON = 0x5845eF6154052AE3001efE14DC873654269b8A18;
    address internal constant NVDOG = 0xF8d73A57EA78aaeA59F6212DB18aE20e6287a198;
    /// @dev The hosted keeper: the publication's sole filler, the only one the published factory admits.
    address internal constant FILLER = 0xa9CCD2D1fC2DFc61Da18cf007f906bDf687407a8;

    /// @dev The six vaults of the publication, by its ids: two NVDAx-only vaults (C rate floor, 5% and 15% fee) and
    /// the four universe vaults (B rate floor, 10%).
    IntentVault internal constant NVDA_LOW = IntentVault(0xdC84c106B4d5c5AD2EEd221e75Bba0Fa1aF42Be0);
    IntentVault internal constant NVDA_HIGH = IntentVault(0xDF53aE8730f9a7B5a4956Ac398012A861aFB4532);
    IntentVault internal constant STOCKS = IntentVault(0xE1a4B86928E7cbcEb23acf7A3acf8fAeACA9eD35);
    IntentVault internal constant MEMES = IntentVault(0xe3f5839ec7d1C134fb65F20D57127c6ebbE50A7A);
    IntentVault internal constant COMMODITIES = IntentVault(0x0C49FC64f45187000Fa575e5CE6D9A6A9200F54C);
    IntentVault internal constant RH_ECO = IntentVault(0xdC5C6b2977f8A5ABbd02E7149F6B1d1C42B54d37);
    /// @dev What the publication records of every vault's mandate beyond the bounds the vault keeps itself: the
    /// execution-fee ceiling it started with, and the secondary policy it was created with (`createWithSecondary`).
    /// The picked collateral is `_publishedPicks`.
    uint16 internal constant EXECUTION_CAP_BPS = 2000;
    bool internal constant SECONDARY_ENABLED = true;
    uint16 internal constant SECONDARY_EXTRA_BPS = 300;

    /// @dev The four vaults the fixture stages in, by the publication's role (see `_fixtureVault`): the published
    /// vault itself while it stands as published at the pin, otherwise its twin.
    IntentVault internal nvdaLowFee;
    IntentVault internal nvdaHighFee;
    IntentVault internal stockVault;
    IntentVault internal memeVault;

    /// @dev keccak256 of the creation bytecode each contract was deployed from, as the publication records them
    /// (`bytecodeHash`, `vaultCreationCodeHash`, `fillRouterBytecodeHash`, `verifierBytecodeHash`, `lensBytecodeHash`,
    /// `vaultCodeBytecodeHash`), and the settings extension's as audit-freeze.json records it.
    bytes32 internal constant FACTORY_CREATION_HASH =
        0xe0240ee38553d939edaa601a7b9fb45f93cb2338113edb038cefe951d2c48622;
    bytes32 internal constant VAULT_CREATION_HASH = 0xaaa0b36a1214f4c911dc17ebb84a4109e94625aeac8a23e0d0af95065e83a38b;
    bytes32 internal constant ROUTER_CREATION_HASH = 0x9865a68a8d3941e0df77ac89d35879a3b899a47fd826c9866ecd82d988970f87;
    bytes32 internal constant VERIFIER_CREATION_HASH =
        0xbedb50b193c350d730ad188932a4fed21891dad8700d83cf58fcdf95b85a6951;
    bytes32 internal constant LENS_CREATION_HASH = 0xeddb4d3877b7cc88b8e23e5017103dc3745d22bcb22286a278e820ccea94046c;
    bytes32 internal constant VAULT_CODE_CREATION_HASH =
        0x269ad4937490915f9e18a5880bd9d5844f93bc313e3a98a86cb548200a3e2bb8;
    bytes32 internal constant SETTINGS_CREATION_HASH =
        0xb97c77b59039681371d27b70674ea6716c1c2d32805f6aaab20dcd5a03e9f6f6;

    /// @dev The fork's fixture, all seven days on the zero-grace core. Principals are raw USDG units. Their ids are the
    /// core's next ids at the pin, and their terms and holders are read from the core, never taken from here.
    /// schedule: MSFTx, stocks alone; repaid 110 seconds into its term and booked an hour before any scenario starts,
    ///     so it is a D29 schedule already running in that vault's books. It is never repaid again.
    /// split A: NVDAx, held by three vaults (nvda-low-fee one unit, nvda-high-fee two, stocks one); funded six seconds
    ///     after the schedule, so the schedule's term ends first.
    /// split B: NVDAx, the two NVDAx vaults (nvda-low-fee three units, nvda-high-fee one).
    /// meme: MOON, memes alone.
    uint128 internal constant SCHEDULE_PRINCIPAL = 200e6;
    uint128 internal constant SPLIT_A_PRINCIPAL = 800e6;
    uint128 internal constant SPLIT_B_PRINCIPAL = 400e6;
    uint128 internal constant MEME_PRINCIPAL = 300e6;
    uint256 internal constant REPAID_AFTER = 110;
    /// @dev How long the booked schedule has run when the scenarios start.
    uint256 internal constant SCHEDULE_RUN = 1 hours;
    uint256 internal constant FILL_SPACING = 6;
    uint256 internal scheduleLoan;
    uint256 internal splitLoanA;
    uint256 internal splitLoanB;
    uint256 internal memeLoan;
    /// @dev The first listing of the fixture: where a scan of a vault's loans starts.
    uint256 internal firstListing;
    /// @dev The cash stocks held out of free liquidity for the schedule listing right after its booking.
    uint256 internal scheduleHeldAtBooking;

    uint256 internal constant VIRTUAL_SHARES = 1e12;
    uint40 internal constant NO_DEADLINE = type(uint40).max;

    uint256 internal pinnedBlock;
    bytes32 internal pinnedHash;
    uint256 internal pinnedTime;
    string internal scope;
    string[] internal notes;

    /// @dev The fork's actors. The depositor is the only holder of every vault the fixture fills, the borrower lists
    /// every loan.
    address internal immutable DEPOSITOR = makeAddr("s8-fork-depositor");
    address internal immutable BORROWER = makeAddr("s8-fork-borrower");
    address internal stranger = makeAddr("s8-fork-stranger");
    address internal entrant = makeAddr("s8-fork-late-entrant");
    address internal second = makeAddr("s8-fork-second-entrant");

    function setUp() public {
        string memory rpc = vm.envOr("INTENT_TESTNET_FORK_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 blk = vm.envOr("INTENT_TESTNET_FORK_BLOCK", uint256(0));
        if (blk == 0) {
            vm.createSelectFork(rpc);
            blk = (vm.getBlockNumber() - HEAD_MARGIN) / PIN_GRAIN * PIN_GRAIN;
        }
        vm.createSelectFork(rpc, blk);
        assertEq(block.chainid, CHAIN_ID, "Robinhood Chain testnet 46630 only");
        pinnedBlock = blk;
        pinnedTime = vm.getBlockTimestamp();
        // BLOCKHASH exposes the pinned header once the local block number has moved past it.
        vm.roll(blk + 1);
        pinnedHash = blockhash(blk);
        vm.roll(blk);
        vm.label(address(FACTORY), "IntentFactory");
        vm.label(address(ROUTER), "IntentFillRouter");
        vm.label(address(VERIFIER), "IntentQuoteVerifier");
        vm.label(address(VAULT_CODE), "IntentVaultCode");
        vm.label(address(CORE), "GageV2Vault");
        vm.label(address(RESERVE), "MorphoReserve");
        vm.label(address(USDG), "USDG");
        vm.label(address(DEAL_FEE_ROUTER), "DealFeeRouter");
        vm.label(FEE_FLOOR, "FeeFloor");
        vm.label(address(NVDA_LOW), "nvda-low-fee");
        vm.label(address(NVDA_HIGH), "nvda-high-fee");
        vm.label(address(STOCKS), "stocks");
        vm.label(address(MEMES), "memes");
        vm.label(address(COMMODITIES), "commodities");
        vm.label(address(RH_ECO), "rh-eco");
        emit log_named_uint("pinned block", blk);
    }

    // ================================================================ the tests

    function testPublishedIdentitiesAndBytecode() public {
        _identities();
    }

    /// @dev On the superseded S8 publication the hosted keeper had booked this repayment on chain; the published
    /// generation has none, so the fixture books it an hour before the scenario starts.
    function testRunningScheduleOfAnEarlyRepaymentBookedBeforehand() public {
        _identities();
        _stage();
        _runningSchedule();
    }

    function testEarlyRepaymentKeepsTheOriginalSchedule() public {
        _identities();
        _stage();
        _earlyRepayment();
    }

    function testOnTimeRepaymentPaysTheVaultTheManagerAndTheFeeRouter() public {
        _identities();
        _stage();
        _onTimeRepayment();
    }

    function testMultiVaultLoanRepaidIsDividedByUnits() public {
        _identities();
        _stage();
        _multiVaultRepayment();
    }

    function testDefaultAndRecoveryOfAStockLoanAcrossItsThreeVaults() public {
        _identities();
        _stage();
        _defaultAndRecovery("defaultStock", _trio(), _trioNames(), splitLoanA, true);
    }

    function testDefaultAndRecoveryOfAMemeLoan() public {
        _identities();
        _stage();
        _defaultAndRecovery("defaultMeme", _one(memeVault), _oneName("memes"), memeLoan, false);
    }

    function testWithdrawalsAboveFreeLiquidityTheReserveAndTheLastHolder() public {
        _identities();
        _stage();
        _withdrawals();
    }

    function testPermissionFailuresOnThePublishedContracts() public {
        _identities();
        _stage();
        _permissions();
    }

    function testSettingsChangeDoesNotTouchRunningLoans() public {
        _identities();
        _stage();
        _settingsChange();
    }

    function testFactoryRefusesAProtocolRecipientThatIsNotAFeeProcessor() public {
        _identities();
        _stage();
        _recipientGuard();
    }

    function testFundOnAVaultWithNoHoldersRevertsNoHolders() public {
        _identities();
        _stage();
        _noHolders();
    }

    function testADepositAfterTheLastHolderLeftIsPricedFairly() public {
        _identities();
        _stage();
        _depositAfterLastHolder();
    }

    /// @dev The generation is published with funding and deposits closed (the publication's `fundingEnabled` and
    /// `depositsEnabled`). What its activation brings on chain (testers supply the fixture vaults, the keeper funds
    /// their loans, managers move settings, testers admitted as creators add vaults) is done first on the fork: the
    /// identities still hold, the fixture stages in twins and leaves the testers' vaults as they were, and a scenario
    /// across three vaults still runs.
    function testTheFixtureStillStagesAfterTheGenerationIsActivated() public {
        uint256[4] memory supplies = _activate();
        _identities();
        _stage();
        IntentVault[] memory published = _publishedFixture();
        IntentVault[] memory staged = _fixture();
        for (uint256 v; v < staged.length; ++v) {
            assertTrue(address(staged[v]) != address(published[v]), "staged in a twin");
            assertEq(
                ILegacyIntentCreate(address(FACTORY)).creatorOf(address(staged[v])),
                published[v].CURATOR(),
                "created by the same manager"
            );
            assertEq(published[v].totalSupply(), supplies[v], "the published vault is left as the testers left it");
            assertEq(published[v].balanceOf(DEPOSITOR), 0);
        }
        _multiVaultRepayment();
    }

    /// @dev Every scenario again, each from the same staged state of one fork, and the evidence file.
    function testWritesTheLifecycleEvidenceFromOnePinnedBlock() public {
        string memory published = _identities();
        string memory staged = _stage();
        uint256 snapshot = vm.snapshotState();
        string memory o = "s8.scenarios";
        vm.serializeString(o, "1a_runningScheduleOfAnEarlyRepaymentBookedBeforehand", _runningSchedule());
        snapshot = _rewind(snapshot);
        vm.serializeString(o, "1b_freshEarlyRepayment", _earlyRepayment());
        snapshot = _rewind(snapshot);
        vm.serializeString(o, "2_onTimeRepayment", _onTimeRepayment());
        snapshot = _rewind(snapshot);
        vm.serializeString(o, "3_multiVaultRepayment", _multiVaultRepayment());
        snapshot = _rewind(snapshot);
        vm.serializeString(
            o,
            "4a_defaultAndRecoveryStockAcrossThreeVaults",
            _defaultAndRecovery("defaultStock", _trio(), _trioNames(), splitLoanA, true)
        );
        snapshot = _rewind(snapshot);
        vm.serializeString(
            o,
            "4b_defaultAndRecoveryMeme",
            _defaultAndRecovery("defaultMeme", _one(memeVault), _oneName("memes"), memeLoan, false)
        );
        snapshot = _rewind(snapshot);
        vm.serializeString(o, "5_withdrawals", _withdrawals());
        snapshot = _rewind(snapshot);
        vm.serializeString(o, "6_permissionFailures", _permissions());
        snapshot = _rewind(snapshot);
        vm.serializeString(o, "7_settingsChange", _settingsChange());
        snapshot = _rewind(snapshot);
        vm.serializeString(o, "8_recipientGuard_D30", _recipientGuard());
        snapshot = _rewind(snapshot);
        vm.serializeString(o, "9_noHolders_D31", _noHolders());
        snapshot = _rewind(snapshot);
        string memory scenarios = vm.serializeString(o, "10_depositAfterTheLastHolderLeft", _depositAfterLastHolder());
        _rewind(snapshot);

        o = "s8.pinned";
        _n(o, "blockNumber", pinnedBlock);
        vm.serializeBytes32(o, "blockHash", pinnedHash);
        string memory pinned = _n(o, "blockTimestamp", pinnedTime);

        o = "s8";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeString(o, "acceptance", "S8: the money lifecycle on the published testnet candidate");
        vm.serializeString(
            o,
            "publication",
            "launch/staging/staging-freeze-r1-20260925.publication.json (generation staging-freeze-r1-20260925, the audit freeze's testnet generation: docs/intent-v1/evidence/audit-freeze.json)"
        );
        vm.serializeString(o, "generation", GENERATION);
        vm.serializeString(o, "test", "contracts/test/fork/IntentCandidateTestnet.fork.t.sol");
        vm.serializeString(
            o,
            "method",
            "A local fork of testnet 46630 at one pinned block. Every call goes to the published contracts; time is vm.warp, callers are vm.prank, balances come from the mocks' public mint. The scenarios need sole depositors and loans of known shape, which no live state provides, so the fixture (staged) is made first through the published contracts: in each of the four published vaults it uses while that vault stands as published at the pin, otherwise in a twin its own manager creates through the published factory from the mandate it was published with (staged.fixtureVaults says which). Each scenario starts from that staged state again. Amounts are raw USDG units (6 decimals) unless a key says otherwise; a share price is USDG raw units per 1e18 shares, and the X1e18 figure is the same price with eighteen more digits."
        );
        vm.serializeString(
            o,
            "forkOnly",
            "What exists only on the fork: a quote signer the factory's owner names (the hosted signer's key is held by nobody); grades and modeled costs republished unchanged by the grade registry's own publisher; the twin of any fixture vault that no longer stands as published; the depositor's deposits into the four fixture vaults; the borrower's listings; the four loans the admitted filler funds through the published router with plans that signer signs; the early repayment of the schedule listing and its booking an hour before the scenarios start; the further listings of scenarios 7 and 9; the admitted filler's reserve investments (scenarios 5, 9 and 10); and one fresh vault an admitted manager creates (scenario 9)."
        );
        _n(o, "checkedAtUnixMs", vm.unixTime());
        vm.serializeBool(o, "localForkOnly", true);
        vm.serializeBool(o, "mainnetMutations", false);
        vm.serializeBool(o, "testnetMutations", false);
        vm.serializeString(o, "pinned", pinned);
        vm.serializeString(o, "published", published);
        vm.serializeString(o, "staged", staged);
        vm.writeJson(vm.serializeString(o, "scenarios", scenarios), EVIDENCE);
    }

    function _rewind(uint256 snapshot) internal returns (uint256) {
        assertTrue(vm.revertToState(snapshot), "back to the staged state");
        return vm.snapshotState();
    }

    // ================================================================ identities

    struct Replayed {
        bytes32 published;
        bytes32 replayed;
    }

    /// @dev Who names whom, and that the code at the published addresses is what this source compiles to.
    function _identities() internal returns (string memory) {
        scope = "identity";
        assertEq(block.chainid, CHAIN_ID);
        assertEq(vm.getBlockNumber(), pinnedBlock, "pinned");
        // Factory <-> router <-> verifier, and the core, reserve, lens and grades they all share.
        assertEq(FACTORY.fillRouter(), address(ROUTER), "factory names the router");
        assertEq(address(ROUTER.FACTORY()), address(FACTORY), "router names the factory");
        assertEq(address(ROUTER.VERIFIER()), address(VERIFIER), "router names the verifier");
        assertEq(address(VERIFIER.FACTORY()), address(FACTORY), "verifier names the factory");
        assertEq(address(VERIFIER.CORE()), address(CORE));
        assertEq(address(ROUTER.CORE()), address(CORE));
        assertEq(address(ROUTER.USDG()), address(USDG));
        assertEq(FACTORY.CORE(), address(CORE));
        assertEq(FACTORY.RESERVE(), address(RESERVE));
        assertEq(FACTORY.RESERVE_LENS(), address(LENS));
        assertEq(FACTORY.GRADES(), address(GRADES));
        assertEq(FACTORY.owner(), ADMIN, "admin");
        // The publication's six come first, in creation order (below); creators the owner admits later add theirs.
        assertGe(FACTORY.count(), 6, "the publication's six vaults, and any created since");
        assertEq(FACTORY.protocolRecipient(), address(DEAL_FEE_ROUTER), "protocol recipient is the DealFeeRouter");
        assertEq(
            ILegacyFillerPayout(address(FACTORY)).fillerPayout(FILLER),
            address(DEAL_FEE_ROUTER),
            "and so is the keeper's payout"
        );
        assertEq(address(DEAL_FEE_ROUTER.USDG()), address(USDG));
        assertEq(address(DEAL_FEE_ROUTER.FLOOR()), FEE_FLOOR, "the floor that router deposits into");
        assertTrue(FACTORY.quoteSigner() != address(0), "a quote signer is named");
        assertTrue(FACTORY.isFiller(FILLER), "the hosted keeper is the admitted filler");
        // D49: the filler's share of execution fees is zero in code, so every execution fee is the protocol's.
        assertEq(
            ILegacyFillRouter(address(ROUTER)).MAX_FILLER_SHARE_BPS(), 0, "D49: the filler's share is locked at zero"
        );
        assertEq(ILegacyFillRouter(address(ROUTER)).fillerShareBps(), 0);
        assertEq(CORE.GRACE(), 0, "zero-grace core");
        assertEq(address(CORE.USDG()), address(USDG));
        // D42, D47: the core lends only to accounts its funder gate names, and the gate is this factory's vaults.
        assertEq(address(CORE.REWARDS().funderGate()), address(FACTORY), "D47: the core's funder gate is bound");
        assertEq(RESERVE.asset(), address(USDG));
        // The factory reads the vault's creation code from the published store and runs settings in its extension.
        assertEq(VAULT_CODE.INIT_HASH(), VAULT_CREATION_HASH, "the store holds the published vault's creation code");
        assertEq(
            ILegacySettings(address(FACTORY)).SETTINGS(),
            vm.computeCreateAddress(address(FACTORY), 1),
            "the factory's settings extension"
        );
        IntentVault[] memory all = _all();
        for (uint256 v; v < all.length; ++v) {
            assertEq(FACTORY.vaults(v), address(all[v]), "the publication's vaults, in creation order");
            _assertVault(all[v]);
        }

        // The local build is the recorded build.
        assertEq(keccak256(type(IntentFactory).creationCode), FACTORY_CREATION_HASH, "factory creation code");
        assertEq(keccak256(type(IntentFillRouter).creationCode), ROUTER_CREATION_HASH, "router creation code");
        assertEq(keccak256(type(IntentQuoteVerifier).creationCode), VERIFIER_CREATION_HASH, "verifier creation code");
        assertEq(keccak256(type(MorphoV2ReserveLens).creationCode), LENS_CREATION_HASH, "lens creation code");
        assertEq(keccak256(type(IntentVaultCode).creationCode), VAULT_CODE_CREATION_HASH, "code store creation code");
        // No settings creation code: this source has no settings extension (IV-a-01 folded the curator settings back
        // into the vault). The published extension's runtime is recorded below, with nothing here to compare it with.

        // The published factory deploys exactly this source's vault, the one the record names.
        bytes32 vaultInit = keccak256(type(IntentVault).creationCode);
        assertEq(vaultInit, VAULT_CREATION_HASH, "vault creation code");
        assertEq(FACTORY.VAULT_INIT_HASH(), vaultInit, "published VAULT_INIT_HASH is this source's vault");
        assertEq(
            keccak256(IStoredVaultCode(address(FACTORY)).vaultCreationCode()),
            vaultInit,
            "and the stored creation code hashes to it"
        );

        // The runtime at each published address is what that creation code leaves there: the constructor is run
        // again at the same address with the same arguments, and the result compared byte for byte.
        Replayed memory factory = _replayFactory();
        Replayed memory router =
            _replay(address(ROUTER), type(IntentFillRouter).creationCode, abi.encode(address(VERIFIER), address(USDG)));
        Replayed memory verifier =
            _replay(address(VERIFIER), type(IntentQuoteVerifier).creationCode, abi.encode(address(FACTORY)));
        Replayed memory lens = _replay(address(LENS), type(MorphoV2ReserveLens).creationCode, "");
        Replayed memory store =
            _replayCreating(address(VAULT_CODE), type(IntentVaultCode).creationCode, "", 2, address(this));
        bytes32 settingsRuntime = keccak256(ILegacySettings(address(FACTORY)).SETTINGS().code);
        assertEq(factory.replayed, factory.published, "factory runtime");
        assertEq(router.replayed, router.published, "router runtime");
        assertEq(verifier.replayed, verifier.published, "verifier runtime");
        assertEq(lens.replayed, lens.published, "lens runtime");
        assertEq(store.replayed, store.published, "code store runtime");

        string memory o = _o("bytecode");
        vm.serializeString(
            o,
            "method",
            "creation: keccak256 of this build's creation code against the hash the publication records, the vault's and the code store's included, and the published factory's VAULT_INIT_HASH and the store's INIT_HASH against the same. runtime: the same creation code run again at the published address with the published constructor arguments (and, for a contract that creates helpers, from the nonce it created them at), compared with the code that is there."
        );
        vm.serializeBytes32(o, "factoryCreationRecorded", FACTORY_CREATION_HASH);
        vm.serializeBytes32(o, "vaultCreationRecorded", VAULT_CREATION_HASH);
        vm.serializeBytes32(o, "routerCreationRecorded", ROUTER_CREATION_HASH);
        vm.serializeBytes32(o, "verifierCreationRecorded", VERIFIER_CREATION_HASH);
        vm.serializeBytes32(o, "lensCreationRecorded", LENS_CREATION_HASH);
        vm.serializeBytes32(o, "vaultCodeCreationRecorded", VAULT_CODE_CREATION_HASH);
        vm.serializeBytes32(o, "settingsCreationRecorded", SETTINGS_CREATION_HASH);
        vm.serializeBool(o, "creationHashesMatchThisBuild", true);
        vm.serializeBytes32(o, "vaultInitHashPublished", FACTORY.VAULT_INIT_HASH());
        vm.serializeBytes32(o, "vaultInitHashThisBuild", vaultInit);
        vm.serializeBytes32(o, "factoryRuntime", factory.published);
        vm.serializeBytes32(o, "routerRuntime", router.published);
        vm.serializeBytes32(o, "verifierRuntime", verifier.published);
        vm.serializeBytes32(o, "lensRuntime", lens.published);
        vm.serializeBytes32(o, "vaultCodeRuntime", store.published);
        vm.serializeBytes32(o, "settingsRuntime", settingsRuntime);
        string[] memory names = _allNames();
        for (uint256 v; v < all.length; ++v) {
            vm.serializeBytes32(o, string.concat(names[v], "Runtime"), _replayVault(all[v]));
        }
        string memory bytecode = vm.serializeBool(o, "runtimesMatchThisBuild", true);

        o = _o("published");
        vm.serializeString(o, "generation", GENERATION);
        vm.serializeAddress(o, "factory", address(FACTORY));
        vm.serializeAddress(o, "fillRouter", address(ROUTER));
        vm.serializeAddress(o, "quoteVerifier", address(VERIFIER));
        vm.serializeAddress(o, "vaultCode", address(VAULT_CODE));
        vm.serializeAddress(o, "settings", ILegacySettings(address(FACTORY)).SETTINGS());
        vm.serializeAddress(o, "quoteSigner", FACTORY.quoteSigner());
        vm.serializeAddress(o, "admittedFiller", FILLER);
        vm.serializeAddress(o, "admittedFillerPayout", ILegacyFillerPayout(address(FACTORY)).fillerPayout(FILLER));
        vm.serializeAddress(o, "core", address(CORE));
        vm.serializeAddress(o, "coreFunderGate", address(CORE.REWARDS().funderGate()));
        vm.serializeAddress(o, "reserve", address(RESERVE));
        vm.serializeAddress(o, "reserveLens", address(LENS));
        vm.serializeAddress(o, "gradeRegistry", address(GRADES));
        vm.serializeAddress(o, "admin", ADMIN);
        vm.serializeAddress(o, "protocolRecipient", FACTORY.protocolRecipient());
        vm.serializeAddress(o, "dealFeeRouter", address(DEAL_FEE_ROUTER));
        vm.serializeAddress(o, "feeFloor", FEE_FLOOR);
        vm.serializeAddress(o, "usdg", address(USDG));
        for (uint256 v; v < all.length; ++v) {
            vm.serializeAddress(o, names[v], address(all[v]));
        }
        _n(o, "coreGrace", CORE.GRACE());
        _n(o, "coreLoanCount", CORE.loanCount());
        _n(o, "factoryVaultCount", FACTORY.count());
        _n(o, "fillerShareBps", ILegacyFillRouter(address(ROUTER)).fillerShareBps());
        vm.serializeBool(o, "identitiesHold", true);
        return vm.serializeString(o, "bytecode", bytecode);
    }

    function _assertVault(IntentVault vault) internal view {
        assertTrue(FACTORY.isVault(address(vault)), "isVault");
        assertEq(vault.PROTOCOL_SOURCE(), address(FACTORY));
        assertEq(address(vault.VAULT()), address(CORE));
        assertEq(address(vault.RESERVE()), address(RESERVE));
        assertEq(address(vault.RESERVE_LENS()), address(LENS));
        assertEq(address(vault.GRADES()), address(GRADES));
        assertEq(address(vault.USDG()), address(USDG));
        assertEq(ILegacySettings(address(vault)).SETTINGS(), ILegacySettings(address(FACTORY)).SETTINGS());
    }

    /// @dev The fork's depositor is each staged vault's only depositor, so it is both every holder of record and the
    /// last.
    function _assertSoleHolder(IntentVault vault) internal view {
        assertEq(vault.balanceOf(DEPOSITOR), vault.totalSupply(), "the fork's depositor is the vault's only depositor");
        assertGt(vault.totalSupply(), 0);
    }

    /// @dev Run `creation ++ args` at `published` and return the runtime it leaves, against the code that is there.
    function _replay(address published, bytes memory creation, bytes memory args) internal returns (Replayed memory r) {
        return _replayCreating(published, creation, args, 0, address(this));
    }

    /// @dev The same, for a contract whose constructor creates `created` contracts at its nonces 1 onward and keeps
    /// their addresses as immutables: the replay starts from nonce 1 with those addresses empty, so it creates them
    /// at the same addresses again. `deployer` calls the constructor: a vault reads its factory's getters from it.
    function _replayCreating(
        address published,
        bytes memory creation,
        bytes memory args,
        uint64 created,
        address deployer
    ) internal returns (Replayed memory r) {
        r.published = keccak256(published.code);
        uint256 snapshot = vm.snapshotState();
        for (uint64 nonce = 1; nonce <= created; ++nonce) {
            address made = vm.computeCreateAddress(published, nonce);
            assertGt(made.code.length, 0, "the published contract's own creation");
            vm.etch(made, "");
            vm.setNonceUnsafe(made, 0);
        }
        if (created != 0) vm.setNonceUnsafe(published, 1);
        vm.etch(published, abi.encodePacked(creation, args));
        vm.prank(deployer);
        (bool ok, bytes memory runtime) = published.call("");
        vm.revertToState(snapshot);
        require(ok, "replay: the constructor reverted");
        r.replayed = keccak256(runtime);
    }

    /// @dev The published factory created its settings extension at its nonce 1 and reads the vault's creation code
    /// from the published store, whose two data contracts it keeps as immutables. This source's factory creates no
    /// extension (IV-a-01) and is given the two data contracts themselves: the published store's.
    function _replayFactory() internal returns (Replayed memory) {
        bytes memory args = abi.encode(
            IntentFactory.Params({
                core: address(CORE),
                reserve: address(RESERVE),
                reserveLens: address(LENS),
                grades: address(GRADES),
                // Storage only; neither reaches the runtime code.
                protocolRecipient: address(DEAL_FEE_ROUTER),
                initialOwner: ADMIN,
                codeA: VAULT_CODE.CHUNK_A(),
                codeB: VAULT_CODE.CHUNK_B()
            })
        );
        return _replayCreating(address(FACTORY), type(IntentFactory).creationCode, args, 0, address(this));
    }

    /// @dev A vault's runtime depends on its core, reserve, lens, grades, factory, curator, longest term and fee (a
    /// published vault's also on its settings extension), and on the asset policy and lender market it creates at its
    /// nonces 1 and 2; every other mandate value, the execution-fee ceiling and the secondary policy among them, is
    /// storage. The category weights only have to name a universe, and the asset list is left empty (it is the
    /// policy's storage).
    function _replayVault(IntentVault vault) internal returns (bytes32) {
        IntentVault.Mandate memory m = _mandateOf(vault, new address[](0));
        assertEq(address(vault.ASSET_POLICY()), vm.computeCreateAddress(address(vault), 1), "the vault's asset policy");
        assertEq(address(vault.LENDER_MARKET()), vm.computeCreateAddress(address(vault), 2), "and its lender market");
        // This source's vault reads its core, reserve, lens and grades from its deployer, the factory. The secondary
        // policy is the policy's storage, not the vault's runtime.
        Replayed memory r = _replayCreating(
            address(vault), type(IntentVault).creationCode, abi.encode(m, false, uint16(0)), 2, address(FACTORY)
        );
        assertEq(r.replayed, r.published, "vault runtime");
        return r.published;
    }

    /// @dev The mandate `vault` was created with, as far as the vault keeps it: its creation-time bounds (the
    /// category ceilings are the weights it started with), with `picks` as its collateral and the publication's
    /// execution-fee ceiling.
    function _mandateOf(IntentVault vault, address[] memory picks)
        internal
        view
        returns (IntentVault.Mandate memory m)
    {
        m.curator = vault.CURATOR();
        m.categoryWeights = [
            ILegacyIntentBounds(address(vault)).categoryCeilingBps(IntentCategory.STOCK),
            ILegacyIntentBounds(address(vault)).categoryCeilingBps(IntentCategory.MEME),
            ILegacyIntentBounds(address(vault)).categoryCeilingBps(IntentCategory.RH_ECOSYSTEM),
            ILegacyIntentBounds(address(vault)).categoryCeilingBps(IntentCategory.COMMODITY)
        ];
        m.assets = picks;
        m.maxLoanTerm = vault.MAX_TERM();
        m.feeBps = vault.feeBps();
        m.minGrade = vault.MIN_GRADE_FLOOR();
        m.minRateGrade = ILegacyIntentBounds(address(vault)).MIN_RATE_GRADE_FLOOR();
        m.maxLoanPrincipal = ILegacyIntentBounds(address(vault)).MAX_LOAN_PRINCIPAL();
        m.maxAssetBps = ILegacyIntentBounds(address(vault)).MAX_ASSET_BPS();
        m.bufferBps = ILegacyIntentBounds(address(vault)).MIN_BUFFER_BPS();
        m.executionCapBps = EXECUTION_CAP_BPS;
    }

    // ================================================================ the fork's fixture

    /// @dev What the scenarios need and no live state provides, made through the published contracts as the hosted
    /// keeper and its users would: deposits, four loans the admitted filler funds through the published router, and
    /// one early repayment booked by a settle an hour before any scenario starts. The loans repeat the shape of the
    /// fixture the superseded S8 publication held on chain (see `SCHEDULE_PRINCIPAL`); every scenario reads them from
    /// the core.
    function _stage() internal returns (string memory) {
        scope = "staged";
        string memory vaults = _openForTheFixture();
        _refreshGrades();
        _forkSigner();
        _deposit(nvdaLowFee, 1000e6);
        _deposit(nvdaHighFee, 1000e6);
        _deposit(stockVault, 1500e6);
        _deposit(memeVault, 1000e6);
        uint256 t0 = vm.getBlockTimestamp();
        firstListing = CORE.loanCount() + 1;
        scheduleLoan = _fill(MSFTX, SCHEDULE_PRINCIPAL, _one(stockVault), _units(4, 0, 0));
        vm.warp(t0 + FILL_SPACING);
        splitLoanA = _fill(NVDAX, SPLIT_A_PRINCIPAL, _trio(), _units(1, 2, 1));
        vm.warp(t0 + 2 * FILL_SPACING);
        IntentVault[] memory pair = new IntentVault[](2);
        (pair[0], pair[1]) = (nvdaLowFee, nvdaHighFee);
        splitLoanB = _fill(NVDAX, SPLIT_B_PRINCIPAL, pair, _units(3, 1, 0));
        vm.warp(t0 + 3 * FILL_SPACING);
        memeLoan = _fill(MOON, MEME_PRINCIPAL, _one(memeVault), _units(4, 0, 0));
        assertEq(firstListing, scheduleLoan);
        assertEq(memeLoan, CORE.loanCount(), "the fixture's four listings are the core's latest");

        // The schedule listing is repaid early and booked, as the hosted keeper would, and its schedule then runs for
        // an hour before any scenario starts.
        vm.warp(t0 + REPAID_AFTER);
        _repay(scheduleLoan);
        vm.prank(FILLER);
        stockVault.settle(_ids(scheduleLoan));
        IntentVault.Loan memory booked = _held(stockVault, scheduleLoan);
        assertTrue(booked.repaid && !booked.settled, "booked, and running as a schedule");
        assertEq(CORE.cashCredit(address(stockVault)), 0, "the booking pulled the cash");
        scheduleHeldAtBooking = IIntentVaultD29(address(stockVault)).unearnedInterest();
        assertGt(scheduleHeldAtBooking, 0, "the part not yet earned is held");
        vm.warp(t0 + REPAID_AFTER + SCHEDULE_RUN);

        string memory o = _o("fixture");
        vm.serializeString(o, "fixtureVaults", vaults);
        vm.serializeAddress(o, "depositor", DEPOSITOR);
        vm.serializeAddress(o, "borrower", BORROWER);
        vm.serializeAddress(o, "forkQuoteSigner", FACTORY.quoteSigner());
        _n(o, "depositNvdaLowFee", 1000e6);
        _n(o, "depositNvdaHighFee", 1000e6);
        _n(o, "depositStocks", 1500e6);
        _n(o, "depositMemes", 1000e6);
        _n(o, "stagedFrom", t0);
        _n(o, "scheduleListing", scheduleLoan);
        _n(o, "splitListingA", splitLoanA);
        _n(o, "splitListingB", splitLoanB);
        _n(o, "memeListing", memeLoan);
        _n(o, "scheduleRepaidAndBookedAt", t0 + REPAID_AFTER);
        _n(o, "heldUnearnedCashAtTheBooking", scheduleHeldAtBooking);
        vm.serializeString(
            o,
            "what",
            "Made on the fork through the published contracts before any scenario, in the four fixture vaults (fixtureVaults: each published vault while it stands as published at the pin, otherwise its twin): the depositor deposits into nvda-low-fee, nvda-high-fee, stocks and memes; the borrower lists MSFTx, NVDAx twice and MOON for seven days; the admitted filler funds each through the published router with a plan the fork's signer signs (the schedule listing by stocks alone; split A by nvda-low-fee one unit, nvda-high-fee two and stocks one; split B by nvda-low-fee three units and nvda-high-fee one; the meme listing by memes alone). The schedule listing is repaid 110 seconds into its term and booked by a settle, so it runs as a D29 schedule in stocks, for an hour before the scenarios start."
        );
        return _n(o, "stagedUntil", vm.getBlockTimestamp());
    }

    /// @dev Choose the four fixture vaults, and open new deals. The depositor is to be each fixture vault's only
    /// holder and its loans the fixture's own, so a published vault that no longer stands as published at the pin
    /// (testers deposit and the keeper funds once the generation is activated) is replaced by its twin. A pause of new
    /// deals on the core's registry or on the legacy V1 registry behind the bridge, or a fixture vault its manager
    /// paused or closed to fillers, is lifted on the fork by its own owner or manager, so a live switch cannot decide
    /// the run.
    /// @return json The fixture vaults, and for each whether it is the published one or a twin, and why.
    function _openForTheFixture() internal returns (string memory json) {
        _unpause(IDealsPause(address(CORE.REGISTRY())));
        _unpause(IDealsPause(ILegacyDealVault(address(CORE.BRIDGE().VAULT())).REGISTRY()));
        (nvdaLowFee, json) = _fixtureVault(NVDA_LOW, "nvdaLowFee");
        (nvdaHighFee, json) = _fixtureVault(NVDA_HIGH, "nvdaHighFee");
        (stockVault, json) = _fixtureVault(STOCKS, "stocks");
        (memeVault, json) = _fixtureVault(MEMES, "memes");
        IntentVault[] memory staged = _fixture();
        for (uint256 v; v < staged.length; ++v) {
            IntentVault vault = staged[v];
            assertEq(vault.totalSupply(), 0, "the fixture's vault holds no deposit");
            vm.startPrank(vault.CURATOR());
            if (vault.paused()) vault.setPaused(false);
            if (!vault.fillersOpen()) vault.setFillersOpen(true);
            vm.stopPrank();
        }
    }

    /// @dev The published vault while it stands as published, otherwise its twin; recorded under `name`.
    function _fixtureVault(IntentVault published, string memory name)
        internal
        returns (IntentVault vault, string memory json)
    {
        string memory drift = _drift(published, _publishedPicks(published));
        bool stands = bytes(drift).length == 0;
        vault = stands ? published : _twin(published);
        if (!stands) vm.label(address(vault), string.concat(name, "-twin"));
        string memory o = _o("fixtureVaults");
        vm.serializeAddress(o, name, address(vault));
        json = vm.serializeString(
            o,
            string.concat(name, "Is"),
            stands
                ? "the published vault itself: it stands as published at the pin"
                : string.concat(
                    "a twin of the published ",
                    vm.toString(address(published)),
                    ", created on the fork by its manager through the published factory, because ",
                    drift
                )
        );
    }

    /// @dev Why a vault no longer stands as the publication left it, or nothing while it does. The fixture needs no
    /// share, USDG, reserve position, open loan or side pocket in it, and every setting a scenario relies on still its
    /// creation value: its limits and floors, its category weights, the publication's `picks` and execution-fee
    /// ceiling, and its manager as fee recipient. A pause, or fillers closed, is lifted instead.
    function _drift(IntentVault vault, address[] memory picks) internal view returns (string memory) {
        if (vault.totalSupply() != 0) return "it holds deposits";
        if (USDG.balanceOf(address(vault)) != 0 || vault.reserveShares() != 0) {
            return "it holds USDG or a reserve position";
        }
        if (vault.performingPrincipal() != 0 || vault.earliestMaturity() != NO_DEADLINE) return "it holds a loan";
        if (vault.pocketCount() != 0) return "it holds a side pocket";
        if (
            vault.maxLoanPrincipal() != ILegacyIntentBounds(address(vault)).MAX_LOAN_PRINCIPAL()
                || vault.maxAssetBps() != ILegacyIntentBounds(address(vault)).MAX_ASSET_BPS()
                || vault.bufferBps() != ILegacyIntentBounds(address(vault)).MIN_BUFFER_BPS()
        ) return "its manager moved its limits";
        if (
            vault.minGrade() != vault.MIN_GRADE_FLOOR()
                || vault.minRateGrade() != ILegacyIntentBounds(address(vault)).MIN_RATE_GRADE_FLOOR()
        ) {
            return "its manager moved a grade floor";
        }
        for (uint256 c; c < 4; ++c) {
            if (
                vault.categoryWeightBps(IntentCategory(c))
                    != ILegacyIntentBounds(address(vault)).categoryCeilingBps(IntentCategory(c))
            ) {
                return "its manager moved a category weight";
            }
        }
        if (ILegacyIntentVault(address(vault)).pickedAssets() != picks.length) return "its manager changed its picks";
        for (uint256 i; i < picks.length; ++i) {
            if (!ILegacyIntentVault(address(vault)).assetPicked(picks[i])) return "its manager changed its picks";
        }
        if (vault.executionCapBps() != EXECUTION_CAP_BPS) return "its manager moved its execution-fee ceiling";
        if (vault.feeRecipient() != vault.CURATOR()) return "its manager moved its fee recipient";
        return "";
    }

    /// @dev A vault the published factory creates on the fork for `published`'s own manager, from the mandate that
    /// vault was published with (`_mandateOf`, with the publication's picks) and its secondary policy. The identities
    /// show that factory deploys this source's vault; the twin's runtime is replayed as well. A manager whose
    /// admission as a creator was withdrawn since is admitted again by the factory's owner, on the fork only.
    function _twin(IntentVault published) internal returns (IntentVault twin) {
        address manager = published.CURATOR();
        if (!FACTORY.openCreation() && !FACTORY.isCreator(manager)) {
            vm.prank(ADMIN);
            FACTORY.setCreator(manager, true);
        }
        IntentVault.Mandate memory m = _mandateOf(published, _publishedPicks(published));
        uint256 index = FACTORY.count();
        vm.prank(manager);
        twin = IntentVault(
            ILegacyIntentCreate(address(FACTORY)).createWithSecondary(m, SECONDARY_ENABLED, SECONDARY_EXTRA_BPS)
        );
        assertEq(FACTORY.vaults(index), address(twin), "listed by the published factory");
        assertEq(ILegacyIntentCreate(address(FACTORY)).creatorOf(address(twin)), manager);
        _assertVault(twin);
        assertEq(keccak256(abi.encode(_mandateOf(twin, m.assets))), keccak256(abi.encode(m)), "the same mandate");
        assertEq(twin.CATEGORY_MASK(), published.CATEGORY_MASK());
        assertEq(twin.ASSET_POLICY().secondaryEnabled(), SECONDARY_ENABLED);
        assertEq(twin.ASSET_POLICY().minExtraAnnualReturnBps(), SECONDARY_EXTRA_BPS);
        assertEq(bytes(_drift(twin, m.assets)).length, 0, "the twin stands as its original was published");
        _replayVault(twin);
    }

    /// @dev The collateral each published vault the fixture uses was created with (the publication's `assets`).
    function _publishedPicks(IntentVault published) internal pure returns (address[] memory picks) {
        address vault = address(published);
        if (vault == address(NVDA_LOW) || vault == address(NVDA_HIGH)) {
            picks = new address[](1);
            picks[0] = NVDAX;
        } else if (vault == address(STOCKS)) {
            picks = new address[](3);
            (picks[0], picks[1], picks[2]) = (NVDAX, TSLAX, MSFTX);
        } else if (vault == address(MEMES)) {
            picks = new address[](2);
            (picks[0], picks[1]) = (MOON, NVDOG);
        } else {
            revert("not a published fixture vault");
        }
    }

    /// @dev On the fork, what the activation of the generation brings: a tester deposits into nvda-low-fee,
    /// nvda-high-fee and stocks, the admitted filler funds a listing from nvda-low-fee through the published router,
    /// memes' manager lowers its cap per loan, and a tester the factory's owner admits creates a seventh vault.
    /// @return supplies The share supply each published fixture vault is left with, by role.
    function _activate() internal returns (uint256[4] memory supplies) {
        scope = "activated";
        _unpause(IDealsPause(address(CORE.REGISTRY())));
        _unpause(IDealsPause(ILegacyDealVault(address(CORE.BRIDGE().VAULT())).REGISTRY()));
        _refreshGrades();
        address tester = makeAddr("s8-fork-tester");
        IntentVault[] memory published = _publishedFixture();
        for (uint256 v; v < 3; ++v) {
            IntentVault vault = published[v];
            vm.startPrank(vault.CURATOR());
            if (vault.paused()) vault.setPaused(false);
            if (!vault.fillersOpen()) vault.setFillersOpen(true);
            vm.stopPrank();
            IMintable(address(USDG)).mint(tester, 500e6);
            vm.startPrank(tester);
            USDG.approve(address(vault), 500e6);
            vault.deposit(500e6, 0);
            vm.stopPrank();
        }
        _fill(NVDAX, 100e6, _one(NVDA_LOW), _units(4, 0, 0));
        uint128 cap = ILegacyIntentBounds(address(MEMES)).MAX_LOAN_PRINCIPAL() / 2;
        uint16 assetBps = MEMES.maxAssetBps();
        uint16 buffer = MEMES.bufferBps();
        vm.prank(MEMES.CURATOR());
        ILegacyIntentBounds(address(MEMES)).setLimits(cap, assetBps, buffer);
        IntentVault.Mandate memory m = _mandateOf(NVDA_HIGH, _publishedPicks(NVDA_HIGH));
        m.curator = tester;
        vm.prank(ADMIN);
        FACTORY.setCreator(tester, true);
        uint256 count = FACTORY.count();
        vm.prank(tester);
        ILegacyIntentCreate(address(FACTORY)).create(m);
        assertEq(FACTORY.count(), count + 1, "a tester's vault joins the publication's");
        for (uint256 v; v < published.length; ++v) {
            assertGt(bytes(_drift(published[v], _publishedPicks(published[v]))).length, 0, "no longer as published");
            supplies[v] = published[v].totalSupply();
        }
    }

    function _unpause(IDealsPause registry) internal {
        if (!registry.newDealsPaused()) return;
        vm.prank(registry.owner());
        registry.pauseNewDeals(false);
    }

    /// @dev The grade registry's own publisher publishes again, unchanged, the grade and seven-day modeled cost it last
    /// published for each fixture token, so a publisher stopped for more than `MAX_AGE` cannot age them out.
    function _refreshGrades() internal {
        address[] memory tokens = new address[](4);
        (tokens[0], tokens[1], tokens[2], tokens[3]) = (NVDAX, TSLAX, MSFTX, MOON);
        uint8[] memory ranks = new uint8[](4);
        uint32[] memory terms = new uint32[](4);
        uint32[] memory costs = new uint32[](4);
        for (uint256 i; i < tokens.length; ++i) {
            (ranks[i],) = GRADES.grades(tokens[i]);
            terms[i] = 7 days;
            (costs[i],) = GRADES.modeledCosts(tokens[i], 7 days);
            assertGt(ranks[i], 0, "a grade was published for the token");
            assertGt(costs[i], 0, "and a seven-day modeled cost");
        }
        address publisher = GRADES.publisher();
        vm.startPrank(publisher);
        GRADES.setGrades(tokens, ranks);
        GRADES.setModeledCosts(tokens, terms, costs);
        vm.stopPrank();
    }

    function _deposit(IntentVault vault, uint256 assets) internal {
        IMintable(address(USDG)).mint(DEPOSITOR, assets);
        vm.startPrank(DEPOSITOR);
        USDG.approve(address(vault), assets);
        vault.deposit(assets, 0);
        vm.stopPrank();
    }

    /// @dev A new listing, funded whole by `vaults` (taking `units` each) through the published router.
    function _fill(address token, uint128 principal, IntentVault[] memory vaults, uint8[] memory units)
        internal
        returns (uint256 id)
    {
        (id,) = _newListing(token, principal);
        IntentQuoteVerifier.Plan memory plan = _planFor(id, vaults, units);
        uint256[] memory limits = new uint256[](vaults.length);
        for (uint256 i; i < limits.length; ++i) {
            limits[i] = type(uint256).max;
        }
        bytes memory signature = _sign(_forkSigner(), plan);
        vm.prank(FILLER);
        ROUTER.fill(plan, signature, limits);
        assertEq(uint8(CORE.getLoan(id).state), uint8(V2State.ACTIVE), "the fill activated the listing");
    }

    function _units(uint8 a, uint8 b, uint8 c) internal pure returns (uint8[] memory units) {
        uint256 count = c != 0 ? 3 : b != 0 ? 2 : 1;
        units = new uint8[](count);
        units[0] = a;
        if (count > 1) units[1] = b;
        if (count > 2) units[2] = c;
    }

    // ================================================================ 1a. an early repayment booked beforehand (D29)

    struct Running {
        Book pinned;
        Book redeemed;
        Book midway;
        Book termEnd;
        Book released;
        IntentVault.Loan loan;
        uint256 redeemedShares;
        uint256 redeemedAssets;
        uint256 leftBehind;
    }

    /// @dev The schedule listing was repaid 110 seconds into its seven days and booked by a settle when the fixture was
    /// staged, an hour before this scenario starts. Nothing is repaid here: the schedule that booking left in stocks'
    /// books, running since, is followed to its end.
    function _runningSchedule() internal returns (string memory) {
        scope = "running";
        IntentVault vault = stockVault;
        uint256 id = scheduleLoan;
        Running memory r;
        V2Loan memory l = CORE.getLoan(id);
        assertEq(uint8(l.state), uint8(V2State.REPAID), "repaid before the scenario starts");
        assertEq(CORE.unitsOf(id, address(vault)), 4, "stocks holds all four units");
        uint256 maturity = uint256(l.fundedAt) + l.term;
        assertLt(l.closedAt, maturity, "before the end of its term");
        assertEq(CORE.cashCredit(address(vault)), 0, "the booking already pulled the cash");
        r.loan = _held(vault, id);
        assertTrue(r.loan.repaid && !r.loan.settled, "booked, and still in the open set until the term ends");
        assertEq(r.loan.principal, l.principal);
        assertEq(r.loan.maturity, maturity, "same end");
        assertGt(r.loan.rate, 0, "same rate, still running");
        (uint256 fee,) = _performanceFee(r.loan, l.cap);
        assertEq(r.loan.interest, (l.cap - l.principal) - fee, "its net interest is the cost less the manager fee");
        _assertSoleHolder(vault);
        uint256 t0 = vm.getBlockTimestamp();
        assertLt(t0, maturity, "still in term at the start");
        assertGe(t0 - l.closedAt, SCHEDULE_RUN, "booked when it was repaid, and running since");

        r.pinned = _book(vault);
        assertEq(r.pinned.earliestMaturity, maturity, "it is the vault's earliest open loan");
        assertEq(r.pinned.paidInterest, r.loan.interest, "the vault's only running schedule");
        assertApproxEqAbs(
            r.pinned.unearnedInterest, uint256(r.loan.rate) * (maturity - t0) / 1e18, 2, "what the schedule still owes"
        );
        // Since the booking the clock has released what it earned: less cash is held now than was held then.
        assertApproxEqAbs(
            scheduleHeldAtBooking - r.pinned.unearnedInterest,
            uint256(r.loan.rate) * (t0 - l.closedAt) / 1e18,
            2,
            "released on the clock since the booking"
        );
        assertGt(r.pinned.unearnedInterest, 0);
        assertLt(r.pinned.unearnedInterest, r.loan.interest);
        _assertBacked(vault, r.pinned);

        // The depositor leaves with a tenth now: paid at the current price, the unearned part stays behind.
        r.redeemedShares = vault.balanceOf(DEPOSITOR) / 10;
        uint256 expected = vault.convertToAssets(r.redeemedShares);
        uint256 wallet = USDG.balanceOf(DEPOSITOR);
        vm.prank(DEPOSITOR);
        r.redeemedAssets = vault.redeem(r.redeemedShares, expected);
        r.redeemed = _book(vault);
        assertEq(r.redeemedAssets, expected, "paid at the current share price");
        assertEq(USDG.balanceOf(DEPOSITOR) - wallet, expected);
        assertApproxEqAbs(r.redeemed.price, r.pinned.price, 1, "a redemption does not move the price");
        assertEq(r.redeemed.unearnedInterest, r.pinned.unearnedInterest, "the unearned part is left to those who stay");
        r.leftBehind = r.redeemedShares * (r.pinned.totalAssets + r.pinned.unearnedInterest + 1)
            / (r.pinned.totalSupply + VIRTUAL_SHARES) - expected;
        assertGt(r.leftBehind, 0);

        // Halfway to the end of the term the held cash has been freed exactly as it was earned.
        vm.warp(t0 + (maturity - t0) / 2);
        r.midway = _book(vault);
        assertApproxEqAbs(
            r.midway.totalAssets - r.redeemed.totalAssets,
            r.redeemed.accrualRate * (vm.getBlockTimestamp() - t0) / 1e18,
            2,
            "priced assets rose on the clock only"
        );
        assertEq(
            r.midway.freeLiquidity - r.redeemed.freeLiquidity,
            r.redeemed.unearnedInterest - r.midway.unearnedInterest,
            "held cash is freed exactly as it is earned"
        );

        // At the end of the original term pricing pauses until the permissionless settle ends the schedule.
        vm.warp(maturity);
        r.termEnd = _book(vault);
        _expectSettlementDue(vault);
        vm.prank(stranger);
        vault.settle(_ids(id));
        r.released = _book(vault);
        assertTrue(_held(vault, id).settled, "released");
        assertEq(r.released.paidInterest, 0, "its paid interest is recognised in full");
        assertEq(r.released.unearnedInterest, 0);
        assertApproxEqAbs(r.released.totalAssets, r.termEnd.totalAssets, 1, "no step at the release");
        assertEq(r.released.freeLiquidity, r.released.cash + r.released.reservePayable, "and all of it is free");
        assertGt(r.released.earliestMaturity, maturity, "pricing resumes until the next loan's term ends");
        vm.prank(DEPOSITOR);
        vault.redeem(1e18, 0);

        string memory o = _o("result");
        vm.serializeString(
            o,
            "what",
            "The schedule listing was repaid early and booked by a settle when the fixture was staged, an hour before this scenario starts; nothing is repaid here. At the start the loan is REPAID on the core and a running schedule in stocks: its net interest is paid interest, the part not yet earned is held out of free liquidity, a redemption is paid at the current price and leaves that part behind, the held cash is freed exactly as the clock earns it, and at the original term end pricing pauses until anyone's settle releases the schedule with no step."
        );
        vm.serializeString(o, "loan", _loanJson("schedule", vault, id, l, r.loan));
        _n(o, "repaidAt", l.closedAt);
        _n(o, "scenarioStartedAt", t0);
        _n(o, "secondsIntoItsTermWhenRepaid", uint256(l.closedAt) - l.fundedAt);
        _n(o, "heldUnearnedCashAtTheStart", r.pinned.unearnedInterest);
        _n(o, "redeemedShares", r.redeemedShares);
        _n(o, "redeemedAssets", r.redeemedAssets);
        _n(o, "leftBehindByThatRedemption", r.leftBehind);
        vm.serializeString(o, "0_atTheStart", _bookJson("0", r.pinned));
        vm.serializeString(o, "1_afterPartialRedemption", _bookJson("1", r.redeemed));
        vm.serializeString(o, "2_midway", _bookJson("2", r.midway));
        vm.serializeString(o, "3_termEndBeforeSettle", _bookJson("3", r.termEnd));
        return vm.serializeString(o, "4_released", _bookJson("4", r.released));
    }

    // ================================================================ 1b. a fresh early repayment (D29)

    struct Early {
        Book before_;
        Book repaid;
        Book booked;
        Book redeemed;
        Book midway;
        Book termEnd;
        Book released;
        IntentVault.Loan loan;
        uint256 fee;
        uint256 protocol;
        uint256 heldForThisLoan;
        uint256 redeemedShares;
        uint256 redeemedAssets;
        uint256 leftBehind;
    }

    function _earlyRepayment() internal returns (string memory) {
        scope = "early";
        IntentVault vault = memeVault;
        uint256 id = memeLoan;
        Early memory e;
        V2Loan memory l = _activeLoanHeldWhole(vault, id);
        e.loan = _held(vault, id);
        e.before_ = _book(vault);
        uint256 maturity = e.loan.maturity;
        uint256 t0 = vm.getBlockTimestamp();

        // The borrower repays the whole fixed cost now, days before the end of the term.
        _repay(id);
        e.repaid = _book(vault);
        assertEq(CORE.cashCredit(address(vault)), l.cap, "the core owes the vault the whole cap");
        assertEq(e.repaid.totalAssets, e.before_.totalAssets, "an unbooked repayment is priced on the same schedule");

        // Anyone books it.
        vm.prank(stranger);
        vault.settle(_ids(id));
        e.booked = _book(vault);
        (e.fee, e.protocol) = _performanceFee(e.loan, l.cap);
        assertEq(e.loan.interest, (l.cap - l.principal) - e.fee, "net interest is the cost less the manager fee");
        assertEq(e.booked.totalAssets, e.before_.totalAssets, "booking moved priced assets by zero");
        assertEq(e.booked.price, e.before_.price, "the share price did not jump");
        assertEq(e.booked.cash - e.before_.cash, l.cap - e.fee, "cash: the cap less the fee");
        assertEq(e.before_.performingPrincipal - e.booked.performingPrincipal, l.principal, "no longer lent");
        assertEq(e.booked.paidInterest - e.before_.paidInterest, e.loan.interest, "its net interest is paid interest");
        assertEq(e.booked.curatorFees - e.before_.curatorFees, e.fee - e.protocol, "manager fee claimable at once");
        assertEq(e.booked.protocolFees - e.before_.protocolFees, e.protocol, "protocol fee claimable at once");
        assertEq(e.booked.accrualRate, e.before_.accrualRate, "the loan keeps its place on the interest clock");
        _assertBacked(vault, e.booked);
        IntentVault.Loan memory now_ = _held(vault, id);
        assertTrue(now_.repaid && !now_.settled, "repaid, and still in the open set until the term ends");
        assertEq(now_.rate, e.loan.rate, "same rate");
        assertEq(now_.maturity, maturity, "same end");
        assertEq(e.booked.earliestMaturity, maturity);

        // The unearned part of the cash is held out of free liquidity.
        e.heldForThisLoan = e.booked.unearnedInterest - e.before_.unearnedInterest;
        assertGt(e.heldForThisLoan, 0);
        assertLt(e.heldForThisLoan, e.loan.interest);
        assertApproxEqAbs(
            e.heldForThisLoan, uint256(e.loan.rate) * (maturity - t0) / 1e18, 1, "what the schedule still owes"
        );
        assertEq(e.booked.freeLiquidity, e.booked.cash + e.booked.reservePayable - e.booked.unearnedInterest);
        assertEq(
            e.booked.freeLiquidity - e.before_.freeLiquidity,
            (l.cap - e.fee) - e.heldForThisLoan,
            "free liquidity rose by the cash less the part not yet earned"
        );

        // The depositor leaves with a tenth now: paid at the current price, the unearned part stays behind.
        e.redeemedShares = vault.balanceOf(DEPOSITOR) / 10;
        uint256 expected = vault.convertToAssets(e.redeemedShares);
        uint256 walletBefore = USDG.balanceOf(DEPOSITOR);
        vm.prank(DEPOSITOR);
        e.redeemedAssets = vault.redeem(e.redeemedShares, expected);
        e.redeemed = _book(vault);
        assertEq(e.redeemedAssets, expected, "paid at the current share price");
        assertEq(USDG.balanceOf(DEPOSITOR) - walletBefore, expected);
        assertApproxEqAbs(e.redeemed.price, e.booked.price, 1, "a redemption does not move the price");
        assertEq(e.redeemed.unearnedInterest, e.booked.unearnedInterest, "the unearned part is left to those who stay");
        assertEq(e.redeemed.paidInterest, e.booked.paidInterest);
        // Had the unearned cash been priced, the same shares would have taken this much more.
        e.leftBehind = e.redeemedShares * (e.booked.totalAssets + e.booked.unearnedInterest + 1)
            / (e.booked.totalSupply + VIRTUAL_SHARES) - expected;
        assertGt(e.leftBehind, 0);

        // Halfway to the end of the term the schedule has earned half of what was held.
        vm.warp(t0 + (maturity - t0) / 2);
        e.midway = _book(vault);
        assertApproxEqAbs(
            e.midway.totalAssets - e.redeemed.totalAssets,
            e.redeemed.accrualRate * (vm.getBlockTimestamp() - t0) / 1e18,
            2,
            "priced assets rose on the clock only"
        );
        assertEq(
            e.midway.freeLiquidity - e.redeemed.freeLiquidity,
            e.redeemed.unearnedInterest - e.midway.unearnedInterest,
            "held cash is freed exactly as it is earned"
        );

        // At the end of the original term pricing pauses until the same permissionless settle ends the schedule.
        vm.warp(maturity);
        e.termEnd = _book(vault);
        _expectSettlementDue(vault);
        vm.prank(stranger);
        vault.settle(_ids(id));
        e.released = _book(vault);
        now_ = _held(vault, id);
        assertTrue(now_.settled, "released");
        assertEq(e.released.paidInterest, e.before_.paidInterest, "its paid interest is recognised in full");
        assertApproxEqAbs(e.released.totalAssets, e.termEnd.totalAssets, 1, "no step at the release either");
        assertApproxEqAbs(
            e.released.totalAssets - e.redeemed.totalAssets,
            e.redeemed.accrualRate * (maturity - t0) / 1e18,
            2,
            "from booking to release priced assets rose by the schedule and nothing else"
        );
        assertEq(
            e.released.freeLiquidity - e.redeemed.freeLiquidity,
            e.redeemed.unearnedInterest - e.released.unearnedInterest,
            "and all of it is free"
        );
        assertLe(e.released.unearnedInterest, e.before_.unearnedInterest, "only older schedules still hold cash");
        assertGt(e.released.earliestMaturity, maturity, "pricing resumes");
        vm.prank(DEPOSITOR);
        vault.redeem(1e18, 0);
        return _earlyJson(vault, id, l, e);
    }

    function _earlyJson(IntentVault vault, uint256 id, V2Loan memory l, Early memory e)
        internal
        returns (string memory)
    {
        string memory o = _o("result");
        vm.serializeString(
            o,
            "what",
            "The borrower repays days early; anyone settles. The cash is booked, the fee is claimable, priced assets and the share price do not move, the loan keeps accruing at its original rate, the unearned part of the cash is held out of free liquidity, a redemption is paid at the current price and leaves that part behind, and at the original term end a settle releases the schedule with no step."
        );
        vm.serializeString(o, "loan", _loanJson("meme", vault, id, l, e.loan));
        _n(o, "performanceFee", e.fee);
        _n(o, "protocolPartOfFee", e.protocol);
        _n(o, "managerPartOfFee", e.fee - e.protocol);
        _n(o, "cashBooked", l.cap - e.fee);
        _n(o, "heldUnearnedCashForThisLoanAtBooking", e.heldForThisLoan);
        _n(o, "redeemedShares", e.redeemedShares);
        _n(o, "redeemedAssets", e.redeemedAssets);
        _n(o, "leftBehindByThatRedemption", e.leftBehind);
        vm.serializeString(o, "0_before", _bookJson("0", e.before_));
        vm.serializeString(o, "1_repaidNotSettled", _bookJson("1", e.repaid));
        vm.serializeString(o, "2_booked", _bookJson("2", e.booked));
        vm.serializeString(o, "3_afterPartialRedemption", _bookJson("3", e.redeemed));
        vm.serializeString(o, "4_midway", _bookJson("4", e.midway));
        vm.serializeString(o, "5_termEndBeforeSettle", _bookJson("5", e.termEnd));
        return vm.serializeString(o, "6_released", _bookJson("6", e.released));
    }

    // ================================================================ 2. on-time repayment

    struct OnTime {
        Book before_;
        Book hourBefore;
        Book booked;
        Book claimed;
        Book released;
        IntentVault.Loan loan;
        uint256 fee;
        uint256 protocol;
        uint256 routerAvailableBefore;
        uint256 routerAvailableAfter;
        uint256 managerBefore;
        uint256 managerAfter;
        address manager;
    }

    function _onTimeRepayment() internal returns (string memory) {
        scope = "ontime";
        IntentVault vault = memeVault;
        uint256 id = memeLoan;
        OnTime memory t;
        V2Loan memory l = _activeLoanHeldWhole(vault, id);
        t.loan = _held(vault, id);
        t.before_ = _book(vault);
        uint256 maturity = t.loan.maturity;
        uint256 t0 = vm.getBlockTimestamp();

        vm.warp(maturity - 1 hours);
        t.hourBefore = _book(vault);
        uint256 heldBefore = USDG.balanceOf(address(vault));
        _repay(id);
        vm.prank(stranger);
        vault.settle(_ids(id));
        t.booked = _book(vault);
        (t.fee, t.protocol) = _performanceFee(t.loan, l.cap);

        // Principal and the vault's part of what the loan earns arrive; the fee is set aside.
        assertEq(USDG.balanceOf(address(vault)) - heldBefore, l.cap, "the whole cap reached the vault");
        assertEq(CORE.cashCredit(address(vault)), 0);
        assertEq(t.booked.cash - t.hourBefore.cash, l.cap - t.fee);
        assertEq(l.cap - t.fee, uint256(l.principal) + t.loan.interest, "principal plus the loan's net interest");
        assertEq(t.booked.totalAssets, t.hourBefore.totalAssets, "no step at the booking");
        assertEq(t.booked.curatorFees - t.hourBefore.curatorFees, t.fee - t.protocol);
        assertEq(t.booked.protocolFees - t.hourBefore.protocolFees, t.protocol);
        _assertBacked(vault, t.booked);

        // Anyone pays the fees out: the protocol's part to the DealFeeRouter, the manager's to the manager's payout.
        t.manager = vault.feeRecipient();
        t.managerBefore = USDG.balanceOf(t.manager);
        t.routerAvailableBefore = DEAL_FEE_ROUTER.availableUSDG();
        uint256 routerHeld = USDG.balanceOf(address(DEAL_FEE_ROUTER));
        vm.prank(stranger);
        vault.claimFees();
        t.claimed = _book(vault);
        t.routerAvailableAfter = DEAL_FEE_ROUTER.availableUSDG();
        t.managerAfter = USDG.balanceOf(t.manager);
        assertEq(t.routerAvailableAfter - t.routerAvailableBefore, t.booked.protocolFees, "availableUSDG rose by it");
        assertEq(USDG.balanceOf(address(DEAL_FEE_ROUTER)) - routerHeld, t.booked.protocolFees, "a plain transfer");
        assertEq(t.managerAfter - t.managerBefore, t.booked.curatorFees, "the manager's part");
        assertEq(t.claimed.curatorFees + t.claimed.protocolFees, 0);
        assertEq(t.claimed.totalAssets, t.booked.totalAssets, "fees were never priced");
        _assertBacked(vault, t.claimed);

        // The last hour of the schedule, then its release.
        vm.warp(maturity);
        _expectSettlementDue(vault);
        vm.prank(stranger);
        vault.settle(_ids(id));
        t.released = _book(vault);
        assertTrue(_held(vault, id).settled);
        assertEq(t.released.paidInterest, t.before_.paidInterest);
        assertApproxEqAbs(
            t.released.totalAssets - t.before_.totalAssets,
            t.before_.accrualRate * (maturity - t0) / 1e18,
            2,
            "over its life the loan added its schedule to priced assets and nothing else"
        );

        string memory o = _o("result");
        vm.serializeString(
            o,
            "what",
            "The borrower repays one hour before the end of the term; anyone settles and anyone claims the fees. The vault receives the whole cap, keeps principal plus net interest, the protocol's tenth of the fee goes to the DealFeeRouter as plain USDG and the rest to the manager's payout address."
        );
        vm.serializeString(o, "loan", _loanJson("meme", vault, id, l, t.loan));
        _n(o, "repaidAt", maturity - 1 hours);
        _n(o, "capReceived", l.cap);
        _n(o, "performanceFee", t.fee);
        _n(o, "protocolPartOfFee", t.protocol);
        _n(o, "managerPartOfFee", t.fee - t.protocol);
        vm.serializeAddress(o, "managerPayout", t.manager);
        _n(o, "managerPayoutBalanceBefore", t.managerBefore);
        _n(o, "managerPayoutBalanceAfter", t.managerAfter);
        _n(o, "dealFeeRouterAvailableBefore", t.routerAvailableBefore);
        _n(o, "dealFeeRouterAvailableAfter", t.routerAvailableAfter);
        vm.serializeString(o, "0_before", _bookJson("0", t.before_));
        vm.serializeString(o, "1_oneHourBeforeTermEnd", _bookJson("1", t.hourBefore));
        vm.serializeString(o, "2_booked", _bookJson("2", t.booked));
        vm.serializeString(o, "3_feesClaimed", _bookJson("3", t.claimed));
        return vm.serializeString(o, "4_released", _bookJson("4", t.released));
    }

    // ================================================================ 3. loans split across several vaults

    struct Part {
        uint256 units;
        uint256 principal;
        uint256 payout;
        uint256 interest;
        uint256 fee;
        uint256 protocol;
    }

    struct SplitSide {
        Book before_;
        Book booked;
        Book end;
        Part total;
    }

    function _multiVaultRepayment() internal returns (string memory) {
        scope = "split";
        IntentVault[] memory vaults = _trio();
        string[] memory names = _trioNames();
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (splitLoanA, splitLoanB);
        SplitSide[] memory sides = new SplitSide[](vaults.length);
        for (uint256 v; v < vaults.length; ++v) {
            sides[v].before_ = _book(vaults[v]);
        }
        string memory loansJson;
        for (uint256 i; i < ids.length; ++i) {
            (Part[] memory parts, string memory json) = _repaySplit(ids[i], vaults, names);
            for (uint256 v; v < vaults.length; ++v) {
                _add(sides[v].total, parts[v]);
            }
            loansJson = vm.serializeString(_o("loans"), vm.toString(ids[i]), json);
        }
        // Every vault books its own parts; each settle is anyone's.
        for (uint256 v; v < vaults.length; ++v) {
            for (uint256 i; i < ids.length; ++i) {
                if (_held(vaults[v], ids[i]).principal == 0) continue;
                vm.prank(stranger);
                vaults[v].settle(_ids(ids[i]));
            }
            sides[v].booked = _book(vaults[v]);
            _assertSplitBooked(vaults[v], sides[v]);
        }
        // Each schedule ends at its own term end, the schedule listing's in stocks first; every vault releases it
        // there.
        _releaseSchedulesBefore(vaults, NO_DEADLINE);
        string memory o = _o("result");
        for (uint256 v; v < vaults.length; ++v) {
            sides[v].end = _book(vaults[v]);
            _assertSplitEnded(sides[v]);
            vm.serializeString(o, names[v], _splitSideJson(names[v], sides[v]));
        }
        vm.serializeString(
            o,
            "what",
            "Split listing A is held by three vaults (nvda-high-fee two units, nvda-low-fee one, stocks one) and split listing B by the two NVDAx vaults (nvda-high-fee one, nvda-low-fee three). Both are repaid. The core credits each vault the cap's slices of exactly the units it holds, the credits sum to the cap, each vault books its own part at its own fee rate with no step in its priced assets, and once every schedule has been released at its own term end each vault is all cash, up by exactly its net interest."
        );
        return vm.serializeString(o, "loans", loansJson);
    }

    /// @dev Repay one split listing and check the core's credit to each vault, unit by unit.
    function _repaySplit(uint256 id, IntentVault[] memory vaults, string[] memory names)
        internal
        returns (Part[] memory parts, string memory json)
    {
        V2Loan memory l = CORE.getLoan(id);
        assertEq(uint8(l.state), uint8(V2State.ACTIVE), "active at the start");
        address[4] memory lenders = CORE.lenders(id);
        parts = new Part[](vaults.length);
        uint256[] memory credits = new uint256[](vaults.length);
        Part memory sum;
        uint256 holders;
        for (uint256 v; v < vaults.length; ++v) {
            parts[v] = _part(vaults[v], id, l, lenders);
            credits[v] = CORE.cashCredit(address(vaults[v]));
            _add(sum, parts[v]);
            if (parts[v].units != 0) ++holders;
        }
        assertGt(holders, 1, "split across vaults");
        assertEq(sum.units, 4, "these vaults hold the whole listing");
        assertEq(sum.payout, l.cap, "the slices sum to the cap exactly");
        assertEq(sum.principal, l.principal);
        _repay(id);
        string memory o = _o(string.concat("loan", vm.toString(id)));
        for (uint256 v; v < vaults.length; ++v) {
            assertEq(CORE.cashCredit(address(vaults[v])) - credits[v], parts[v].payout, "credited its units' slices");
            if (parts[v].units != 0) {
                vm.serializeString(o, names[v], _partJson(string.concat(names[v], vm.toString(id)), parts[v]));
            }
        }
        vm.serializeAddress(o, "token", l.token);
        _n(o, "principal", l.principal);
        _n(o, "cap", l.cap);
        _n(o, "fundedAt", l.fundedAt);
        json = _n(o, "termEnd", uint256(l.fundedAt) + l.term);
    }

    function _part(IntentVault vault, uint256 id, V2Loan memory l, address[4] memory lenders)
        internal
        view
        returns (Part memory p)
    {
        for (uint8 i; i < 4; ++i) {
            if (lenders[i] != address(vault)) continue;
            ++p.units;
            p.principal += _slice(l.principal, i);
            p.payout += _slice(l.cap, i);
        }
        IntentVault.Loan memory h = _held(vault, id);
        assertEq(h.principal, p.principal, "the vault's record is its units' principal");
        p.interest = h.interest;
        (p.fee, p.protocol) = _performanceFee(h, p.payout);
        assertEq(p.interest, (p.payout - p.principal) - p.fee, "net interest is its part of the cost less its fee");
    }

    function _add(Part memory total, Part memory p) internal pure {
        total.units += p.units;
        total.principal += p.principal;
        total.payout += p.payout;
        total.interest += p.interest;
        total.fee += p.fee;
        total.protocol += p.protocol;
    }

    function _assertSplitBooked(IntentVault vault, SplitSide memory s) internal view {
        assertEq(CORE.cashCredit(address(vault)), 0, "the credit was pulled");
        assertEq(s.booked.cash - s.before_.cash, s.total.payout - s.total.fee, "cash: its slices less its fees");
        assertEq(s.before_.performingPrincipal - s.booked.performingPrincipal, s.total.principal);
        assertEq(s.booked.performingPrincipal, 0, "these were all the loans it still had out");
        assertEq(s.booked.paidInterest - s.before_.paidInterest, s.total.interest);
        assertEq(s.booked.curatorFees - s.before_.curatorFees, s.total.fee - s.total.protocol);
        assertEq(s.booked.protocolFees - s.before_.protocolFees, s.total.protocol);
        assertEq(s.booked.totalAssets, s.before_.totalAssets, "no step in any vault");
        _assertBacked(vault, s.booked);
    }

    function _assertSplitEnded(SplitSide memory s) internal pure {
        assertEq(s.end.earliestMaturity, NO_DEADLINE, "no open loan is left");
        assertEq(s.end.paidInterest, 0);
        assertEq(s.end.unearnedInterest, 0);
        assertEq(s.end.accrualRate, 0);
        assertEq(s.end.totalAssets, s.end.cash + s.end.reserveAssets, "all cash");
        assertEq(s.end.freeLiquidity, s.end.cash + s.end.reservePayable, "all free");
        // Priced assets started at cash + principal + what every schedule had earned less what was already paid in,
        // and end at cash + principal + the whole net interest of the loans repaid here.
        assertEq(
            s.end.totalAssets + s.before_.accruedInterest,
            s.before_.totalAssets + s.total.interest + s.before_.paidInterest,
            "up by exactly its net interest"
        );
    }

    function _splitSideJson(string memory name, SplitSide memory s) internal returns (string memory) {
        string memory o = _o(string.concat("side.", name));
        vm.serializeString(o, "total", _partJson(string.concat(name, ".total"), s.total));
        vm.serializeString(o, "0_before", _bookJson(string.concat(name, "0"), s.before_));
        vm.serializeString(o, "1_booked", _bookJson(string.concat(name, "1"), s.booked));
        return vm.serializeString(o, "2_allReleased", _bookJson(string.concat(name, "2"), s.end));
    }

    // ================================================================ 4. default and recovery

    struct Side {
        IntentVault vault;
        string name;
        uint256 units;
        uint256 collateralShare;
        IntentVault.Loan loan;
        Book before_;
        Book termEnd;
        Book writtenOff;
        Book afterExit;
        uint256 pocketId;
        uint256 collateral;
        uint256 claimed;
        uint256 exitShares;
        uint256 exitAssets;
        uint256 entrantShares;
    }

    function _defaultAndRecovery(
        string memory name,
        IntentVault[] memory vaults,
        string[] memory names,
        uint256 id,
        bool thirdPartyFinalizes
    ) internal returns (string memory) {
        scope = name;
        V2Loan memory l = CORE.getLoan(id);
        assertEq(uint8(l.state), uint8(V2State.ACTIVE), "active at the start");
        assertEq(CORE.ownerOf(id), BORROWER, "the test borrower holds the reclaim right");
        uint40 maturity = l.fundedAt + l.term;
        Side[] memory sides = new Side[](vaults.length);
        uint256 units;
        uint256 collateral;
        for (uint256 v; v < vaults.length; ++v) {
            sides[v] = _side(vaults[v], names[v], id, l);
            units += sides[v].units;
            collateral += sides[v].collateralShare;
        }
        assertEq(units, 4, "these vaults hold the whole listing");
        assertEq(collateral, l.collateral, "the slices of the collateral sum to it");

        // As the keeper would: a schedule that ends before this loan's term is released at its own term end, so no
        // vault's interest clock waits (the schedule listing in stocks ends six seconds before split listing A).
        _releaseSchedulesBefore(vaults, maturity);
        // Nobody repays. Zero grace: the second the term ends, repayment is closed and the default is open.
        vm.warp(maturity);
        vm.prank(BORROWER);
        vm.expectRevert(GageV2Vault.Deadline.selector);
        CORE.reclaim(id, BORROWER);
        for (uint256 v; v < vaults.length; ++v) {
            // Pricing stops from that second: no deposit, no redemption, no funding, until the loan is settled.
            // The funding call is made as the published router, the only caller the vault would otherwise let through.
            sides[v].termEnd = _book(vaults[v]);
            _expectSettlementDue(vaults[v]);
            vm.prank(address(ROUTER));
            vm.expectRevert(IntentVault.SettlementDue.selector);
            ILegacyIntentVault(address(vaults[v])).fund(id, 1, 0, 0);
        }
        if (thirdPartyFinalizes) {
            // The core's default is anyone's call; the keeper or a stranger. It moves nothing in any vault.
            vm.prank(stranger);
            CORE.finalizeDefault(id);
            assertEq(uint8(CORE.getLoan(id).state), uint8(V2State.DEFAULTED));
            for (uint256 v; v < vaults.length; ++v) {
                assertEq(vaults[v].totalAssets(), sides[v].termEnd.totalAssets, "the vault has not booked it yet");
                _expectSettlementDue(vaults[v]);
            }
        }
        // The vault's side is anyone's call too; the first settle finalizes on the core itself when nobody has.
        for (uint256 v; v < vaults.length; ++v) {
            vm.prank(stranger);
            vaults[v].settle(_ids(id));
            assertEq(uint8(CORE.getLoan(id).state), uint8(V2State.DEFAULTED));
            sides[v].writtenOff = _book(vaults[v]);
            _assertWrittenOff(sides[v], id);
        }
        // Pricing resumes at the lower price: the depositor takes USDG out, a newcomer comes in.
        for (uint256 v; v < vaults.length; ++v) {
            _exitAndEnter(sides[v]);
        }
        // The core hands collateral only to a unit holder; each vault's own `recover` is anyone's call.
        vm.prank(stranger);
        vm.expectRevert(GageV2Vault.NotAuthorized.selector);
        CORE.recoverDefault(id, 0, 0, vm.getBlockTimestamp());
        for (uint256 v; v < vaults.length; ++v) {
            _recoverAndClaim(sides[v], id, l);
        }
        assertEq(IERC20(l.token).balanceOf(l.account), 0, "the loan's custody account is empty");
        return _defaultJson(id, l, sides, thirdPartyFinalizes);
    }

    function _side(IntentVault vault, string memory name, uint256 id, V2Loan memory l)
        internal
        view
        returns (Side memory s)
    {
        s.vault = vault;
        s.name = name;
        address[4] memory lenders = CORE.lenders(id);
        uint256 principal;
        for (uint8 i; i < 4; ++i) {
            if (lenders[i] != address(vault)) continue;
            ++s.units;
            principal += _slice(l.principal, i);
            s.collateralShare += _slice(l.collateral, i);
        }
        assertGt(s.units, 0, "the vault holds units of this listing");
        s.loan = _held(vault, id);
        assertEq(s.loan.principal, principal, "the vault's record is its units' principal");
        assertEq(s.loan.maturity, uint256(l.fundedAt) + l.term, "the vault knows the exact end of the term");
        assertGt(s.loan.rate, 0, "accruing");
        assertLt(vm.getBlockTimestamp(), s.loan.maturity, "still in term");
        _assertSoleHolder(vault);
        s.before_ = _book(vault);
    }

    function _assertWrittenOff(Side memory d, uint256 id) internal view {
        IntentVault.Loan memory h = _held(d.vault, id);
        assertTrue(h.settled && !h.repaid && !h.recovered);
        assertGt(h.snapshotId, 0, "holders of record are fixed at the write-off");
        assertEq(h.snapshotSupply, d.writtenOff.totalSupply);
        // Its whole principal and everything the loan had been priced as earning leave priced assets at once.
        assertApproxEqAbs(
            d.termEnd.totalAssets - d.writtenOff.totalAssets,
            uint256(d.loan.principal) + d.loan.interest,
            1,
            "written off in full: its principal and the interest it had accrued"
        );
        assertEq(d.termEnd.performingPrincipal - d.writtenOff.performingPrincipal, d.loan.principal);
        assertEq(d.writtenOff.cash, d.termEnd.cash, "no USDG arrives from a default");
        assertEq(d.writtenOff.curatorFees, d.termEnd.curatorFees, "no manager fee on a loss");
        assertEq(d.writtenOff.protocolFees, d.termEnd.protocolFees);
        assertEq(d.writtenOff.executionFees, d.termEnd.executionFees, "the execution fee stays an incurred cost");
        assertLt(d.writtenOff.price, d.termEnd.price, "the share price falls");
        assertGt(d.writtenOff.earliestMaturity, d.loan.maturity, "pricing resumes");
        assertEq(CORE.cashCredit(address(d.vault)), 0);
        _assertBacked(d.vault, d.writtenOff);
    }

    function _exitAndEnter(Side memory d) internal {
        d.exitShares = d.vault.balanceOf(DEPOSITOR) / 20;
        uint256 expected = d.vault.convertToAssets(d.exitShares);
        vm.prank(DEPOSITOR);
        d.exitAssets = d.vault.redeem(d.exitShares, expected);
        assertEq(d.exitAssets, expected);
        IMintable(address(USDG)).mint(entrant, 5e6);
        vm.startPrank(entrant);
        USDG.approve(address(d.vault), 5e6);
        d.entrantShares = d.vault.deposit(5e6, 0);
        vm.stopPrank();
        d.afterExit = _book(d.vault);
        assertApproxEqAbs(d.afterExit.price, d.writtenOff.price, 1);
    }

    /// @dev The collateral never enters priced assets: it goes to a side pocket owned by the holders of record.
    function _recoverAndClaim(Side memory d, uint256 id, V2Loan memory l) internal {
        IERC20 token = IERC20(l.token);
        IntentVault vault = d.vault;
        uint256 held = token.balanceOf(address(vault));
        uint256 pockets = vault.pocketCount();
        vm.prank(stranger);
        vault.recover(id);
        d.pocketId = vault.pocketCount();
        assertEq(d.pocketId, pockets + 1);
        d.collateral = token.balanceOf(address(vault)) - held;
        assertEq(d.collateral, d.collateralShare, "the collateral's slices of exactly the units it held");
        assertEq(vault.pocketLiability(address(token)), d.collateral);
        assertEq(vault.totalAssets(), d.afterExit.totalAssets, "recovered collateral is never priced");
        vm.expectRevert(IntentVault.NothingToRecover.selector);
        vault.recover(id);

        // The holder of record claims in kind, whatever they redeemed since; a later entrant owns none of it.
        assertEq(vault.pocketClaimable(d.pocketId, DEPOSITOR), d.collateral, "the only holder at the write-off");
        assertEq(vault.pocketClaimable(d.pocketId, entrant), 0);
        uint256 wallet = token.balanceOf(DEPOSITOR);
        vm.prank(DEPOSITOR);
        d.claimed = vault.claimPocket(d.pocketId);
        assertEq(d.claimed, d.collateral);
        assertEq(token.balanceOf(DEPOSITOR) - wallet, d.collateral);
        assertEq(vault.pocketLiability(address(token)), 0);
        vm.prank(DEPOSITOR);
        vm.expectRevert(IntentVault.InvalidAmount.selector);
        vault.claimPocket(d.pocketId);
        vm.prank(entrant);
        vm.expectRevert(IntentVault.InvalidAmount.selector);
        vault.claimPocket(d.pocketId);
    }

    function _defaultJson(uint256 id, V2Loan memory l, Side[] memory sides, bool thirdPartyFinalized)
        internal
        returns (string memory)
    {
        string memory o = _o("result");
        vm.serializeString(
            o,
            "what",
            "Nobody repays. At the second the term ends the borrower's repayment reverts Deadline and every vault that holds units refuses deposit, redeem and fund with SettlementDue. Anyone finalizes the default on the core (or the first vault's own settle does); anyone's settle writes off, in each vault, its principal and the interest the loan had accrued there, in full, with no USDG arriving and no manager fee. Pricing resumes at the lower price. Anyone's recover moves each vault's slices of the collateral token into a side pocket; it is never priced, and only holders of record at the write-off claim it, in kind."
        );
        _n(o, "listingId", id);
        vm.serializeAddress(o, "collateralToken", l.token);
        _n(o, "collateral", l.collateral);
        _n(o, "principal", l.principal);
        _n(o, "cap", l.cap);
        _n(o, "fundedAt", l.fundedAt);
        _n(o, "termEnd", uint256(l.fundedAt) + l.term);
        vm.serializeBool(o, "coreDefaultFinalizedByAThirdPartyFirst", thirdPartyFinalized);
        vm.serializeAddress(o, "finalizeSettleAndRecoverCalledBy", stranger);
        vm.serializeString(o, "thatCaller", "an address with no role and no shares: all three calls are permissionless");
        vm.serializeString(
            o,
            "whileUnsettledPastTerm",
            "deposit and redeem revert SettlementDue, and so does fund when called as the published router; the borrower's reclaim reverts Deadline"
        );
        string memory json;
        for (uint256 v; v < sides.length; ++v) {
            json = vm.serializeString(o, sides[v].name, _sideJson(id, l, sides[v]));
        }
        return json;
    }

    function _sideJson(uint256 id, V2Loan memory l, Side memory d) internal returns (string memory) {
        string memory o = _o(string.concat("side.", d.name));
        vm.serializeString(o, "loan", _loanJson(d.name, d.vault, id, l, d.loan));
        _n(o, "writtenOff", d.termEnd.totalAssets - d.writtenOff.totalAssets);
        _n(o, "usdgReceivedFromTheDefault", d.writtenOff.cash - d.termEnd.cash);
        _n(o, "collateralDeliveredToTheSidePocket", d.collateral);
        _n(o, "pocketId", d.pocketId);
        _n(o, "collateralClaimedByTheHolderOfRecord", d.claimed);
        _n(o, "collateralClaimableByALaterEntrant", 0);
        _n(o, "bookedValueOfTheCollateralInPricedAssets", 0);
        _n(o, "depositorRedeemedSharesAfterwards", d.exitShares);
        _n(o, "depositorRedeemedAssetsAfterwards", d.exitAssets);
        _n(o, "laterEntrantShares", d.entrantShares);
        vm.serializeString(o, "0_before", _bookJson(string.concat(d.name, "0"), d.before_));
        vm.serializeString(o, "1_termEndUnsettled", _bookJson(string.concat(d.name, "1"), d.termEnd));
        vm.serializeString(o, "2_writtenOff", _bookJson(string.concat(d.name, "2"), d.writtenOff));
        return
            vm.serializeString(
                o, "3_afterARedemptionAndALaterDeposit", _bookJson(string.concat(d.name, "3"), d.afterExit)
            );
    }

    // ================================================================ 5. withdrawals

    struct Exits {
        Book start;
        Book before_;
        Book invested;
        Book paidFromReserve;
        Book allRepaid;
        Book empty;
        uint256 firstShares;
        uint256 firstAssets;
        uint256 allShares;
        uint256 wholeValue;
        uint256 allButOneValue;
        uint256 sharesOver;
        uint256 valueOver;
        uint256 investedAssets;
        uint256 reserveSharesBought;
        uint256 exitShares;
        uint256 exitAssets;
        uint256 pulledFromReserve;
        uint256 reserveSharesBurned;
        uint256 reservePayableBefore;
        uint256 reservePayableAfter;
        uint256 loansRepaid;
        uint256 lastShares;
        uint256 lastAssets;
    }

    function _withdrawals() internal returns (string memory) {
        scope = "exits";
        IntentVault vault = nvdaLowFee;
        _assertSoleHolder(vault);
        Exits memory x;
        x.start = _book(vault);
        // At the start about half of this vault is idle. The depositor takes most of that cash out first, so that most
        // of what is left is out on loans (split listing A, one unit; split listing B, three).
        x.firstShares = vault.convertToShares(x.start.freeLiquidity * 85 / 100);
        vm.prank(DEPOSITOR);
        x.firstAssets = vault.redeem(x.firstShares, 0);
        x.before_ = _book(vault);
        assertGt(x.before_.performingPrincipal, x.before_.freeLiquidity * 3, "most of the vault is out on loans");

        // More than free liquidity is refused outright: nothing is paid, nothing queues, the shares stay.
        x.allShares = vault.balanceOf(DEPOSITOR);
        x.wholeValue = vault.convertToAssets(x.allShares);
        assertGt(x.wholeValue, x.before_.freeLiquidity);
        // The depositor's whole balance is the whole supply, and the last holder cannot leave while any principal is
        // lent: that exit reverts OutstandingLoans before liquidity is looked at (the residual D31 left, closed since
        // d5a53b45, docs/intent-v1/AUDIT-SCOPE.md question 15; src/intent/IntentVault.sol:622).
        assertEq(x.allShares, x.before_.totalSupply, "the last holder");
        vm.prank(DEPOSITOR);
        vm.expectRevert(IntentVault.OutstandingLoans.selector);
        vault.redeem(x.allShares, 0);
        // Everything but one share is not the last holder's exit, and it is worth more than free liquidity.
        x.allButOneValue = vault.convertToAssets(x.allShares - 1);
        assertGt(x.allButOneValue, x.before_.freeLiquidity);
        vm.prank(DEPOSITOR);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        vault.redeem(x.allShares - 1, 0);
        // Two raw units above free liquidity is refused as well; the boundary is exact.
        x.sharesOver = vault.convertToShares(x.before_.freeLiquidity) + 2 * VIRTUAL_SHARES;
        x.valueOver = vault.convertToAssets(x.sharesOver);
        assertGt(x.valueOver, x.before_.freeLiquidity);
        assertLe(x.valueOver, x.before_.freeLiquidity + 2);
        vm.prank(DEPOSITOR);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        vault.redeem(x.sharesOver, 0);
        assertEq(keccak256(abi.encode(_book(vault))), keccak256(abi.encode(x.before_)), "a refusal moves nothing");
        assertEq(vault.balanceOf(DEPOSITOR), x.allShares);

        // The admitted filler moves idle cash into the testnet's Morpho reserve through the published router.
        x.investedAssets = x.before_.cash * 2 / 3;
        vm.prank(FILLER);
        x.reserveSharesBought = ROUTER.investReserve(address(vault), x.investedAssets, 0);
        x.invested = _book(vault);
        assertEq(x.invested.cash, x.before_.cash - x.investedAssets);
        assertEq(x.invested.reserveShares, x.reserveSharesBought);
        assertApproxEqAbs(x.invested.totalAssets, x.before_.totalAssets, 2, "the reserve is priced at its own value");
        assertApproxEqAbs(x.invested.freeLiquidity, x.before_.freeLiquidity, 2, "and counted as far as it can pay");
        assertEq(
            RESERVE.maxWithdraw(address(vault)), 0, "the Morpho max view reports zero by design; the lens measures"
        );

        // The slippage argument is honoured.
        x.exitAssets = x.invested.cash + x.investedAssets / 2;
        x.exitShares = vault.convertToShares(x.exitAssets);
        x.exitAssets = vault.convertToAssets(x.exitShares);
        vm.prank(DEPOSITOR);
        vm.expectRevert(IntentVault.Slippage.selector);
        vault.redeem(x.exitShares, x.exitAssets + 1);
        // A redemption larger than cash, inside free liquidity: cash first, then the reserve for the shortfall.
        x.reservePayableBefore = x.invested.reservePayable;
        uint256 wallet = USDG.balanceOf(DEPOSITOR);
        vm.prank(DEPOSITOR);
        assertEq(vault.redeem(x.exitShares, x.exitAssets), x.exitAssets);
        x.paidFromReserve = _book(vault);
        x.pulledFromReserve = x.exitAssets - x.invested.cash;
        x.reserveSharesBurned = x.invested.reserveShares - x.paidFromReserve.reserveShares;
        x.reservePayableAfter = x.paidFromReserve.reservePayable;
        assertEq(USDG.balanceOf(DEPOSITOR) - wallet, x.exitAssets, "paid in full, at once");
        assertEq(x.paidFromReserve.cash, 0, "all cash went first");
        assertGt(x.reserveSharesBurned, 0);
        assertApproxEqAbs(x.reservePayableBefore - x.reservePayableAfter, x.pulledFromReserve, 1, "out of the reserve");
        assertApproxEqAbs(x.paidFromReserve.price, x.invested.price, 1);
        _assertBacked(vault, x.paidFromReserve);

        // Every loan the vault holds is repaid and booked. The interest they paid early is held, not priced.
        x.loansRepaid = _repayAndBookEverything(vault);
        x.allRepaid = _book(vault);
        assertEq(x.allRepaid.performingPrincipal, 0);
        assertGt(x.allRepaid.unearnedInterest, 0);
        assertEq(
            x.allRepaid.totalAssets,
            x.allRepaid.cash + x.allRepaid.reserveAssets - x.allRepaid.unearnedInterest,
            "priced assets leave the unearned cash out"
        );

        // The last holder leaves: every running schedule is released to them first, so nothing waits for the next
        // depositor. What remains is the fees owed to the manager and the protocol, and rounding.
        x.lastShares = vault.balanceOf(DEPOSITOR);
        assertEq(x.lastShares, x.allRepaid.totalSupply, "the last holder");
        uint256 everything = x.allRepaid.cash + x.allRepaid.reserveAssets;
        wallet = USDG.balanceOf(DEPOSITOR);
        vm.prank(DEPOSITOR);
        x.lastAssets = vault.redeem(x.lastShares, 0);
        x.empty = _book(vault);
        assertEq(x.lastAssets, x.lastShares * (everything + 1) / (x.lastShares + VIRTUAL_SHARES), "all of it");
        assertApproxEqAbs(x.lastAssets, everything, 2);
        assertApproxEqAbs(
            x.lastAssets, x.allRepaid.totalAssets + x.allRepaid.unearnedInterest, 2, "priced assets plus the held cash"
        );
        assertEq(USDG.balanceOf(DEPOSITOR) - wallet, x.lastAssets);
        _assertEmptied(x.empty);
        return _exitsJson(x);
    }

    function _assertEmptied(Book memory empty) internal pure {
        assertEq(empty.totalSupply, 0);
        assertEq(empty.paidInterest, 0, "no paid interest is left for a next depositor");
        assertEq(empty.unearnedInterest, 0);
        assertEq(empty.accrualRate, 0);
        assertEq(empty.performingPrincipal, 0);
        assertEq(empty.earliestMaturity, NO_DEADLINE, "the open set is empty");
        assertLe(empty.totalAssets, 3, "rounding only");
        assertLe(empty.usdgHeld - empty.curatorFees - empty.protocolFees - empty.executionFees, 3);
    }

    /// @dev Repay every active loan the vault holds units of, then book them all.
    function _repayAndBookEverything(IntentVault vault) internal returns (uint256 count) {
        uint256 last = CORE.loanCount();
        uint256[] memory ids = new uint256[](last);
        for (uint256 id = firstListing; id <= last; ++id) {
            IntentVault.Loan memory h = _held(vault, id);
            if (h.principal == 0 || h.settled || h.repaid) continue;
            assertEq(uint8(CORE.getLoan(id).state), uint8(V2State.ACTIVE));
            _repay(id);
            ids[count++] = id;
        }
        assembly ("memory-safe") {
            mstore(ids, count)
        }
        assertLe(count, 32, "one settle batch");
        vm.prank(stranger);
        vault.settle(ids);
    }

    function _exitsJson(Exits memory x) internal returns (string memory) {
        string memory o = _o("result");
        vm.serializeString(
            o,
            "what",
            "The nvda-low-fee vault. The depositor first takes most of the idle cash out, so that most of what is left is out on loans. Redeeming the whole supply then reverts OutstandingLoans, since the last holder cannot leave while principal is lent, and a redemption of all but one share, worth more than free liquidity, reverts InsufficientLiquidity: nothing is paid, nothing queues, the shares stay, and the holder must ask for less. Inside free liquidity a redemption is paid at once, cash first and then the Morpho reserve for the shortfall, and minAssets is honoured. After every loan is repaid and booked, the exit of the last holder releases every running schedule to them."
        );
        vm.serializeString(
            o,
            "forkOnly",
            "The admitted filler's reserve investment: no staged vault holds reserve shares at the start."
        );
        _n(o, "firstRedemptionShares", x.firstShares);
        _n(o, "firstRedemptionAssets", x.firstAssets);
        _n(o, "depositorShares", x.allShares);
        _n(o, "valueOfAllShares", x.wholeValue);
        vm.serializeString(
            o, "redeemAllShares", "reverts OutstandingLoans: the last holder cannot leave while principal is lent"
        );
        _n(o, "valueOfAllButOneShare", x.allButOneValue);
        vm.serializeString(o, "redeemAllButOneShare", "reverts InsufficientLiquidity");
        _n(o, "sharesWorthTwoUnitsOverFreeLiquidity", x.sharesOver);
        _n(o, "theirValue", x.valueOver);
        vm.serializeString(o, "redeemThoseShares", "reverts InsufficientLiquidity");
        _n(o, "investedIntoTheReserveByTheFiller", x.investedAssets);
        _n(o, "reserveSharesBought", x.reserveSharesBought);
        vm.serializeString(o, "redeemWithMinAssetsOneAboveTheValue", "reverts Slippage");
        _n(o, "redeemedShares", x.exitShares);
        _n(o, "redeemedAssets", x.exitAssets);
        _n(o, "ofWhichPulledFromTheReserve", x.pulledFromReserve);
        _n(o, "reserveSharesBurned", x.reserveSharesBurned);
        _n(o, "reservePayableBefore", x.reservePayableBefore);
        _n(o, "reservePayableAfter", x.reservePayableAfter);
        _n(o, "loansRepaidAndBooked", x.loansRepaid);
        _n(o, "lastHolderShares", x.lastShares);
        _n(o, "lastHolderAssets", x.lastAssets);
        _n(o, "heldUnearnedCashReleasedToTheLastHolder", x.allRepaid.unearnedInterest);
        vm.serializeString(o, "0_atTheStart", _bookJson("s", x.start));
        vm.serializeString(o, "1_afterTheFirstRedemption", _bookJson("0", x.before_));
        vm.serializeString(o, "2_cashInvestedInTheReserve", _bookJson("1", x.invested));
        vm.serializeString(o, "3_afterARedemptionLargerThanCash", _bookJson("2", x.paidFromReserve));
        vm.serializeString(o, "4_everyLoanRepaidAndBooked", _bookJson("3", x.allRepaid));
        return vm.serializeString(o, "5_afterTheLastHolderLeft", _bookJson("4", x.empty));
    }

    // ================================================================ 6. permission failures

    function _permissions() internal returns (string memory) {
        scope = "permissions";
        delete notes;
        _strangerAndTheVault(stockVault);
        _strangerAndTheFactory();
        _managerAndItsCeilings();
        string memory o = _o("result");
        vm.serializeString(
            o,
            "what",
            "Each line is one call on a published contract, or on the fixture's vault of that role (the published vault itself unless staged.fixtureVaults names a twin), that reverted with exactly the named error."
        );
        return vm.serializeString(o, "refused", notes);
    }

    function _strangerAndTheVault(IntentVault vault) internal {
        bytes4 notCurator = IntentVault.NotCurator.selector;
        vm.startPrank(stranger);
        vm.expectRevert(notCurator);
        ILegacyIntentVault(address(vault)).fund(splitLoanA, 1, 0, 0);
        notes.push("stranger: vault.fund -> NotCurator");
        vm.expectRevert(notCurator);
        vault.collectExecutionFees();
        notes.push("stranger: vault.collectExecutionFees -> NotCurator");
        vm.expectRevert(notCurator);
        vault.investReserve(1e6, 0);
        notes.push("stranger: vault.investReserve -> NotCurator");
        vm.expectRevert(notCurator);
        vault.divestReserve(1, 0);
        notes.push("stranger: vault.divestReserve -> NotCurator");
        vm.expectRevert(notCurator);
        vault.withdrawCommitment(splitLoanA);
        notes.push("stranger: vault.withdrawCommitment -> NotCurator");
        vm.expectRevert(notCurator);
        ILegacyIntentBounds(address(vault)).setLimits(1, 1, 10_000);
        notes.push("stranger: vault.setLimits -> NotCurator");
        vm.expectRevert(notCurator);
        vault.setPaused(true);
        notes.push("stranger: vault.setPaused -> NotCurator");
        vm.expectRevert(notCurator);
        vault.setFillersOpen(false);
        notes.push("stranger: vault.setFillersOpen -> NotCurator");
        vm.expectRevert(notCurator);
        ILegacyIntentBounds(address(vault)).setCategoryWeight(IntentCategory.STOCK, 0);
        notes.push("stranger: vault.setCategoryWeight -> NotCurator");
        vm.expectRevert(notCurator);
        vault.setAsset(TSLAX, false);
        notes.push("stranger: vault.setAsset -> NotCurator");
        vm.expectRevert(notCurator);
        vault.setMinGrade(10);
        notes.push("stranger: vault.setMinGrade -> NotCurator");
        vm.expectRevert(notCurator);
        ILegacyIntentBounds(address(vault)).setMinRateGrade(4);
        notes.push("stranger: vault.setMinRateGrade -> NotCurator");
        vm.expectRevert(notCurator);
        vault.setExecutionCap(5000);
        notes.push("stranger: vault.setExecutionCap -> NotCurator");
        vm.expectRevert(notCurator);
        vault.setFeeRecipient(stranger);
        notes.push("stranger: vault.setFeeRecipient -> NotCurator");
        vm.stopPrank();
        // The factory's owner is not a vault's manager either, and an admitted filler funds only through the router.
        vm.prank(ADMIN);
        vm.expectRevert(notCurator);
        vault.setPaused(true);
        notes.push("factory owner: vault.setPaused -> NotCurator");
        vm.prank(FILLER);
        vm.expectRevert(notCurator);
        ILegacyIntentVault(address(vault)).fund(splitLoanA, 1, 0, 0);
        notes.push("admitted filler, directly: vault.fund -> NotCurator");
    }

    function _strangerAndTheFactory() internal {
        bytes memory notOwner = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger);
        IntentQuoteVerifier.Plan memory plan;
        IntentVault.Mandate memory mandate;
        mandate.curator = stranger;
        // Creation is closed to all but admitted managers, as published. D43 lets the owner open it; if it is open at
        // the pin, the owner closes it again on the fork so the refusal below is the one exercised, and likewise
        // withdraws its own admission as a creator if it has admitted itself since.
        if (FACTORY.openCreation()) {
            vm.prank(ADMIN);
            FACTORY.setOpenCreation(false);
        }
        if (FACTORY.isCreator(ADMIN)) {
            vm.prank(ADMIN);
            FACTORY.setCreator(ADMIN, false);
        }
        // D42, D47: the core lends only to vaults of this factory, so nobody else can take a lender unit directly, not
        // even of a listing that is still open for funding.
        (uint256 open,) = _newListing(TSLAX, 100e6);
        vm.startPrank(stranger);
        vm.expectRevert(GageV2Rewards.NotFunder.selector);
        CORE.fund(open, 1);
        notes.push("stranger: core.fund of a listing still funding -> NotFunder (D42, D47)");
        vm.expectRevert(IntentQuoteVerifier.NotRouter.selector);
        VERIFIER.consume(plan, "", stranger);
        notes.push("stranger: verifier.consume -> NotRouter");
        vm.expectRevert(IntentQuoteVerifier.NotAuthority.selector);
        VERIFIER.revoke(bytes32(uint256(1)));
        notes.push("stranger: verifier.revoke -> NotAuthority");
        vm.expectRevert(IntentQuoteVerifier.NotAuthority.selector);
        VERIFIER.revokeAll();
        notes.push("stranger: verifier.revokeAll -> NotAuthority");
        vm.expectRevert(IntentFactory.CreationClosed.selector);
        ILegacyIntentCreate(address(FACTORY)).create(mandate);
        notes.push("stranger: factory.create -> CreationClosed");
        vm.expectRevert(notOwner);
        FACTORY.setCreator(stranger, true);
        notes.push("stranger: factory.setCreator -> OwnableUnauthorizedAccount");
        vm.expectRevert(notOwner);
        ILegacyFillerPayout(address(FACTORY)).setFiller(stranger, true, stranger);
        notes.push("stranger: factory.setFiller -> OwnableUnauthorizedAccount");
        vm.expectRevert(notOwner);
        FACTORY.setFillRouter(address(0));
        notes.push("stranger: factory.setFillRouter -> OwnableUnauthorizedAccount");
        vm.expectRevert(notOwner);
        FACTORY.setQuoteSigner(stranger);
        notes.push("stranger: factory.setQuoteSigner -> OwnableUnauthorizedAccount");
        vm.expectRevert(notOwner);
        FACTORY.setProtocolRecipient(address(DEAL_FEE_ROUTER));
        notes.push("stranger: factory.setProtocolRecipient -> OwnableUnauthorizedAccount");
        vm.expectRevert(notOwner);
        FACTORY.assignCategory(MOON, IntentCategory.STOCK);
        notes.push("stranger: factory.assignCategory -> OwnableUnauthorizedAccount");
        vm.expectRevert(notOwner);
        FACTORY.transferOwnership(stranger);
        notes.push("stranger: factory.transferOwnership -> OwnableUnauthorizedAccount");
        vm.expectRevert(ILegacyFillRouter.NotOwner.selector);
        ILegacyFillRouter(address(ROUTER)).setFillerShare(10_000);
        notes.push("stranger: router.setFillerShare -> NotOwner");
        vm.expectRevert(IntentFillRouter.NotFiller.selector);
        ROUTER.investReserve(address(stockVault), 1e6, 0);
        notes.push("stranger: router.investReserve -> NotFiller");
        vm.expectRevert(
            abi.encodeWithSelector(IntentQuoteVerifier.Refused.selector, IntentQuoteVerifier.Refusal.BAD_SIGNATURE)
        );
        ROUTER.fill(plan, "", new uint256[](0));
        notes.push("stranger: router.fill with no signed plan -> Refused(BAD_SIGNATURE)");
        vm.expectRevert(IntentFillRouter.NothingOwed.selector);
        ROUTER.claim(stranger);
        notes.push("anyone: router.claim for a recipient owed nothing -> NothingOwed");
        vm.expectRevert(IntentFillRouter.NotAVault.selector);
        ROUTER.sweepStale(stranger);
        notes.push("anyone: router.sweepStale of a non-vault -> NotAVault");
        vm.stopPrank();
        assertEq(uint8(CORE.getLoan(open).state), uint8(V2State.FUNDING), "the open listing is untouched");
        assertEq(CORE.getLoan(open).filled, 0);
        // A manager the factory admitted cannot create a vault for somebody else, and nobody else can create at all.
        address managerA = nvdaLowFee.CURATOR();
        vm.prank(managerA);
        vm.expectRevert(IntentFactory.CreationClosed.selector);
        ILegacyIntentCreate(address(FACTORY)).create(mandate);
        notes.push("admitted manager naming another curator: factory.create -> CreationClosed");
        mandate.curator = ADMIN;
        assertFalse(FACTORY.isCreator(ADMIN));
        vm.prank(ADMIN);
        vm.expectRevert(IntentFactory.CreationClosed.selector);
        ILegacyIntentCreate(address(FACTORY)).create(mandate);
        notes.push("factory owner, not admitted as a creator: factory.create -> CreationClosed");
    }

    function _managerAndItsCeilings() internal {
        bytes4 invalid = IntentVault.InvalidConfiguration.selector;
        IntentVault vault = nvdaLowFee;
        address manager = vault.CURATOR();
        uint128 loanCeiling = ILegacyIntentBounds(address(vault)).MAX_LOAN_PRINCIPAL();
        uint16 assetCeiling = ILegacyIntentBounds(address(vault)).MAX_ASSET_BPS();
        uint16 bufferFloor = ILegacyIntentBounds(address(vault)).MIN_BUFFER_BPS();
        uint8 rateFloor = ILegacyIntentBounds(address(vault)).MIN_RATE_GRADE_FLOOR();
        uint8 gradeFloor = vault.MIN_GRADE_FLOOR();
        uint16 stockCeiling = ILegacyIntentBounds(address(vault)).categoryCeilingBps(IntentCategory.STOCK);
        // The fixture's vault stands as published, its active cap at the ceiling. Its manager lowers the cap first,
        // so that raising it back to exactly the ceiling at the end is a real move.
        assertEq(vault.maxLoanPrincipal(), loanCeiling, "as published, the active cap is the ceiling");
        uint16 assetBps = vault.maxAssetBps();
        uint16 buffer = vault.bufferBps();
        vm.prank(manager);
        ILegacyIntentBounds(address(vault)).setLimits(loanCeiling / 2, assetBps, buffer);
        notes.push("manager: per-loan cap lowered to half its creation-time ceiling -> accepted");
        assertLt(vault.maxLoanPrincipal(), loanCeiling, "the active cap sits under its ceiling");
        assertEq(vault.CATEGORY_MASK(), 1, "stocks only");
        assertGt(rateFloor, 0);
        assertGt(gradeFloor, 0);

        vm.startPrank(manager);
        vm.expectRevert(invalid);
        ILegacyIntentBounds(address(vault)).setLimits(loanCeiling + 1, assetCeiling, bufferFloor);
        notes.push("manager: per-loan cap one unit above its creation-time ceiling -> InvalidConfiguration");
        vm.expectRevert(invalid);
        ILegacyIntentBounds(address(vault)).setLimits(loanCeiling, assetCeiling + 1, bufferFloor);
        notes.push("manager: per-asset cap one basis point above its creation-time ceiling -> InvalidConfiguration");
        // A vault created with no buffer floor can only break the other bound, the whole of its assets.
        vm.expectRevert(invalid);
        ILegacyIntentBounds(address(vault))
            .setLimits(loanCeiling, assetCeiling, bufferFloor == 0 ? 10_001 : bufferFloor - 1);
        notes.push(
            bufferFloor == 0
                ? "manager: liquidity buffer above 100% (its creation-time floor is zero) -> InvalidConfiguration"
                : "manager: liquidity buffer below its creation-time floor -> InvalidConfiguration"
        );
        vm.expectRevert(invalid);
        ILegacyIntentBounds(address(vault)).setCategoryWeight(IntentCategory.MEME, 1);
        notes.push("manager: a category the vault did not start with (MEME) -> InvalidConfiguration");
        vm.expectRevert(invalid);
        ILegacyIntentBounds(address(vault)).setCategoryWeight(IntentCategory.RH_ECOSYSTEM, 1);
        notes.push("manager: a category the vault did not start with (RH_ECOSYSTEM) -> InvalidConfiguration");
        if (stockCeiling < 10_000) {
            vm.expectRevert(invalid);
            ILegacyIntentBounds(address(vault)).setCategoryWeight(IntentCategory.STOCK, stockCeiling + 1);
            notes.push("manager: its own category above its ceiling -> InvalidConfiguration");
        }
        vm.expectRevert(invalid);
        vault.setAsset(MOON, true);
        notes.push("manager: picking a token of a category outside the mandate -> InvalidConfiguration");
        vm.expectRevert(invalid);
        ILegacyIntentBounds(address(vault)).setMinRateGrade(rateFloor - 1);
        notes.push("manager: rate floor below its creation-time floor -> InvalidConfiguration");
        vm.expectRevert(invalid);
        vault.setMinGrade(gradeFloor - 1);
        notes.push("manager: collateral grade below its creation-time floor -> InvalidConfiguration");
        // The refusals are the ceilings, not a closed door: up to the ceiling the manager may move.
        ILegacyIntentBounds(address(vault)).setLimits(loanCeiling, assetCeiling, bufferFloor);
        vm.stopPrank();
        assertEq(vault.maxLoanPrincipal(), loanCeiling);
        notes.push("manager: per-loan cap raised to exactly its ceiling -> accepted");
    }

    // ================================================================ 7. a settings change and the running loans

    struct Settings {
        Book before_;
        Book changed;
        Book booked;
        Book released;
        Part part;
        uint256 listingId;
        uint256 listingPrincipal;
        uint256 executionFee;
        uint128 capBefore;
        uint128 capAfter;
        uint256 exitAssets;
        bytes32 recordsBefore;
        bytes32 recordsAfter;
    }

    function _settingsChange() internal returns (string memory) {
        scope = "settings";
        IntentVault vault = stockVault;
        // What this vault has running at the start: its one unit of split listing A, still lent, and the schedule.
        uint256 id = splitLoanA;
        Settings memory s;
        V2Loan memory l = CORE.getLoan(id);
        assertEq(uint8(l.state), uint8(V2State.ACTIVE), "active at the start");
        IntentVault.Loan memory held = _held(vault, id);
        IntentVault.Loan memory schedule = _held(vault, scheduleLoan);
        assertTrue(schedule.repaid && !schedule.settled, "the schedule listing's schedule is running");
        s.part = _part(vault, id, l, CORE.lenders(id));
        assertGt(s.part.units, 0);
        s.before_ = _book(vault);
        s.recordsBefore = keccak256(abi.encode(held, schedule));
        address manager = vault.CURATOR();

        // A new listing the vault would fund today, and a signed plan for it (fork only, see `_forkSigner`).
        Vm.Wallet memory signer = _forkSigner();
        (s.listingId, s.listingPrincipal) = _newListing(TSLAX, 400e6);
        IntentQuoteVerifier.Plan memory plan = _plan(s.listingId, vault);
        s.executionFee = plan.allocations[0].executionFee;
        bytes memory signature = _sign(signer, plan);
        uint256[] memory limits = new uint256[](1);
        limits[0] = type(uint256).max;

        // Control: before the change the published router funds it from this vault and the listing activates.
        uint256 snapshot = vm.snapshotState();
        uint256 owed = ROUTER.owed(FACTORY.protocolRecipient());
        vm.prank(FILLER);
        ROUTER.fill(plan, signature, limits);
        assertEq(uint8(CORE.getLoan(s.listingId).state), uint8(V2State.ACTIVE));
        assertEq(CORE.unitsOf(s.listingId, address(vault)), 4);
        assertEq(vault.performingPrincipal() - s.before_.performingPrincipal, s.listingPrincipal);
        assertEq(ROUTER.owed(FACTORY.protocolRecipient()) - owed, s.executionFee, "its execution fee is owed at once");
        assertTrue(vm.revertToState(snapshot));
        scope = "settings";

        // The manager lowers the cap per loan under what the vault already holds in one loan: new funding is refused.
        s.capBefore = vault.maxLoanPrincipal();
        s.capAfter = 100e6;
        assertLt(s.capAfter, held.principal);
        uint16 assetBps = vault.maxAssetBps();
        uint16 buffer = vault.bufferBps();
        vm.prank(manager);
        ILegacyIntentBounds(address(vault)).setLimits(s.capAfter, assetBps, buffer);
        vm.prank(FILLER);
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        ROUTER.fill(plan, signature, limits);
        // Then the manager pauses the vault: funding and deposits are refused, exits and servicing are not.
        vm.prank(manager);
        vault.setPaused(true);
        vm.prank(FILLER);
        vm.expectRevert(IntentVault.PausedError.selector);
        ROUTER.fill(plan, signature, limits);
        vm.prank(DEPOSITOR);
        vm.expectRevert(IntentVault.PausedError.selector);
        vault.deposit(1e6, 0);
        vm.prank(FILLER);
        vm.expectRevert(IntentVault.PausedError.selector);
        ROUTER.investReserve(address(vault), 1e6, 0);
        s.changed = _book(vault);
        s.recordsAfter = keccak256(abi.encode(_held(vault, id), _held(vault, scheduleLoan)));
        assertEq(s.recordsAfter, s.recordsBefore, "the running loans' records are untouched");
        assertEq(s.changed.totalAssets, s.before_.totalAssets);
        assertEq(s.changed.accrualRate, s.before_.accrualRate, "they still accrue");

        // The loans it already holds still settle and pay, the fees still pay out, and the depositor still exits.
        _repay(id);
        vm.prank(stranger);
        vault.settle(_ids(id));
        s.booked = _book(vault);
        assertEq(
            s.booked.cash - s.changed.cash, s.part.payout - s.part.fee, "its unit's slice of the cap, less the fee"
        );
        assertEq(s.booked.totalAssets, s.changed.totalAssets);
        uint256 available = DEAL_FEE_ROUTER.availableUSDG();
        vm.prank(stranger);
        vault.claimFees();
        assertEq(DEAL_FEE_ROUTER.availableUSDG() - available, s.booked.protocolFees);
        uint256 shares = vault.balanceOf(DEPOSITOR) / 10;
        uint256 expected = vault.convertToAssets(shares);
        vm.prank(DEPOSITOR);
        s.exitAssets = vault.redeem(shares, expected);
        assertEq(s.exitAssets, expected, "exits stay open while paused");
        // Both schedules are released at their own term ends, paused or not.
        _releaseSchedulesBefore(_one(vault), NO_DEADLINE);
        s.released = _book(vault);
        assertTrue(_held(vault, id).settled && _held(vault, scheduleLoan).settled, "both released while paused");
        assertEq(s.released.paidInterest, 0);
        assertEq(s.released.earliestMaturity, NO_DEADLINE);
        assertTrue(vault.paused());

        string memory o = _o("result");
        vm.serializeString(
            o,
            "what",
            "A new listing is funded from stocks by the published router as a control and rolled back. The manager then lowers the cap per loan below what the vault already holds in one loan: the same signed plan reverts IneligibleDeal. The manager pauses the vault: the plan, a deposit and a reserve investment revert PausedError. What the vault already has running is untouched: its unit of split listing A is repaid and booked, the fees are paid out, the depositor redeems, and that schedule and the schedule listing's are released at their term ends, all while paused."
        );
        vm.serializeString(
            o,
            "forkOnly",
            "The hosted quote signer's key is held by nobody, so on the fork the factory's owner named a signer the test holds, and the borrower listed a new TSLAx loan for the plan. Every other setting was changed by the vault's manager."
        );
        vm.serializeString(o, "runningLoan", _loanJson("splitA", vault, id, l, held));
        vm.serializeString(
            o, "runningSchedule", _loanJson("schedule", vault, scheduleLoan, CORE.getLoan(scheduleLoan), schedule)
        );
        _n(o, "newListingId", s.listingId);
        _n(o, "newListingPrincipal", s.listingPrincipal);
        _n(o, "newListingExecutionFee", s.executionFee);
        vm.serializeString(o, "control", "before the change the fill succeeded and the listing activated; rolled back");
        _n(o, "maxLoanPrincipalBefore", s.capBefore);
        _n(o, "maxLoanPrincipalAfter", s.capAfter);
        vm.serializeString(o, "fillAfterTheCapWasLowered", "reverts IneligibleDeal");
        vm.serializeString(o, "fillDepositAndReserveInvestmentWhilePaused", "revert PausedError");
        vm.serializeBytes32(o, "runningRecordsHashBefore", s.recordsBefore);
        vm.serializeBytes32(o, "runningRecordsHashAfter", s.recordsAfter);
        vm.serializeString(o, "itsPartOfSplitListingA", _partJson("splitA", s.part));
        _n(o, "depositorRedeemedWhilePaused", s.exitAssets);
        vm.serializeString(o, "0_before", _bookJson("0", s.before_));
        vm.serializeString(o, "1_capLoweredAndPaused", _bookJson("1", s.changed));
        vm.serializeString(o, "2_runningLoanRepaidAndBooked", _bookJson("2", s.booked));
        return vm.serializeString(o, "3_bothSchedulesReleasedWhilePaused", _bookJson("3", s.released));
    }

    // ================================================================ 8. the recipient guard (D30)

    function _recipientGuard() internal returns (string memory) {
        scope = "recipient";
        delete notes;
        bytes4 refused = IntentFactory.NotAFeeProcessor.selector;
        assertGt(FEE_FLOOR.code.length, 0, "the floor is a contract, and still not a fee processor");
        vm.startPrank(ADMIN);
        vm.expectRevert(refused);
        FACTORY.setProtocolRecipient(FEE_FLOOR);
        notes.push("factory owner: setProtocolRecipient(FeeFloor) -> NotAFeeProcessor");
        vm.expectRevert(refused);
        FACTORY.setProtocolRecipient(stranger);
        notes.push("factory owner: setProtocolRecipient(a plain wallet) -> NotAFeeProcessor");
        vm.expectRevert(refused);
        FACTORY.setProtocolRecipient(address(0));
        notes.push("factory owner: setProtocolRecipient(the zero address) -> NotAFeeProcessor");
        vm.expectRevert(refused);
        FACTORY.setProtocolRecipient(address(USDG));
        notes.push(
            "factory owner: setProtocolRecipient(the USDG token, a contract with neither view) -> NotAFeeProcessor"
        );
        vm.expectRevert(refused);
        FACTORY.setProtocolRecipient(address(CORE));
        notes.push(
            "factory owner: setProtocolRecipient(the core: the right USDG(), no availableUSDG()) -> NotAFeeProcessor"
        );
        vm.stopPrank();
        assertEq(FACTORY.protocolRecipient(), address(DEAL_FEE_ROUTER), "unchanged by the refusals");
        // The guard is on the constructor too: a factory cannot be born paying the floor, even with the published code
        // store's two data contracts. This source's guard calls the floor's missing `USDG()` view, which reverts with
        // no data. The data contracts are read before the expected revert.
        (address codeA, address codeB) = (VAULT_CODE.CHUNK_A(), VAULT_CODE.CHUNK_B());
        vm.expectRevert(bytes(""));
        new IntentFactory(
            IntentFactory.Params({
                core: address(CORE),
                reserve: address(RESERVE),
                reserveLens: address(LENS),
                grades: address(GRADES),
                protocolRecipient: FEE_FLOOR,
                initialOwner: ADMIN,
                codeA: codeA,
                codeB: codeB
            })
        );
        notes.push("anyone: new IntentFactory with FeeFloor as the recipient -> reverts (FeeFloor has no USDG())");
        // Control: the fee processor itself is accepted.
        vm.prank(ADMIN);
        FACTORY.setProtocolRecipient(address(DEAL_FEE_ROUTER));
        assertEq(FACTORY.protocolRecipient(), address(DEAL_FEE_ROUTER));
        notes.push("factory owner: setProtocolRecipient(DealFeeRouter) -> accepted");

        string memory o = _o("result");
        vm.serializeString(
            o,
            "what",
            "As the published factory's owner on the fork: the floor, a wallet, the zero address, a token and the core are each refused as protocol recipient with NotAFeeProcessor, the recipient stays the DealFeeRouter, a new factory cannot be constructed with the floor, and the DealFeeRouter itself is accepted."
        );
        vm.serializeAddress(o, "feeFloor", FEE_FLOOR);
        vm.serializeAddress(o, "plainWallet", stranger);
        vm.serializeAddress(o, "protocolRecipientAfter", FACTORY.protocolRecipient());
        return vm.serializeString(o, "calls", notes);
    }

    // ================================================================ 9. no holders, no lending (D31)

    struct Emptied {
        Book empty;
        uint256 invested;
        uint256 loansRepaid;
        uint256 lastShares;
        uint256 lastAssets;
    }

    /// @dev Empty a vault the way it would happen: the filler had part of the idle cash in the reserve, every loan is
    /// repaid and booked, and the only holder redeems every share.
    function _emptied(IntentVault vault) internal returns (Emptied memory e) {
        _assertSoleHolder(vault);
        e.invested = vault.cash() / 2;
        vm.prank(FILLER);
        ROUTER.investReserve(address(vault), e.invested, 0);
        e.loansRepaid = _repayAndBookEverything(vault);
        e.lastShares = vault.balanceOf(DEPOSITOR);
        vm.prank(DEPOSITOR);
        e.lastAssets = vault.redeem(e.lastShares, 0);
        e.empty = _book(vault);
        _assertEmptied(e.empty);
    }

    function _noHolders() internal returns (string memory) {
        scope = "noHolders";
        IntentVault vault = nvdaLowFee;
        Emptied memory e = _emptied(vault);
        bytes4 refused = IntentVault.NoHolders.selector;

        // Directly, as the published router: the only caller the vault would otherwise let through.
        vm.prank(address(ROUTER));
        vm.expectRevert(refused);
        ILegacyIntentVault(address(vault)).fund(splitLoanB, 1, 0, 0);
        // The supply is looked at before the caller, so on an empty vault anybody is told the same thing.
        vm.prank(stranger);
        vm.expectRevert(refused);
        ILegacyIntentVault(address(vault)).fund(splitLoanB, 1, 0, 0);

        // The whole path: a new listing this vault's mandate accepts, a signed plan for it, the admitted filler and
        // the published router (fork only, see `_forkSigner`). The fill reverts, and the plan is not used up.
        Vm.Wallet memory signer = _forkSigner();
        (uint256 listingId, uint256 principal) = _newListing(NVDAX, 100e6);
        IntentQuoteVerifier.Plan memory plan = _plan(listingId, vault);
        bytes memory signature = _sign(signer, plan);
        bytes32 digest = VERIFIER.planHash(plan);
        uint256[] memory limits = new uint256[](1);
        limits[0] = type(uint256).max;
        IntentQuoteVerifier.Refusal reason = IntentPreflight.reason(VERIFIER, plan, signature, FILLER);
        assertEq(uint8(reason), uint8(IntentQuoteVerifier.Refusal.NONE), "the verifier has nothing against the plan");
        vm.prank(FILLER);
        vm.expectRevert(refused);
        ROUTER.fill(plan, signature, limits);
        assertFalse(VERIFIER.consumed(digest), "the plan is still unused");
        assertEq(uint8(CORE.getLoan(listingId).state), uint8(V2State.FUNDING));
        assertEq(keccak256(abi.encode(_book(vault))), keccak256(abi.encode(e.empty)), "the refusal moved nothing");

        // A vault that never had a holder: created on the fork by nvda-low-fee's manager through the published factory,
        // from the mandate nvda-low-fee was published with, and funded by nobody.
        IntentVault fresh = _twin(NVDA_LOW);
        assertEq(fresh.totalSupply(), 0);
        vm.prank(address(ROUTER));
        vm.expectRevert(refused);
        ILegacyIntentVault(address(fresh)).fund(listingId, 4, 0, 0);

        // Control: once somebody holds shares, the very same signed plan fills and the listing activates.
        uint256 deposit = 1000e6;
        IMintable(address(USDG)).mint(entrant, deposit);
        vm.startPrank(entrant);
        USDG.approve(address(vault), deposit);
        uint256 shares = vault.deposit(deposit, 0);
        vm.stopPrank();
        vm.prank(FILLER);
        ROUTER.fill(plan, signature, limits);
        assertTrue(VERIFIER.consumed(digest));
        assertEq(uint8(CORE.getLoan(listingId).state), uint8(V2State.ACTIVE));
        assertEq(CORE.unitsOf(listingId, address(vault)), 4);
        Book memory funded = _book(vault);
        assertEq(funded.performingPrincipal, principal);

        string memory o = _o("result");
        vm.serializeString(
            o,
            "what",
            "The nvda-low-fee vault is emptied on the fork (its loans repaid and booked, its only holder redeems every share). With no share outstanding, fund reverts NoHolders when called as the published router, and so does a complete fill by the admitted filler with a plan the verifier accepts; the plan is not used up and nothing moves. A vault that never had a holder refuses the same way. Once a newcomer deposits, the very same plan fills."
        );
        vm.serializeString(
            o,
            "forkOnly",
            "The emptying, the named signer, the new NVDAx listing, the fresh vault an admitted manager created, and the newcomer's deposit."
        );
        vm.serializeAddress(o, "vault", address(vault));
        vm.serializeAddress(o, "freshVault", address(fresh));
        _n(o, "loansRepaidToEmptyIt", e.loansRepaid);
        _n(o, "lastHolderShares", e.lastShares);
        _n(o, "lastHolderAssets", e.lastAssets);
        _n(o, "listingId", listingId);
        _n(o, "listingPrincipal", principal);
        vm.serializeBytes32(o, "planDigest", digest);
        vm.serializeString(o, "fundAsThePublishedRouter", "reverts NoHolders");
        vm.serializeString(o, "fundAsAStranger", "reverts NoHolders too: the supply is checked before the caller");
        vm.serializeString(o, "routerFillByTheAdmittedFiller", "reverts NoHolders; the plan stays unused");
        vm.serializeString(o, "fundOnAVaultThatNeverHadAHolder", "reverts NoHolders");
        _n(o, "controlDeposit", deposit);
        _n(o, "controlShares", shares);
        vm.serializeString(
            o, "controlFill", "the same plan fills; the listing is ACTIVE with all four units in the vault"
        );
        vm.serializeString(o, "0_emptied", _bookJson("0", e.empty));
        return vm.serializeString(o, "1_afterTheControlFill", _bookJson("1", funded));
    }

    // ================================================================ 10. the next deposit after the last holder left

    struct Newcomer {
        uint256 priceOffered;
        uint256 deposit;
        uint256 shares;
        uint256 value;
        uint256 paidPer1e18Shares;
        uint256 valueAfterFeesClaimed;
        uint256 secondDeposit;
        uint256 secondShares;
        uint256 secondValue;
        uint256 redeemed;
        Book entered;
        Book left;
    }

    function _depositAfterLastHolder() internal returns (string memory) {
        scope = "newcomer";
        IntentVault vault = nvdaLowFee;
        Emptied memory e = _emptied(vault);
        Newcomer memory n;
        // What an empty vault still prices is rounding; the nominal price it offers is that dust over virtual shares.
        n.priceOffered = e.empty.price;
        n.deposit = 1000e6;
        IMintable(address(USDG)).mint(entrant, n.deposit);
        vm.startPrank(entrant);
        USDG.approve(address(vault), n.deposit);
        n.shares = vault.deposit(n.deposit, 0);
        vm.stopPrank();
        n.value = vault.convertToAssets(n.shares);
        n.paidPer1e18Shares = n.deposit * 1e18 / n.shares;
        n.entered = _book(vault);
        assertLe(n.value, n.deposit, "never more than was put in");
        assertGe(n.value + 2, n.deposit, "and at most rounding less: the newcomer's shares are worth the deposit");
        assertEq(n.entered.paidInterest, 0, "no paid interest was waiting for them");
        assertLe(n.entered.totalAssets - n.deposit, 3, "nor anything else but rounding");

        // The fees the earlier loans earned are the manager's and the protocol's: paying them changes nothing here.
        vm.prank(stranger);
        vault.claimFees();
        n.valueAfterFeesClaimed = vault.convertToAssets(n.shares);
        assertEq(n.valueAfterFeesClaimed, n.value);

        // A second depositor gets the same terms, and the first loses nothing to them.
        n.secondDeposit = 500e6;
        IMintable(address(USDG)).mint(second, n.secondDeposit);
        vm.startPrank(second);
        USDG.approve(address(vault), n.secondDeposit);
        n.secondShares = vault.deposit(n.secondDeposit, 0);
        vm.stopPrank();
        n.secondValue = vault.convertToAssets(n.secondShares);
        assertGe(n.secondValue + 2, n.secondDeposit);
        assertLe(n.secondValue, n.secondDeposit);
        assertGe(vault.convertToAssets(n.shares) + 1, n.value, "the first newcomer is not diluted");
        assertApproxEqAbs(n.secondDeposit * 1e18 / n.secondShares, n.paidPer1e18Shares, 2, "the same price per share");

        // And the newcomer can take it all out again.
        vm.prank(entrant);
        n.redeemed = vault.redeem(n.shares, 0);
        assertGe(n.redeemed + 2, n.deposit);
        assertLe(n.redeemed, n.deposit);
        n.left = _book(vault);

        string memory o = _o("result");
        vm.serializeString(
            o,
            "what",
            "After the last holder of the nvda-low-fee vault left (with part of the cash having been through the reserve), a newcomer deposits. The rounding the empty vault still prices sets the number of shares per USDG, not their worth: the newcomer's shares are worth the deposit to within rounding, the fees owed from before are not theirs and do not move their value, a second depositor gets the same price, and the newcomer redeems the deposit back."
        );
        vm.serializeAddress(o, "vault", address(vault));
        _n(o, "lastHolderShares", e.lastShares);
        _n(o, "lastHolderAssets", e.lastAssets);
        _n(o, "pricedAssetsLeftInTheEmptyVault", e.empty.totalAssets);
        _n(o, "reserveAssetsLeftInTheEmptyVault", e.empty.reserveAssets);
        _n(o, "cashLeftInTheEmptyVault", e.empty.cash);
        _n(o, "nominalAssetsPer1e18SharesOfferedByTheEmptyVault", n.priceOffered);
        _n(o, "deposit", n.deposit);
        _n(o, "sharesMinted", n.shares);
        _n(o, "depositPer1e18SharesMinted", n.paidPer1e18Shares);
        _n(o, "valueOfThoseSharesRightAfter", n.value);
        _n(o, "newcomerShortfall", n.deposit - n.value);
        _n(o, "valueAfterTheOldFeesWereClaimed", n.valueAfterFeesClaimed);
        _n(o, "secondDeposit", n.secondDeposit);
        _n(o, "secondSharesMinted", n.secondShares);
        _n(o, "secondValueRightAfter", n.secondValue);
        _n(o, "newcomerRedeemedEverythingFor", n.redeemed);
        vm.serializeString(o, "0_emptied", _bookJson("0", e.empty));
        vm.serializeString(o, "1_afterTheNewcomerEntered", _bookJson("1", n.entered));
        return vm.serializeString(o, "2_afterTheNewcomerLeft", _bookJson("2", n.left));
    }

    // ================================================================ fork-only fixtures

    /// @dev The hosted signer's key is one the rates service made and nobody holds, so a plan can only be signed on
    /// the fork by a signer the factory's owner names there. Apart from what `_openForTheFixture` and `_refreshGrades`
    /// restore, it is the one setting here not made by a vault's manager.
    function _forkSigner() internal returns (Vm.Wallet memory signer) {
        signer = vm.createWallet("s8-fork-quote-signer");
        vm.prank(ADMIN);
        FACTORY.setQuoteSigner(signer.addr);
    }

    function _sign(Vm.Wallet memory signer, IntentQuoteVerifier.Plan memory plan) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, VERIFIER.planHash(plan));
        return abi.encodePacked(r, s, v);
    }

    /// @dev The borrower lists the registry's minimum of `token` for seven days at a cost twice the modeled one.
    function _newListing(address token, uint128 principal) internal returns (uint256 id, uint256 principal_) {
        uint32 term = 7 days;
        uint256 modeled = GRADES.modeledCostOf(token, term);
        assertGt(modeled, 0, "a current modeled cost is published for this token and term");
        ICollateralRegistry.ERC20Config memory config =
            ICollateralRegistry(address(CORE.REGISTRY())).getERC20Config(token);
        assertTrue(config.allowed);
        uint256 cost = uint256(principal) * modeled * 2 / 10_000 + 1e5;
        assertLe(cost, type(uint64).max);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 cap = principal + uint128(cost);
        IMintable(token).mint(BORROWER, config.minAmount);
        uint40 deadline = uint40(vm.getBlockTimestamp() + 1 days);
        vm.startPrank(BORROWER);
        IERC20(token).approve(address(CORE), config.minAmount);
        id = CORE.list(Collateral(Kind.ERC20, token, config.minAmount), principal, cap, term, deadline, false);
        vm.stopPrank();
        principal_ = principal;
    }

    /// @dev The plan an honest signer would produce now for the whole listing from one vault.
    function _plan(uint256 id, IntentVault vault) internal view returns (IntentQuoteVerifier.Plan memory) {
        return _planFor(id, _one(vault), _units(4, 0, 0));
    }

    /// @dev The plan an honest signer would produce now for the whole listing from `vaults`, each taking `units`
    /// lender units. The plan lists them in ascending address order, the only order the verifier accepts (a twin's
    /// address is wherever the factory created it), and each takes the next empty units as the verifier and the core
    /// walk them.
    function _planFor(uint256 id, IntentVault[] memory vaults, uint8[] memory units)
        internal
        view
        returns (IntentQuoteVerifier.Plan memory p)
    {
        (vaults, units) = _byAddress(vaults, units);
        V2Loan memory l = CORE.getLoan(id);
        p.engine = address(CORE);
        p.listingId = id;
        p.filler = FILLER;
        p.token = l.token;
        p.kind = uint8(l.kind);
        p.collateral = l.collateral;
        p.principal = l.principal;
        p.cap = l.cap;
        p.term = l.term;
        p.costBps = GRADES.modeledCostOf(l.token, l.term);
        p.feePolicy = VERIFIER.FEE_POLICY_VERSION();
        p.epoch = VERIFIER.epoch();
        p.issuedAt = uint40(vm.getBlockTimestamp());
        p.expiry = uint40(vm.getBlockTimestamp() + 90);
        p.evidence = keccak256("s8 testnet fork fixture");
        p.allocations = new IntentQuoteVerifier.Allocation[](vaults.length);
        address[4] memory lenders = CORE.lenders(id);
        uint8 next;
        for (uint256 i; i < vaults.length; ++i) {
            if (i != 0) assertTrue(address(vaults[i - 1]) < address(vaults[i]), "vaults in ascending order");
            uint256 principal;
            uint256 repayment;
            uint8 left = units[i];
            for (; next < 4 && left != 0; ++next) {
                if (lenders[next] != address(0)) continue;
                principal += _slice(l.principal, next);
                repayment += _slice(l.cap, next);
                --left;
            }
            assertEq(left, 0, "enough empty units");
            p.allocations[i] = _allocation(vaults[i], units[i], principal, repayment - principal, p.costBps);
        }
    }

    /// @dev `vaults` sorted by address into new arrays, each keeping its own `units`.
    function _byAddress(IntentVault[] memory vaults, uint8[] memory units)
        internal
        pure
        returns (IntentVault[] memory sorted, uint8[] memory sortedUnits)
    {
        sorted = new IntentVault[](vaults.length);
        sortedUnits = new uint8[](vaults.length);
        for (uint256 i; i < vaults.length; ++i) {
            uint256 j = i;
            for (; j != 0 && address(sorted[j - 1]) > address(vaults[i]); --j) {
                (sorted[j], sortedUnits[j]) = (sorted[j - 1], sortedUnits[j - 1]);
            }
            (sorted[j], sortedUnits[j]) = (vaults[i], units[i]);
        }
    }

    /// @dev One vault's purchase: its amounts, the fee terms it is read under, its minimum and its execution fee.
    function _allocation(IntentVault vault, uint8 units, uint256 principal, uint256 interest, uint32 costBps)
        internal
        view
        returns (IntentQuoteVerifier.Allocation memory a)
    {
        a.vault = address(vault);
        a.units = units;
        // Both fit: each is a part of the listing's principal or cap, which are uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        a.principal = uint128(principal);
        // forge-lint: disable-next-line(unsafe-typecast)
        a.interest = uint128(interest);
        a.minRateGrade = vault.minRateGrade();
        a.capBps = vault.executionCapBps();
        a.managerBps = vault.feeBps();
        uint256 minimum = IntentFeeMath.minimumInterest(a.principal, costBps, a.minRateGrade);
        (bool ok, uint256 fee) = IntentFeeMath.executionFee(a.interest, minimum, a.capBps);
        require(ok && minimum <= a.interest, "the listing pays the vault's floor");
        // Both fit: each is at most the listing's interest, which is a uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        a.minimum = uint128(minimum);
        // forge-lint: disable-next-line(unsafe-typecast)
        a.executionFee = uint128(fee);
        // The signed ceiling is the live reserve quote for this complete purchase.
        // forge-lint: disable-next-line(unsafe-typecast)
        a.maxReserveShares = uint128(vault.RESERVE().previewWithdraw(uint256(a.principal) + fee));
    }

    // ================================================================ shared

    struct Book {
        uint256 time;
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 price;
        uint256 priceX18;
        uint256 cash;
        uint256 reserveShares;
        uint256 reserveAssets;
        uint256 reservePayable;
        uint256 performingPrincipal;
        uint256 accruedInterest;
        uint256 paidInterest;
        uint256 unearnedInterest;
        uint256 freeLiquidity;
        uint256 curatorFees;
        uint256 protocolFees;
        uint256 executionFees;
        uint256 executionPending;
        uint256 unassignedCash;
        uint256 usdgHeld;
        uint256 accrualRate;
        uint256 earliestMaturity;
    }

    function _book(IntentVault vault) internal view returns (Book memory b) {
        b.time = vm.getBlockTimestamp();
        b.totalAssets = vault.totalAssets();
        b.totalSupply = vault.totalSupply();
        b.price = vault.convertToAssets(1e18);
        b.priceX18 = (b.totalAssets + 1) * 1e36 / (b.totalSupply + VIRTUAL_SHARES);
        b.cash = vault.cash();
        b.reserveShares = vault.reserveShares();
        b.reserveAssets = RESERVE.convertToAssets(b.reserveShares);
        // What the vault counts of its reserve position: its value, as far as the reserve can pay now.
        uint256 payable_ = LENS.withdrawable(address(RESERVE), address(vault));
        b.reservePayable = b.reserveAssets < payable_ ? b.reserveAssets : payable_;
        b.performingPrincipal = vault.performingPrincipal();
        b.accruedInterest = vault.accruedInterest();
        b.paidInterest = IIntentVaultD29(address(vault)).paidInterest();
        b.unearnedInterest = IIntentVaultD29(address(vault)).unearnedInterest();
        b.freeLiquidity = vault.freeLiquidity();
        b.curatorFees = vault.curatorFees();
        b.protocolFees = vault.protocolFees();
        b.executionFees = vault.executionFees();
        b.executionPending = vault.executionPending();
        b.unassignedCash = vault.unassignedCash();
        b.usdgHeld = USDG.balanceOf(address(vault));
        b.accrualRate = ILegacyIntentVault(address(vault)).accrualRate();
        b.earliestMaturity = vault.earliestMaturity();
        // The two identities every reading must satisfy.
        assertEq(
            b.totalAssets,
            b.cash + b.reserveAssets + b.performingPrincipal + b.accruedInterest - b.paidInterest,
            "priced assets"
        );
        assertEq(b.freeLiquidity, b.cash + b.reservePayable - b.unearnedInterest, "free liquidity");
    }

    /// @dev After a settle has harvested, every USDG the vault holds is on one of its ledgers.
    function _assertBacked(IntentVault vault, Book memory b) internal view {
        assertEq(
            b.usdgHeld,
            b.cash + b.curatorFees + b.protocolFees + b.executionFees + b.executionPending + b.unassignedCash
                + vault.pocketLiability(address(USDG)),
            "every USDG held is accounted for"
        );
    }

    function _held(IntentVault vault, uint256 id) internal view returns (IntentVault.Loan memory h) {
        (bool ok, bytes memory data) = address(vault).staticcall(abi.encodeWithSelector(vault.loans.selector, id));
        require(ok, "loans(id)");
        h = abi.decode(data, (IntentVault.Loan));
    }

    /// @dev Read from the core at the start: active, in term, and all four units held by this vault.
    function _activeLoanHeldWhole(IntentVault vault, uint256 id) internal view returns (V2Loan memory l) {
        l = CORE.getLoan(id);
        assertEq(uint8(l.state), uint8(V2State.ACTIVE), "active at the start");
        assertEq(CORE.unitsOf(id, address(vault)), 4, "the vault holds all four units");
        assertEq(CORE.ownerOf(id), BORROWER, "the test borrower holds the reclaim right");
        IntentVault.Loan memory h = _held(vault, id);
        assertEq(h.principal, l.principal);
        assertEq(h.maturity, uint256(l.fundedAt) + l.term, "the vault knows the exact end of the term");
        assertEq(h.maturity, vault.earliestMaturity(), "it is the vault's earliest loan");
        assertLt(vm.getBlockTimestamp(), h.maturity, "still in term");
        assertGt(h.rate, 0, "accruing");
        assertTrue(h.executionEarned || h.executionFee == 0);
        _assertSoleHolder(vault);
    }

    /// @dev The holder of the reclaim right pays the whole cap to the core; the USDG is the mock's public mint.
    function _repay(uint256 id) internal {
        V2Loan memory l = CORE.getLoan(id);
        address owner = CORE.ownerOf(id);
        IMintable(address(USDG)).mint(owner, l.cap);
        vm.startPrank(owner);
        USDG.approve(address(CORE), l.cap);
        CORE.reclaim(id, owner);
        vm.stopPrank();
        assertEq(uint8(CORE.getLoan(id).state), uint8(V2State.REPAID));
    }

    /// @dev As the keeper would: in the order their terms end, move to each term end before `upTo` and release, in
    /// every vault that holds it, the schedule that ends there. Only schedules of repaid loans may end on the way: an
    /// unpaid loan reaching its term here would be a default, which no caller of this means to cause.
    function _releaseSchedulesBefore(IntentVault[] memory vaults, uint40 upTo) internal {
        uint256 last = CORE.loanCount();
        while (true) {
            uint40 next = NO_DEADLINE;
            for (uint256 v; v < vaults.length; ++v) {
                uint40 end = vaults[v].earliestMaturity();
                if (end < next) next = end;
            }
            if (next >= upTo) return;
            vm.warp(next);
            for (uint256 v; v < vaults.length; ++v) {
                if (vaults[v].earliestMaturity() != next) continue;
                _expectSettlementDue(vaults[v]);
                for (uint256 id = firstListing; id <= last; ++id) {
                    IntentVault.Loan memory h = _held(vaults[v], id);
                    if (h.principal == 0 || h.settled || h.maturity != next) continue;
                    assertTrue(h.repaid, "only the schedule of a repaid loan ends on the way");
                    vm.prank(stranger);
                    vaults[v].settle(_ids(id));
                    assertTrue(_held(vaults[v], id).settled, "released at its own term end");
                }
            }
        }
    }

    /// @dev The fee a vault takes when `payout` arrives for a loan it holds, and the protocol's tenth of it.
    function _performanceFee(IntentVault.Loan memory h, uint256 payout)
        internal
        pure
        returns (uint256 fee, uint256 protocol)
    {
        fee = IntentFeeMath.performanceFee(payout - h.principal, h.executionFee, h.feeBps);
        protocol = fee * IntentFeeMath.PROTOCOL_SHARE_BPS / IntentFeeMath.BPS;
    }

    /// @dev Past an unsettled term end a redemption is refused, and a deposit too (a paused vault refuses that anyway).
    function _expectSettlementDue(IntentVault vault) internal {
        if (!vault.paused()) {
            vm.prank(DEPOSITOR);
            vm.expectRevert(IntentVault.SettlementDue.selector);
            vault.deposit(1e6, 0);
        }
        vm.prank(DEPOSITOR);
        vm.expectRevert(IntentVault.SettlementDue.selector);
        vault.redeem(1e18, 0);
    }

    function _slice(uint256 total, uint8 i) internal pure returns (uint256) {
        return total / 4 + (i < total % 4 ? 1 : 0);
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _one(IntentVault vault) internal pure returns (IntentVault[] memory vaults) {
        vaults = new IntentVault[](1);
        vaults[0] = vault;
    }

    function _oneName(string memory name) internal pure returns (string[] memory names) {
        names = new string[](1);
        names[0] = name;
    }

    /// @dev The three fixture vaults that hold split listing A between them (a plan lists them by address instead).
    function _trio() internal view returns (IntentVault[] memory vaults) {
        vaults = new IntentVault[](3);
        (vaults[0], vaults[1], vaults[2]) = (nvdaLowFee, nvdaHighFee, stockVault);
    }

    /// @dev The four fixture vaults, by the publication's role, and the published vaults of those roles.
    function _fixture() internal view returns (IntentVault[] memory vaults) {
        vaults = new IntentVault[](4);
        (vaults[0], vaults[1], vaults[2], vaults[3]) = (nvdaLowFee, nvdaHighFee, stockVault, memeVault);
    }

    function _publishedFixture() internal pure returns (IntentVault[] memory vaults) {
        vaults = new IntentVault[](4);
        (vaults[0], vaults[1], vaults[2], vaults[3]) = (NVDA_LOW, NVDA_HIGH, STOCKS, MEMES);
    }

    function _trioNames() internal pure returns (string[] memory names) {
        names = new string[](3);
        (names[0], names[1], names[2]) = ("nvdaLowFee", "nvdaHighFee", "stocks");
    }

    /// @dev The publication's six vaults, in the order the factory created them.
    function _all() internal pure returns (IntentVault[] memory vaults) {
        vaults = new IntentVault[](6);
        (vaults[0], vaults[1], vaults[2]) = (NVDA_LOW, NVDA_HIGH, STOCKS);
        (vaults[3], vaults[4], vaults[5]) = (MEMES, COMMODITIES, RH_ECO);
    }

    function _allNames() internal pure returns (string[] memory names) {
        names = new string[](6);
        (names[0], names[1], names[2]) = ("nvdaLowFee", "nvdaHighFee", "stocks");
        (names[3], names[4], names[5]) = ("memes", "commodities", "rhEco");
    }

    // ---------------------------------------------------------------- evidence

    /// @dev Serialized objects outlive a state revert, so every scenario names its own.
    function _o(string memory name) internal view returns (string memory) {
        return string.concat(scope, ".", name);
    }

    function _n(string memory object, string memory key, uint256 value) internal returns (string memory) {
        return vm.serializeString(object, key, vm.toString(value));
    }

    function _loanJson(string memory tag, IntentVault vault, uint256 id, V2Loan memory l, IntentVault.Loan memory h)
        internal
        returns (string memory)
    {
        string memory o = _o(string.concat("loan.", tag));
        _n(o, "listingId", id);
        vm.serializeAddress(o, "vault", address(vault));
        vm.serializeAddress(o, "collateralToken", l.token);
        _n(o, "collateral", l.collateral);
        _n(o, "principal", l.principal);
        _n(o, "cap", l.cap);
        _n(o, "term", l.term);
        _n(o, "fundedAt", l.fundedAt);
        _n(o, "termEnd", h.maturity);
        _n(o, "unitsHeldByTheVault", CORE.unitsOf(id, address(vault)));
        _n(o, "principalHeldByTheVault", h.principal);
        _n(o, "managerFeeBps", h.feeBps);
        _n(o, "executionFeePaidAtTheFill", h.executionFee);
        _n(o, "netInterest", h.interest);
        return _n(o, "ratePerSecondX1e18", h.rate);
    }

    function _partJson(string memory name, Part memory p) internal returns (string memory) {
        string memory o = _o(string.concat("part.", name));
        _n(o, "units", p.units);
        _n(o, "principal", p.principal);
        _n(o, "creditedByTheCore", p.payout);
        _n(o, "netInterest", p.interest);
        _n(o, "performanceFee", p.fee);
        return _n(o, "protocolPartOfFee", p.protocol);
    }

    function _bookJson(string memory name, Book memory b) internal returns (string memory) {
        string memory o = _o(string.concat("book.", name));
        _n(o, "time", b.time);
        _n(o, "totalAssets", b.totalAssets);
        _n(o, "totalSupply", b.totalSupply);
        _n(o, "assetsPer1e18Shares", b.price);
        _n(o, "assetsPer1e18SharesX1e18", b.priceX18);
        _n(o, "cash", b.cash);
        _n(o, "reserveShares", b.reserveShares);
        _n(o, "reserveAssets", b.reserveAssets);
        _n(o, "reservePayableNow", b.reservePayable);
        _n(o, "lentPrincipal", b.performingPrincipal);
        _n(o, "accruedInterest", b.accruedInterest);
        _n(o, "paidInterest", b.paidInterest);
        _n(o, "heldUnearnedCash", b.unearnedInterest);
        _n(o, "freeLiquidity", b.freeLiquidity);
        _n(o, "managerFeesClaimable", b.curatorFees);
        _n(o, "protocolFeesClaimable", b.protocolFees);
        _n(o, "executionFeesHeld", b.executionFees);
        _n(o, "usdgHeld", b.usdgHeld);
        _n(o, "accrualRateX1e18", b.accrualRate);
        return _n(o, "earliestMaturity", b.earliestMaturity);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {DealVault} from "../DealVault.sol";
import {DealRewards} from "../token/DealRewards.sol";
import {ICollateralRegistry} from "../interfaces/ICollateralRegistry.sol";
import {IDealVault} from "../interfaces/IDealVault.sol";
import {IDrip} from "../interfaces/token/IDrip.sol";
import {IMorphoFlashLoan, IMorphoFlashLoanCallback} from "../interfaces/IMorphoFlashLoan.sol";
import {Kind, Collateral} from "../types/Types.sol";
import {GageV2Rewards} from "../v2/GageV2Rewards.sol";
import {V2Loan, V2State, unitSlice} from "../v2/V2Types.sol";
import {LendRewardsLender} from "./LendRewardsLender.sol";

/// @dev What the bridge reads from a Gage V2 core.
interface ILendRewardsCore {
    function getLoan(uint256 id) external view returns (V2Loan memory);
    function REWARDS() external view returns (GageV2Rewards);
    function BRIDGE() external view returns (address);
    function SGAGE() external view returns (IERC20);
}

/// @dev What the bridge calls on a lending vault: its share supply, and its harvest, which indexes received sGAGE.
interface ILendRewardsVault {
    function totalSupply() external view returns (uint256);
    function harvestRewards(uint256[] calldata ids) external;
}

/// @notice Weekly-pot sGAGE for the loans of one lend generation. The generation's fee processor forwards its
///         fees, converted to USDG, here. For each list of the core's loans the keeper names, the bridge spends USDG it
///         holds when the call begins, at most the call's budget (`mirrorBudget`), as the fees of V1 mirror deals, one
///         per loan term: the principal is a Morpho flash loan, `LENDER` funds the deal, the bridge registers it with
///         DealRewards, repays it and returns the loan in the same call. The whole fee reaches the V1 fee sink, so the
///         floor, and DealRewards grants the deal's two drips as for any funded deal. The lender drip is owed to the
///         loans' vaults and the borrower drip to their borrowers, each loan by its origination fee and each vault by
///         its quarters, and both are paid as the drips unlock.
/// @dev A call's budget is at most `MAX_SHARE_BPS` of its loans' share, by origination fee, of every USDG the bridge has
///      mirrored or holds (LB-02). Fees reach the bridge in lumps, often after the loans that paid them were
///      mirrored; spent whole by the next call, a pot went to whichever loans were named next, however small their
///      fees, so a loan opened while one waited took it. What a call may not spend waits for later loans: each call is
///      held to 1.25 times the USDG per unit of origination fee that the bridge has mirrored or holds. The bound is
///      per call: a backlog of more loans than one call names, whose fees already arrived, or one owner's loans named
///      in successive calls can still take more. The average counts only the loans mirrored here: wire a bridge
///      before its generation's first loan, never beside a running ledger.
///      One bridge per core, so that every weight is a fee in the same asset. The bridge is its own V1 collateral: one
///      unit that only travels to the V1 vault and back, admitted once on the V1 registry. The keeper pays vaults, which
///      index the sGAGE at once; borrowers claim their own. A loan the core's own ledger rewards is refused,
///      and so is a loan already mirrored. Nothing here can move a loan, a vault's assets or anyone's sGAGE but the
///      bridge's own; the owner names the keeper and, when V1 takes no deals, can send the held fees to the floor.
contract LendRewardsBridge is ERC20, Ownable2Step, ReentrancyGuardTransient, IMorphoFlashLoanCallback {
    using SafeERC20 for IERC20;

    /// @notice Most loans one `mirror` call may name.
    uint256 public constant MAX_LOANS = 64;
    /// @notice Most distinct loan terms in one `mirror` call: one mirror deal, and one batch, per term.
    uint256 public constant MAX_TERMS = 3;
    /// @notice Most a `mirror` call spends, in basis points of its loans' share, by origination fee among every loan
    ///         mirrored and them, of every USDG mirrored or held (LB-02). Above one, a pot that arrived after its loans
    ///         drains to later loans; 1.25 is 1 / 0.8: at DealRewards' cap of 80% of a fee's value, the sGAGE a loan
    ///         earns is worth at most its share of every fee.
    uint256 public constant MAX_SHARE_BPS = 12_500;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    IERC20 public immutable USDG;
    IERC20 public immutable SGAGE;
    DealVault public immutable VAULT;
    ICollateralRegistry public immutable REGISTRY;
    DealRewards public immutable REWARDS;
    IDrip public immutable DRIP;
    IMorphoFlashLoan public immutable MORPHO;
    ILendRewardsCore public immutable CORE;
    GageV2Rewards public immutable CORE_REWARDS;
    /// @notice Where `sendToFloor` sends held fees: the fee route the processor forwarded to before the bridge.
    address public immutable FEE_ROUTER;
    LendRewardsLender public immutable LENDER;

    /// @notice One mirror deal and the loans it rewards.
    struct Batch {
        uint256 dealId;
        bytes32 lenderDrip;
        bytes32 borrowerDrip;
        uint128 lenderReward;
        uint128 borrowerReward;
        uint128 fee;
        uint32 term;
        uint16 loans;
    }

    /// @dev A named loan as the bridge weighs it.
    struct Named {
        uint32 term;
        uint256 group;
        uint128 weight;
        address borrower;
        address[4] lenders;
    }

    address public keeper;
    uint256 public batchCount;
    /// @notice The origination fees of every loan mirrored, in the core's asset: the weights `mirrorBudget` shares by.
    uint256 public originationFeesMirrored;
    /// @notice The USDG every mirror deal paid as its fee.
    uint256 public usdgMirrored;
    mapping(uint256 batchId => Batch) internal _batches;
    /// @notice The batch that mirrored a loan; zero while none has.
    mapping(uint256 loanId => uint256 batchId) public mirroredIn;
    /// @notice A vault's part of a batch's lender drip, out of 1e18.
    mapping(uint256 batchId => mapping(address vault => uint256)) public vaultShare;
    /// @notice A borrower's part of a batch's borrower drip, out of 1e18.
    mapping(uint256 batchId => mapping(address borrower => uint256)) public borrowerShare;
    mapping(uint256 batchId => mapping(address vault => uint256)) public vaultPaid;
    mapping(uint256 batchId => mapping(address borrower => uint256)) public borrowerPaid;

    bool private transient _flashing;
    uint256 private transient _flashDeal;

    event KeeperSet(address indexed keeper);
    event Mirrored(
        uint256 indexed batchId,
        uint256 indexed dealId,
        uint32 term,
        uint256 fee,
        uint128 lenderReward,
        uint128 borrowerReward,
        uint16 loans
    );
    event LoanMirrored(
        uint256 indexed batchId, uint256 indexed loanId, address indexed borrower, uint128 originationFee
    );
    event VaultPaid(uint256 indexed batchId, address indexed vault, uint256 amount);
    event BorrowerClaimed(uint256 indexed batchId, address indexed borrower, address to, uint256 amount);
    event SentToFloor(address indexed to, uint256 amount);

    error ZeroAddress();
    error CoreBridged(address bridge);
    error TokenMismatch();
    error NotKeeper(address caller);
    error LoanCount(uint256 count);
    error NoFees();
    error TooManyTerms();
    error LoanNotActivated(uint256 loanId);
    error LoanWithoutFee(uint256 loanId);
    error LoanRewardedByCore(uint256 loanId);
    error LoanAlreadyMirrored(uint256 loanId, uint256 batchId);
    error LoanWithoutLender(uint256 loanId);
    error ZeroFee(uint32 term);
    error CycleMismatch(uint256 dealId);
    error RewardBelowMinimum(uint256 reward, uint256 minimum);
    error UnexpectedFlashLoan();
    error ReceiptLocked(address from, address to);
    error UnknownBatch(uint256 batchId);
    error LengthMismatch();

    /// @param initialOwner The Safe: names the keeper, may send held fees to the floor.
    /// @param keeper_ The only caller of `mirror`.
    /// @param core The lend generation's core; it must be unbridged and pay rewards in the same sGAGE.
    /// @param rewards V1 DealRewards; its vault, drip and sGAGE are the bridge's.
    /// @param morpho Morpho Blue, the flash lender of each mirror deal's principal.
    /// @param feeRouter The fee route the processor forwarded to before (DealFeeRouter).
    constructor(
        address initialOwner,
        address keeper_,
        ILendRewardsCore core,
        DealRewards rewards,
        IMorphoFlashLoan morpho,
        address feeRouter
    ) ERC20("gage lend rewards receipt", "gLRR") Ownable(initialOwner) {
        if (
            keeper_ == address(0) || address(core) == address(0) || address(rewards) == address(0)
                || address(morpho) == address(0) || feeRouter == address(0)
        ) revert ZeroAddress();
        address coreBridge = core.BRIDGE();
        if (coreBridge != address(0)) revert CoreBridged(coreBridge);
        DealVault vault = DealVault(address(rewards.VAULT()));
        IERC20 sgage = rewards.SGAGE();
        if (address(core.SGAGE()) != address(sgage)) revert TokenMismatch();

        USDG = vault.USDG();
        SGAGE = sgage;
        VAULT = vault;
        REGISTRY = vault.REGISTRY();
        REWARDS = rewards;
        DRIP = rewards.DRIP();
        MORPHO = morpho;
        CORE = core;
        CORE_REWARDS = core.REWARDS();
        FEE_ROUTER = feeRouter;
        keeper = keeper_;
        LENDER = new LendRewardsLender(IDealVault(address(vault)), USDG, sgage, DRIP);

        _mint(address(this), 1);
        _approve(address(this), address(vault), type(uint256).max);
        USDG.forceApprove(address(vault), type(uint256).max);
        emit KeeperSet(keeper_);
    }

    // ----------------------------------------------------------------- keeper: mirror

    /// @notice Mirrors the named loans' fees into V1 deals, one per loan term, spending the USDG the bridge holds when
    ///         the call begins up to `mirrorBudget` of the loans' origination fees. The rest waits for later loans, so
    ///         loans named when a pot waits take only their share of it (LB-02).
    /// @dev The budget is split between terms by origination fee; each deal's fee is the largest its principal reproduces
    ///      exactly at the V1 fee rate, and the rounding stays for later calls. Creates one batch per term, numbered
    ///      in a row from the returned id, in the order the terms first appear in `loanIds`. Reverts `NoFees` when the
    ///      budget is nothing: nothing held, or a share that rounds to nothing.
    /// @param loanIds Activated loans of `CORE`, none mirrored before, none rewarded by the core's own ledger.
    /// @param minReward Least sGAGE the deals must earn in all, against a budget or rate that moved since the quote.
    /// @return firstBatch The first batch created.
    function mirror(uint256[] calldata loanIds, uint256 minReward) external nonReentrant returns (uint256 firstBatch) {
        if (msg.sender != keeper) revert NotKeeper(msg.sender);
        uint256 n = loanIds.length;
        if (n == 0 || n > MAX_LOANS) revert LoanCount(n);
        uint256 held = USDG.balanceOf(address(this));
        if (held == 0) revert NoFees();

        firstBatch = batchCount + 1;
        Named[] memory loans = new Named[](n);
        uint32[MAX_TERMS] memory terms;
        uint256[MAX_TERMS] memory weights;
        uint256 groups;
        uint256 total;
        for (uint256 i; i < n; ++i) {
            Named memory m = _read(loanIds[i]);
            uint256 g;
            while (g < groups && terms[g] != m.term) ++g;
            if (g == groups) {
                if (groups == MAX_TERMS) revert TooManyTerms();
                terms[groups++] = m.term;
            }
            m.group = g;
            weights[g] += m.weight;
            total += m.weight;
            mirroredIn[loanIds[i]] = firstBatch + g;
            loans[i] = m;
        }
        batchCount = firstBatch + groups - 1;
        uint256 available = _budget(held, total);
        if (available == 0) revert NoFees();
        originationFeesMirrored += total;

        uint256 spent;
        uint256 rewarded;
        for (uint256 g; g < groups; ++g) {
            uint256 fee = g + 1 == groups ? available - spent : Math.mulDiv(available, weights[g], total);
            spent += fee;
            uint256 batchId = firstBatch + g;
            (uint256 dealId, uint256 dealFee) = _open(terms[g], fee);
            usdgMirrored += dealFee;
            rewarded += _record(batchId, dealId, dealFee, terms[g]);
            _assign(batchId, g, weights[g], loans, loanIds);
        }
        if (rewarded < minReward) revert RewardBelowMinimum(rewarded, minReward);
    }

    /// @inheritdoc IMorphoFlashLoanCallback
    /// @dev The mirror deal, start to finish, inside the flash loan that funds it.
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != address(MORPHO) || !_flashing) revert UnexpectedFlashLoan();
        _flashing = false;
        uint32 term = abi.decode(data, (uint32));
        uint128 principal = SafeCast.toUint128(assets);
        uint256 dealId = VAULT.list(Collateral(Kind.ERC20, address(this), 1), principal, term, 0, principal);
        USDG.safeTransfer(address(LENDER), principal);
        LENDER.fund(dealId);
        REWARDS.register(dealId);
        VAULT.withdrawUSDG();
        VAULT.reclaim(dealId);
        LENDER.collect();
        VAULT.withdrawERC20(address(this));
        USDG.forceApprove(address(MORPHO), assets);
        _flashDeal = dealId;
    }

    // ----------------------------------------------------------------- payouts

    /// @notice Pays a vault what its part of a batch's lender drip has unlocked; the keeper only, often and on its own
    ///         clock. A vault's checkpoint collects its core ledger's rewards before every share change but cannot see
    ///         the bridge's, so a payment anyone could time would let a deposit made just before it share what earlier
    ///         holders earned. A depositor shares a payment only by holding through it.
    /// @dev The vault indexes the sGAGE in the same call. A vault with no shares is not paid until it has some, so the
    ///      sGAGE never waits in a vault for its next depositor.
    /// @return amount The sGAGE paid.
    function payVault(uint256 batchId, address vault) external nonReentrant returns (uint256 amount) {
        if (msg.sender != keeper) revert NotKeeper(msg.sender);
        amount = _payVault(batchId, vault);
    }

    /// @notice `payVault` for each pair of `batchIds[i]` and `vaults[i]`; the keeper only.
    /// @return total The sGAGE paid in all.
    function payVaults(uint256[] calldata batchIds, address[] calldata vaults)
        external
        nonReentrant
        returns (uint256 total)
    {
        if (msg.sender != keeper) revert NotKeeper(msg.sender);
        if (batchIds.length != vaults.length) revert LengthMismatch();
        for (uint256 i; i < batchIds.length; ++i) {
            total += _payVault(batchIds[i], vaults[i]);
        }
    }

    /// @notice Pays the caller what its part of each batch's borrower drip has unlocked.
    /// @param to Where the sGAGE goes.
    /// @return total The sGAGE paid in all.
    function claim(uint256[] calldata batchIds, address to) external nonReentrant returns (uint256 total) {
        if (to == address(0)) revert ZeroAddress();
        for (uint256 i; i < batchIds.length; ++i) {
            uint256 batchId = batchIds[i];
            Batch storage b = _batch(batchId);
            uint256 amount = _owed(
                DRIP.unlocked(address(this), b.borrowerDrip),
                borrowerShare[batchId][msg.sender],
                borrowerPaid[batchId][msg.sender]
            );
            if (amount == 0) continue;
            if (DRIP.claimable(address(this), b.borrowerDrip) != 0) DRIP.claim(b.borrowerDrip);
            borrowerPaid[batchId][msg.sender] += amount;
            total += amount;
            emit BorrowerClaimed(batchId, msg.sender, to, amount);
        }
        if (total != 0) SGAGE.safeTransfer(to, total);
    }

    // ----------------------------------------------------------------- owner

    /// @notice Names the caller of `mirror`.
    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice Sends every held USDG to `FEE_ROUTER`, the floor's fee route, without rewards: for a V1 that takes no
    ///         deals, so the fees still reach the floor.
    /// @return amount The USDG sent.
    function sendToFloor() external onlyOwner nonReentrant returns (uint256 amount) {
        amount = USDG.balanceOf(address(this));
        USDG.safeTransfer(FEE_ROUTER, amount);
        emit SentToFloor(FEE_ROUTER, amount);
    }

    // ----------------------------------------------------------------- views

    /// @notice USDG waiting to be mirrored. A fee processor checks this and `USDG` before it forwards here.
    function availableUSDG() external view returns (uint256) {
        return USDG.balanceOf(address(this));
    }

    /// @notice The most `mirror` would spend now on loans whose origination fees sum to `weight`: `MAX_SHARE_BPS` of
    ///         their share, by origination fee among every loan mirrored and them, of every USDG mirrored or held, and
    ///         never more than the bridge holds. The deals' fees may round below it.
    /// @param weight The named loans' origination fees, summed.
    function mirrorBudget(uint256 weight) external view returns (uint256) {
        return _budget(USDG.balanceOf(address(this)), weight);
    }

    function getBatch(uint256 batchId) external view returns (Batch memory) {
        return _batch(batchId);
    }

    /// @notice What `payVault` would pay now.
    function vaultOwed(uint256 batchId, address vault) external view returns (uint256) {
        Batch storage b = _batch(batchId);
        return
            _owed(DRIP.unlocked(address(LENDER), b.lenderDrip), vaultShare[batchId][vault], vaultPaid[batchId][vault]);
    }

    /// @notice What `claim` would pay `borrower` for one batch now.
    function borrowerOwed(uint256 batchId, address borrower) external view returns (uint256) {
        Batch storage b = _batch(batchId);
        return _owed(
            DRIP.unlocked(address(this), b.borrowerDrip),
            borrowerShare[batchId][borrower],
            borrowerPaid[batchId][borrower]
        );
    }

    // ----------------------------------------------------------------- internal

    /// @dev The receipt moves only to the V1 vault and back.
    function _update(address from, address to, uint256 value) internal override {
        if (
            from != address(0)
                && !((from == address(this) && to == address(VAULT)) || (from == address(VAULT) && to == address(this)))
        ) revert ReceiptLocked(from, to);
        super._update(from, to, value);
    }

    function _read(uint256 loanId) internal view returns (Named memory m) {
        V2Loan memory l = CORE.getLoan(loanId);
        if (l.state != V2State.ACTIVE && l.state != V2State.REPAID && l.state != V2State.DEFAULTED) {
            revert LoanNotActivated(loanId);
        }
        if (l.originationFee == 0) revert LoanWithoutFee(loanId);
        if (l.borrowerReward != 0 || l.lenderReward != 0) revert LoanRewardedByCore(loanId);
        uint256 prior = mirroredIn[loanId];
        if (prior != 0) revert LoanAlreadyMirrored(loanId, prior);
        GageV2Rewards.Allocation memory a = CORE_REWARDS.allocation(loanId);
        for (uint256 q; q < 4; ++q) {
            if (a.lenders[q] == address(0)) revert LoanWithoutLender(loanId);
        }
        m.term = l.term;
        m.weight = l.originationFee;
        m.borrower = a.borrower;
        m.lenders = a.lenders;
    }

    /// @dev Lists, funds, registers and repays one mirror deal on a flash loan; the bridge pays its fee and never more.
    ///      USDG anyone sent to `LENDER` comes back with the repaid cap and stays here, like USDG sent to the bridge,
    ///      as fees for later calls (LB-01): an exact spend let one raw unit stop every mirror for good.
    function _open(uint32 term, uint256 fee) internal returns (uint256 dealId, uint256 dealFee) {
        uint256 bps = REGISTRY.feeBps();
        if (bps == 0) revert ZeroFee(term);
        uint256 principal = (fee * BPS) / bps;
        dealFee = (principal * bps) / BPS;
        if (dealFee == 0) revert ZeroFee(term);
        uint256 before = USDG.balanceOf(address(this));
        _flashing = true;
        MORPHO.flashLoan(address(USDG), principal, abi.encode(term));
        dealId = _flashDeal;
        if (_flashing || USDG.balanceOf(address(this)) + dealFee < before || balanceOf(address(this)) != 1) {
            revert CycleMismatch(dealId);
        }
    }

    function _record(uint256 batchId, uint256 dealId, uint256 dealFee, uint32 term) internal returns (uint256 reward) {
        (uint128 total, uint128 lenderReward, uint128 borrowerReward) = REWARDS.rewardOf(dealId);
        Batch storage b = _batches[batchId];
        b.dealId = dealId;
        b.lenderDrip = REWARDS.dripIdOf(dealId, address(LENDER));
        b.borrowerDrip = REWARDS.dripIdOf(dealId, address(this));
        b.lenderReward = lenderReward;
        b.borrowerReward = borrowerReward;
        b.fee = SafeCast.toUint128(dealFee);
        b.term = term;
        reward = total;
    }

    /// @dev Each loan of the group takes its origination fee's part; its lender part goes to its quarters' vaults.
    function _assign(uint256 batchId, uint256 group, uint256 groupWeight, Named[] memory loans, uint256[] calldata ids)
        internal
    {
        uint16 count;
        for (uint256 i; i < loans.length; ++i) {
            Named memory m = loans[i];
            if (m.group != group) continue;
            uint256 wad = Math.mulDiv(m.weight, WAD, groupWeight);
            borrowerShare[batchId][m.borrower] += wad;
            for (uint8 q; q < 4; ++q) {
                vaultShare[batchId][m.lenders[q]] += unitSlice(wad, q);
            }
            emit LoanMirrored(batchId, ids[i], m.borrower, m.weight);
            ++count;
        }
        Batch storage b = _batches[batchId];
        b.loans = count;
        emit Mirrored(batchId, b.dealId, b.term, b.fee, b.lenderReward, b.borrowerReward, count);
    }

    function _payVault(uint256 batchId, address vault) internal returns (uint256 amount) {
        Batch storage b = _batch(batchId);
        amount =
            _owed(DRIP.unlocked(address(LENDER), b.lenderDrip), vaultShare[batchId][vault], vaultPaid[batchId][vault]);
        if (amount == 0 || ILendRewardsVault(vault).totalSupply() == 0) return 0;
        if (DRIP.claimable(address(LENDER), b.lenderDrip) != 0) LENDER.claim(b.lenderDrip);
        vaultPaid[batchId][vault] += amount;
        SGAGE.safeTransfer(vault, amount);
        // indexing now keeps a later deposit from sharing it; failing that, the vault indexes at its next share change
        try ILendRewardsVault(vault).harvestRewards(new uint256[](0)) {} catch {}
        emit VaultPaid(batchId, vault, amount);
    }

    function _batch(uint256 batchId) internal view returns (Batch storage b) {
        b = _batches[batchId];
        if (b.dealId == 0) revert UnknownBatch(batchId);
    }

    function _owed(uint256 unlocked, uint256 share, uint256 paid) internal pure returns (uint256) {
        uint256 due = Math.mulDiv(unlocked, share, WAD);
        return due > paid ? due - paid : 0;
    }

    /// @dev `mirrorBudget` for `held` USDG. Before any loan is mirrored it is everything held: the call's loans are then
    ///      every loan weighed.
    function _budget(uint256 held, uint256 weight) internal view returns (uint256) {
        if (weight == 0) return 0;
        uint256 share =
            Math.mulDiv(usdgMirrored + held, weight * MAX_SHARE_BPS, (originationFeesMirrored + weight) * BPS);
        return Math.min(held, share);
    }
}

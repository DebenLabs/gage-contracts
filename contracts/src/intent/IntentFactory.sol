// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IntentVault} from "./IntentVault.sol";
import {IntentCategory} from "./IntentVaultState.sol";
import {GageV2Vault} from "../v2/GageV2Vault.sol";
import {IIntentFeeProcessor} from "../interfaces/IIntentFeeProcessor.sol";

/// @notice Creation of token-collateral Intent mandates, version 12 (the version 9 mandate, D51's earnings claims, on the
/// r2 interface, D52, with risk limits that tighten at once and loosen after three hours, D53, and a name for every
/// vault, D54): admitted partners, or any address once the owner opens creation.
/// @dev Isolated from legacy EarnFactory. Creation code is fixed at deployment; no public fill switch.
/// Router and signer start at zero. Deployment must retain that gate until S2-S4 validation is complete. The first
/// router named is bound for good: fills can be closed and reopened with it, never handed to another router.
/// The strategy's creation code is read from two data contracts the deployment script writes (S9-01): embedded here
/// it would take this factory's own creation code past EIP-3860. Its hash is computed at construction and published
/// as `VAULT_INIT_HASH`, which the release check compares with the audited build.
contract IntentFactory is Ownable2Step {
    uint256 public constant MANDATE_VERSION = 12;
    /// @notice The longest vault name, in bytes of UTF-8; every vault has a name of at least one byte (D54).
    uint256 public constant MAX_NAME_BYTES = 48;
    // The fee band (500-1500 bps) and the outer bound of a vault's `executionCapBps`
    // (`IntentFeeMath.MAX_EXECUTION_CAP_BPS`) are the vault's own checks; the ceiling inside the bound is each
    // manager's choice (D32), and the factory sets none.

    struct Params {
        address core;
        address reserve;
        /// @dev Zero when the reserve's `maxWithdraw` measures what it can pay; otherwise the lens that does.
        address reserveLens;
        address grades;
        address protocolRecipient;
        address initialOwner;
        /// @dev The two data contracts holding the strategy creation code this factory deploys, in order: each is a
        /// leading STOP followed by one part of the code (the SSTORE2 layout), written by the deployment script.
        address codeA;
        address codeB;
    }

    address public immutable CORE;
    address public immutable RESERVE;
    /// @notice How every strategy measures the reserve's liquidity; fixed with the reserve, zero for its own views.
    address public immutable RESERVE_LENS;
    /// @notice The grade registry every strategy with a minimum grade reads.
    address public immutable GRADES;
    /// @notice Share of every strategy's fee on interest that the protocol recipient receives, fixed for all instances.
    uint16 public constant PROTOCOL_SHARE_BPS = 1000;
    /// @notice keccak256 of the strategy creation code every vault is deployed from, read from its data contracts.
    bytes32 public immutable VAULT_INIT_HASH;
    address internal immutable _CODE_A;
    address internal immutable _CODE_B;

    address public protocolRecipient;
    mapping(address => bool) public isCreator;
    /// @notice When true any address may create a vault it manages; `isCreator` still admits while it is false.
    bool public openCreation;
    address[] private _vaults;
    /// @notice Whether an address was created by this factory. Its creator is its curator (`VaultCreated`).
    mapping(address => bool) public isVault;
    /// @notice The only contract strategies accept funding from; zero closes the filler path.
    address public fillRouter;
    /// @notice The first fill router this factory named, bound for good; zero until then. `fillRouter` is only ever this
    /// router or zero: the vaults, their markets and the quote verifier all trust it, so a replacement could fund or buy
    /// without a signed plan or a sale (Pashov L-02, L-03, L-05). Another router takes a new generation.
    address public boundFillRouter;
    /// @notice The key whose signed quotes the fill router accepts; zero refuses every routed fill.
    address public quoteSigner;
    /// @notice Explicit filler admission, independent of partner creation and curator identity.
    mapping(address => bool) public isFiller;
    /// @notice Each vault's name: chosen by its manager at creation, changed by its manager since (D54). Display text
    /// only; nothing on chain reads it.
    mapping(address => string) public nameOf;

    struct Classification {
        bool classified;
        IntentCategory category;
    }
    mapping(address => Classification) public categoryOf;

    event VaultCreated(address indexed vault, address indexed curator, address creator, uint256 index);
    /// @notice The helpers a new vault created for itself, named so an indexer can follow their own events (S9).
    event VaultHelpers(address indexed vault, address assetPolicy, address lenderMarket);
    event ProtocolRecipientSet(address indexed recipient);
    event CreatorSet(address indexed creator, bool allowed);
    event OpenCreationSet(bool open);
    event FillRouterSet(address indexed router);
    event QuoteSignerSet(address indexed signer);
    event FillerSet(address indexed filler, bool allowed);
    event CategoryAssigned(address indexed token, IntentCategory category);
    event VaultNamed(address indexed vault, string name);

    error InvalidConfiguration();
    /// @notice The protocol recipient is not a fee processor of the core's USDG: fees paid there could be stranded.
    error NotAFeeProcessor();
    error CreationClosed();
    error VaultCreationFailed();
    /// @notice Empty, or longer than `MAX_NAME_BYTES`.
    error InvalidName();
    /// @notice Only a vault's own manager may rename it.
    error NotManager();
    /// @notice A fill router is bound already and this is another: only zero, which closes fills, or the bound router.
    error FillRouterBound();

    constructor(Params memory p) Ownable(p.initialOwner) {
        if (
            p.core.code.length == 0 || p.reserve.code.length == 0 || p.grades.code.length == 0
                || (p.reserveLens != address(0) && p.reserveLens.code.length == 0)
        ) revert InvalidConfiguration();
        _requireFeeProcessor(p.core, p.protocolRecipient);
        CORE = p.core;
        RESERVE = p.reserve;
        RESERVE_LENS = p.reserveLens;
        GRADES = p.grades;
        if (p.codeA.code.length < 2 || p.codeB.code.length < 2) revert InvalidConfiguration();
        _CODE_A = p.codeA;
        _CODE_B = p.codeB;
        VAULT_INIT_HASH = keccak256(_read(p.codeA, p.codeB));
        protocolRecipient = p.protocolRecipient;
        emit ProtocolRecipientSet(p.protocolRecipient);
    }

    /// @notice Deploy a strategy from a mandate and record it under `name`. A rejected mandate or name reverts the
    /// whole call. With `secondaryEnabled` false (and `secondaryExtraBps` zero) the vault does not buy existing positions
    /// until its curator turns that on; with it true, the vault buys existing lender positions from the start, asking
    /// `secondaryExtraBps` a year above the model's requirement (S9). Chosen before any deposit, the policy applies at
    /// once.
    function create(
        IntentVault.Mandate calldata mandate,
        bool secondaryEnabled,
        uint16 secondaryExtraBps,
        string calldata name
    ) external returns (address vault) {
        if ((!openCreation && !isCreator[msg.sender]) || mandate.curator != msg.sender) {
            revert CreationClosed();
        }
        // The vault reads this factory's core, reserve, lens and grades from its deployer.
        bytes memory init =
            abi.encodePacked(_read(_CODE_A, _CODE_B), abi.encode(mandate, secondaryEnabled, secondaryExtraBps));
        assembly ("memory-safe") {
            vault := create(0, add(init, 0x20), mload(init))
        }
        if (vault == address(0)) revert VaultCreationFailed();
        isVault[vault] = true;
        emit VaultCreated(vault, mandate.curator, msg.sender, _vaults.length);
        emit VaultHelpers(
            vault, address(IntentVault(vault).ASSET_POLICY()), address(IntentVault(vault).LENDER_MARKET())
        );
        _vaults.push(vault);
        _name(vault, name);
    }

    /// @notice Rename a vault. Its manager only; the name is display text and changes nothing else.
    function setName(address vault, string calldata name) external {
        if (!isVault[vault] || IntentVault(vault).CURATOR() != msg.sender) revert NotManager();
        _name(vault, name);
    }

    /// @notice Open creation to every address, or close it again to the admitted creators. Vaults created while it was
    /// open stay listed and serviced; whoever creates a vault is always its manager.
    function setOpenCreation(bool open) external onlyOwner {
        openCreation = open;
        emit OpenCreationSet(open);
    }

    /// @notice Creation permission only. Removal preserves discovery, withdrawals and servicing.
    function setCreator(address creator, bool allowed) external onlyOwner {
        if (creator == address(0)) revert InvalidConfiguration();
        isCreator[creator] = allowed;
        emit CreatorSet(creator, allowed);
    }

    /// @notice Classify an already admitted token once. Existing mandates cannot be broadened by relabelling.
    function assignCategory(address token, IntentCategory category) external onlyOwner {
        if (categoryOf[token].classified || !GageV2Vault(CORE).REGISTRY().getERC20Config(token).allowed) {
            revert InvalidConfiguration();
        }
        categoryOf[token] = Classification(true, category);
        emit CategoryAssigned(token, category);
    }

    /// @notice Admission and category are checked together against the existing protocol registry.
    /// Returns 255 when the token is disabled, unclassified or outside the supplied immutable mask.
    function eligibleCategory(address token, uint8 mask) external view returns (uint8) {
        Classification memory c = categoryOf[token];
        if (
            !c.classified || (mask & uint8(1 << uint8(c.category))) == 0
                || !GageV2Vault(CORE).REGISTRY().getERC20Config(token).allowed
        ) return type(uint8).max;
        return uint8(c.category);
    }

    /// @notice Where every strategy pays the protocol's fee share from now on, including the ones already created.
    /// @dev The recipient must be a fee processor of the core's USDG (see `IIntentFeeProcessor`). It is owed every
    /// execution fee too: V1's fill router has no filler share and no filler payout (D49).
    function setProtocolRecipient(address recipient) external onlyOwner {
        _requireFeeProcessor(CORE, recipient);
        protocolRecipient = recipient;
        emit ProtocolRecipientSet(recipient);
    }

    /// @notice Name the contract that fills on fillers' behalf; zero closes the path for every strategy at once.
    /// @dev The first router named is bound for good (`boundFillRouter`, the first non-zero `FillRouterSet`): from then
    /// on the owner may only close fills (zero) and reopen them with that router; any other reverts `FillRouterBound`.
    /// Closing before the first naming binds nothing.
    function setFillRouter(address router) external onlyOwner {
        if (router != address(0)) {
            if (router.code.length == 0) revert InvalidConfiguration();
            address bound = boundFillRouter;
            if (bound == address(0)) boundFillRouter = router;
            else if (router != bound) revert FillRouterBound();
        }
        fillRouter = router;
        emit FillRouterSet(router);
    }

    /// @notice Name the key that signs quotes; zero stops every routed fill until a new key is set.
    function setQuoteSigner(address signer) external onlyOwner {
        quoteSigner = signer;
        emit QuoteSignerSet(signer);
    }

    /// @notice Filler admission only; no execution-fee share or payout is chosen here (D49).
    function setFiller(address filler, bool allowed) external onlyOwner {
        if (filler == address(0)) revert InvalidConfiguration();
        isFiller[filler] = allowed;
        emit FillerSet(filler, allowed);
    }

    /// @notice Number of strategies created here.
    function count() external view returns (uint256) {
        return _vaults.length;
    }

    /// @notice Strategy address by creation index.
    function vaults(uint256 index) external view returns (address) {
        return _vaults[index];
    }

    function _name(address vault, string calldata name) private {
        uint256 length = bytes(name).length;
        if (length == 0 || length > MAX_NAME_BYTES) revert InvalidName();
        nameOf[vault] = name;
        emit VaultNamed(vault, name);
    }

    /// @dev The exact strategy creation code: two SSTORE2 chunks, each behind a leading STOP, joined. Its hash is
    /// `VAULT_INIT_HASH`; the chunks themselves are readable at their own addresses.
    function _read(address a, address b) internal view returns (bytes memory code) {
        uint256 split = a.code.length - 1;
        uint256 total = split + b.code.length - 1;
        code = new bytes(total);
        assembly ("memory-safe") {
            extcodecopy(a, add(code, 0x20), 1, split)
            extcodecopy(b, add(add(code, 0x20), split), 1, sub(total, split))
        }
    }

    /// @dev A contract that names the core's USDG and reports a processable USDG balance. Anything that cannot answer
    /// both, a wallet and the zero address included, is refused: the protocol's share of every fee, the performance
    /// share every strategy pays and stale execution fees are all sent to this one address as plain USDG. A wallet,
    /// the zero address and a processor of another USDG are refused with `NotAFeeProcessor`; a contract missing either
    /// view (or whose view reverts) is refused by that call's own revert, empty for a contract without the function.
    function _requireFeeProcessor(address core_, address recipient) private view {
        if (recipient.code.length == 0) revert NotAFeeProcessor();
        if (IIntentFeeProcessor(recipient).USDG() != address(GageV2Vault(core_).USDG())) revert NotAFeeProcessor();
        // forge-lint: disable-next-line(unused-return)
        IIntentFeeProcessor(recipient).availableUSDG();
    }
}

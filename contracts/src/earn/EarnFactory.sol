// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EarnVault} from "./EarnVault.sol";

/// @notice Creates isolated Earn strategies in one transaction, each with its own curator and mandate.
/// @dev Every strategy shares the factory's core, reserve and protocol recipient. Creation costs nothing beyond
/// gas and is closed to everyone but the owner until public creation is switched on. The strategy's creation
/// code is stored on chain when the factory is deployed and replayed for every instance, so what a strategy
/// runs is fixed by `VAULT_INIT_HASH` and no later change to the factory or its owner can alter it.
/// @dev The factory also names the one path a filler takes into a strategy: the fill router, who may fill through
/// it and which key signs the quotes it checks. Every strategy reads these here, so the owner moves them for all
/// strategies at once; a strategy's curator may still close fillers out of its own mandate.
contract EarnFactory is Ownable2Step {
    struct Params {
        address core;
        address reserve;
        address grades;
        address protocolRecipient;
        uint16 protocolShareBps;
        address initialOwner;
    }

    address public immutable CORE;
    address public immutable RESERVE;
    /// @notice The grade registry every strategy with a minimum grade reads.
    address public immutable GRADES;
    /// @notice Share of every strategy's fee on interest that the protocol recipient receives, fixed for all instances.
    uint16 public immutable PROTOCOL_SHARE_BPS;
    /// @notice keccak256 of the strategy creation code every vault is deployed from.
    bytes32 public immutable VAULT_INIT_HASH;
    address internal immutable _CODE_A;
    address internal immutable _CODE_B;
    uint256 internal immutable _CODE_SPLIT;

    address public protocolRecipient;
    bool public publicCreation;
    address[] private _vaults;
    mapping(address => address) public creatorOf;
    /// @notice The contract every strategy accepts `fund` from besides its curator; zero closes the filler path.
    address public fillRouter;
    /// @notice The key whose signed quotes the fill router accepts; zero refuses every non-curator fill.
    address public quoteSigner;
    /// @notice Whether any account may fill through the router, or only the allowlisted fillers.
    bool public publicFill;
    mapping(address => bool) public isFiller;

    event VaultCreated(address indexed vault, address indexed curator, address creator, uint256 index);
    event ProtocolRecipientSet(address indexed recipient);
    event PublicCreationSet(bool enabled);
    event FillRouterSet(address indexed router);
    event QuoteSignerSet(address indexed signer);
    event PublicFillSet(bool enabled);
    event FillerSet(address indexed filler, bool allowed);

    error InvalidConfiguration();
    error CreationClosed();
    error VaultCreationFailed();

    constructor(Params memory p) Ownable(p.initialOwner) {
        if (
            p.core.code.length == 0 || p.reserve.code.length == 0 || p.grades.code.length == 0
                || p.protocolShareBps > 10_000
        ) {
            revert InvalidConfiguration();
        }
        if (p.protocolShareBps != 0 && p.protocolRecipient == address(0)) revert InvalidConfiguration();
        CORE = p.core;
        RESERVE = p.reserve;
        GRADES = p.grades;
        PROTOCOL_SHARE_BPS = p.protocolShareBps;
        bytes memory code = type(EarnVault).creationCode;
        VAULT_INIT_HASH = keccak256(code);
        uint256 split = code.length / 2;
        _CODE_SPLIT = split;
        _CODE_A = _store(code, 0, split);
        _CODE_B = _store(code, split, code.length - split);
        protocolRecipient = p.protocolRecipient;
        emit ProtocolRecipientSet(p.protocolRecipient);
    }

    /// @notice Deploy a strategy from a mandate and record it. A rejected mandate reverts the whole call.
    function create(EarnVault.Mandate calldata mandate) external returns (address vault) {
        if (!publicCreation && msg.sender != owner()) revert CreationClosed();
        EarnVault.Params memory p = EarnVault.Params({
            core: CORE,
            reserve: RESERVE,
            grades: GRADES,
            protocolSource: address(this),
            protocolShareBps: PROTOCOL_SHARE_BPS,
            mandate: mandate
        });
        bytes memory init = abi.encodePacked(vaultCreationCode(), abi.encode(p));
        assembly ("memory-safe") {
            vault := create(0, add(init, 0x20), mload(init))
        }
        if (vault == address(0)) revert VaultCreationFailed();
        creatorOf[vault] = msg.sender;
        emit VaultCreated(vault, mandate.curator, msg.sender, _vaults.length);
        _vaults.push(vault);
    }

    /// @notice Open or close creation to accounts other than the owner.
    function setPublicCreation(bool enabled) external onlyOwner {
        publicCreation = enabled;
        emit PublicCreationSet(enabled);
    }

    /// @notice Where every strategy pays the protocol's fee share from now on, including the ones already created.
    function setProtocolRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert InvalidConfiguration();
        protocolRecipient = recipient;
        emit ProtocolRecipientSet(recipient);
    }

    /// @notice Name the contract that fills on fillers' behalf; zero closes the path for every strategy at once.
    function setFillRouter(address router) external onlyOwner {
        if (router != address(0) && router.code.length == 0) revert InvalidConfiguration();
        fillRouter = router;
        emit FillRouterSet(router);
    }

    /// @notice Name the key that signs quotes; zero stops every non-curator fill until a new key is set.
    function setQuoteSigner(address signer) external onlyOwner {
        quoteSigner = signer;
        emit QuoteSignerSet(signer);
    }

    /// @notice Open filling to any account, or keep it to the allowlist.
    function setPublicFill(bool enabled) external onlyOwner {
        publicFill = enabled;
        emit PublicFillSet(enabled);
    }

    /// @notice Allow or remove one filler; removal leaves its open loans to run to settlement.
    function setFiller(address filler, bool allowed) external onlyOwner {
        if (filler == address(0)) revert InvalidConfiguration();
        isFiller[filler] = allowed;
        emit FillerSet(filler, allowed);
    }

    /// @notice Whether an account may fill through the router now.
    function canFill(address filler) external view returns (bool) {
        return publicFill || isFiller[filler];
    }

    /// @notice Number of strategies created here.
    function count() external view returns (uint256) {
        return _vaults.length;
    }

    /// @notice Strategy address by creation index.
    function vaults(uint256 index) external view returns (address) {
        return _vaults[index];
    }

    /// @notice Whether an address was created by this factory.
    function isVault(address vault) external view returns (bool) {
        return creatorOf[vault] != address(0);
    }

    /// @notice The exact strategy creation code, reassembled from its on-chain store.
    function vaultCreationCode() public view returns (bytes memory code) {
        uint256 total = _CODE_A.code.length - 1 + _CODE_B.code.length - 1;
        code = new bytes(total);
        address a = _CODE_A;
        address b = _CODE_B;
        uint256 split = _CODE_SPLIT;
        assembly ("memory-safe") {
            extcodecopy(a, add(code, 0x20), 1, split)
            extcodecopy(b, add(add(code, 0x20), split), 1, sub(total, split))
        }
    }

    /// @dev Store one chunk as the runtime of a data contract behind a leading STOP, the SSTORE2 pattern.
    function _store(bytes memory code, uint256 offset, uint256 length) internal returns (address pointer) {
        bytes memory init = new bytes(12 + length);
        assembly ("memory-safe") {
            // PUSH1 0x0B, MSIZE, DUP2, CODESIZE, SUB, DUP1, SWAP3, MSIZE, CODECOPY, RETURN, then STOP + data.
            mstore(add(init, 0x20), 0x600b5981380380925939f3000000000000000000000000000000000000000000)
            mcopy(add(init, 0x2c), add(add(code, 0x20), offset), length)
            pointer := create(0, add(init, 0x20), mload(init))
        }
        if (pointer == address(0)) revert InvalidConfiguration();
    }
}

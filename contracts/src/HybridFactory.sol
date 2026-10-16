// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {HybridVault} from "./HybridVault.sol";
import {HybridFees} from "./HybridFees.sol";

/// @notice Creates isolated Earn strategies from one pinned strategy implementation, each with its own curator.
/// @dev Every vault shares the factory's core and reserve; the creator chooses the curator and the mandate, whose
/// limits are immutable but for the deposit cap the curator may move afterwards (D83).
/// The strategy's creation code is stored on chain at deployment and replayed for every instance, so no later
/// change to the factory or its owner can alter what an existing or future vault runs. Creation itself is free; the
/// fee router only receives each strategy's protocol share of performance fees (D57, D80, D82). Featured status is
/// product metadata.
contract HybridFactory is Ownable2Step, ReentrancyGuardTransient {
    struct Params {
        address core;
        address reserve;
        address feeRouter;
        uint16 protocolShareBps;
        address initialOwner;
    }

    /// @notice What a creator decides; everything else comes from the factory. Only `maxTotalDeposits` moves later.
    struct Mandate {
        address curator;
        uint16[3] laneWeights;
        uint32 maxLoanTerm;
        uint16 minReturnBps;
        uint16 maxGageExposureBps;
        uint128 minDeposit;
        uint128 maxTotalDeposits;
    }

    struct Record {
        address fees;
        address curator;
        address creator;
        uint64 createdAt;
    }

    address public immutable CORE;
    address public immutable RESERVE;
    /// @notice Share of every strategy's performance fee that its floor route receives, fixed for all instances.
    uint16 public immutable PROTOCOL_SHARE_BPS;
    /// @notice keccak256 of the strategy creation code every vault is deployed from.
    bytes32 public immutable VAULT_INIT_HASH;
    address internal immutable _CODE_A;
    address internal immutable _CODE_B;
    uint256 internal immutable _CODE_SPLIT;

    address public feeRouter;
    bool public publicCreation;
    mapping(address => Record) public records;
    address[] private _vaults;

    event VaultCreated(address indexed vault, address indexed fees, address indexed curator, address creator);
    event FeeRouterSet(address indexed router);
    event PublicCreationSet(bool enabled);

    error InvalidConfiguration();
    error CreationClosed();
    error VaultCreationFailed();

    constructor(Params memory p) Ownable(p.initialOwner) {
        if (p.core.code.length == 0 || p.reserve.code.length == 0 || p.feeRouter.code.length == 0) {
            revert InvalidConfiguration();
        }
        if (p.protocolShareBps > 10_000) revert InvalidConfiguration();
        PROTOCOL_SHARE_BPS = p.protocolShareBps;
        CORE = p.core;
        RESERVE = p.reserve;
        bytes memory code = type(HybridVault).creationCode;
        VAULT_INIT_HASH = keccak256(code);
        uint256 split = code.length / 2;
        _CODE_SPLIT = split;
        _CODE_A = _store(code, 0, split);
        _CODE_B = _store(code, split, code.length - split);
        feeRouter = p.feeRouter;
        emit FeeRouterSet(p.feeRouter);
    }

    /// @notice Deploy a strategy with its fee companion, wire it, and record the instance.
    /// @dev Closed to everyone but the owner until public creation is switched on. A rejected mandate reverts the
    /// whole call, so nothing is recorded.
    function create(Mandate calldata m) external nonReentrant returns (address vault, address feeCompanion) {
        if (!publicCreation && msg.sender != owner()) revert CreationClosed();
        HybridVault.Params memory p = HybridVault.Params({
            core: CORE,
            reserve: RESERVE,
            laneWeights: m.laneWeights,
            curator: m.curator,
            maxLoanTerm: m.maxLoanTerm,
            minReturnBps: m.minReturnBps,
            maxGageExposureBps: m.maxGageExposureBps,
            minDeposit: m.minDeposit,
            maxTotalDeposits: m.maxTotalDeposits
        });
        bytes memory init = abi.encodePacked(vaultCreationCode(), abi.encode(p));
        assembly ("memory-safe") {
            vault := create(0, add(init, 0x20), mload(init))
        }
        if (vault == address(0)) revert VaultCreationFailed();
        feeCompanion = address(new HybridFees(vault, PROTOCOL_SHARE_BPS, feeRouter, m.curator));
        HybridVault(payable(vault)).setFees(feeCompanion);
        records[vault] =
            Record({fees: feeCompanion, curator: m.curator, creator: msg.sender, createdAt: uint64(block.timestamp)});
        _vaults.push(vault);
        emit VaultCreated(vault, feeCompanion, m.curator, msg.sender);
    }

    /// @notice Open or close creation to accounts other than the owner.
    function setPublicCreation(bool enabled) external onlyOwner {
        publicCreation = enabled;
        emit PublicCreationSet(enabled);
    }

    /// @notice Point later strategies' protocol fee share at a redeployed floor route; existing companions keep theirs.
    function setFeeRouter(address router) external onlyOwner {
        if (router.code.length == 0) revert InvalidConfiguration();
        feeRouter = router;
        emit FeeRouterSet(router);
    }

    /// @notice Number of vaults created here.
    function count() external view returns (uint256) {
        return _vaults.length;
    }

    /// @notice Vault address by creation index.
    function vaults(uint256 index) external view returns (address) {
        return _vaults[index];
    }

    /// @notice Whether an address was created by this factory.
    function isVault(address vault) external view returns (bool) {
        return records[vault].fees != address(0);
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

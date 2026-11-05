// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LPRegistry} from "./LPRegistry.sol";
import {PoolRef} from "./LPTypes.sol";

/// @title LPVaultFactory
/// @notice Lets a curator the registry's owner allowed (or anyone, once the owner opens creation) open an LP vault in
/// one transaction: the vault lends this factory's USDG through its core, is curated by its creator, and funds loans in
/// the pools of its mandate only. The registry treats the factory's vaults as allowed until its owner removes one. No
/// owner, no fee.
/// @dev An `LPVault`'s creation code is larger than a contract may hold, so it is read from two data contracts (SSTORE2
/// chunks, each behind a leading STOP), as `IntentFactory` does; `VAULT_INIT_HASH` publishes what they hold.
contract LPVaultFactory {
    /// @notice Longest vault name, in bytes.
    uint256 public constant MAX_NAME_BYTES = 64;

    LPRegistry public immutable REGISTRY;
    IERC20 public immutable USDG;
    address public immutable CORE;
    /// @notice keccak256 of the vault creation code this factory deploys (without its constructor arguments).
    bytes32 public immutable VAULT_INIT_HASH;
    /// @notice The data contracts holding the vault creation code's first and second halves.
    address public immutable CODE_A;
    address public immutable CODE_B;

    /// @notice Whether this factory created `vault`.
    mapping(address vault => bool) public isVault;
    /// @notice The name `vault` was created with.
    mapping(address vault => string) public nameOf;
    address[] internal _vaults;

    event VaultCreated(
        address indexed vault,
        address indexed curator,
        string name,
        uint16 performanceFeeBps,
        uint128 maxLoanPrincipal,
        PoolRef[] pools
    );

    error NotCurator(address caller);
    error InvalidName();
    error ZeroAddress();
    error InvalidCode();

    /// @notice A factory for vaults lending `usdg` through `core` under `registry`, whose creation code is the chunks
    /// stored at `codeA` then `codeB`.
    constructor(LPRegistry registry, IERC20 usdg, address core, address codeA, address codeB) {
        if (address(registry) == address(0) || address(usdg) == address(0) || core == address(0)) revert ZeroAddress();
        if (codeA.code.length < 2 || codeB.code.length < 2) revert InvalidCode();
        REGISTRY = registry;
        USDG = usdg;
        CORE = core;
        CODE_A = codeA;
        CODE_B = codeB;
        VAULT_INIT_HASH = keccak256(_read(codeA, codeB));
    }

    /// @notice Opens a vault curated by the caller, which must be an allowed curator unless creation is open, with its
    /// name, performance fee, largest loan and the pools it funds. A vault's own refusal (a fee out of bounds, an empty
    /// mandate) is passed on as it is.
    function create(string calldata name, uint16 performanceFeeBps, uint128 maxLoanPrincipal, PoolRef[] calldata pools)
        external
        returns (address vault)
    {
        if (!REGISTRY.mayOpenVault(msg.sender)) revert NotCurator(msg.sender);
        uint256 length = bytes(name).length;
        if (length == 0 || length > MAX_NAME_BYTES) revert InvalidName();
        bytes memory init = abi.encodePacked(
            _read(CODE_A, CODE_B),
            abi.encode(USDG, CORE, REGISTRY, msg.sender, performanceFeeBps, maxLoanPrincipal, pools, name)
        );
        assembly ("memory-safe") {
            vault := create(0, add(init, 0x20), mload(init))
            if iszero(vault) {
                let p := mload(0x40)
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
        }
        isVault[vault] = true;
        nameOf[vault] = name;
        _vaults.push(vault);
        emit VaultCreated(vault, msg.sender, name, performanceFeeBps, maxLoanPrincipal, pools);
    }

    /// @notice Every vault this factory created, oldest first. Unbounded: under open creation it can outgrow a node's
    /// call gas cap, so readers page with `vaultCount` and `vaultsFrom`.
    function vaults() external view returns (address[] memory) {
        return _vaults;
    }

    /// @notice How many vaults this factory created.
    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    /// @notice At most `count` vaults from index `start`, oldest first; fewer at the end of the list, none past it.
    function vaultsFrom(uint256 start, uint256 count) external view returns (address[] memory page) {
        uint256 n = _vaults.length;
        if (start >= n) return page;
        if (count > n - start) count = n - start;
        page = new address[](count);
        for (uint256 i; i < count; ++i) {
            page[i] = _vaults[start + i];
        }
    }

    /// @dev The vault creation code: the two chunks, each behind a leading STOP, joined.
    function _read(address a, address b) internal view returns (bytes memory code) {
        uint256 split = a.code.length - 1;
        uint256 total = split + b.code.length - 1;
        code = new bytes(total);
        assembly ("memory-safe") {
            extcodecopy(a, add(code, 0x20), 1, split)
            extcodecopy(b, add(add(code, 0x20), split), 1, sub(total, split))
        }
    }
}

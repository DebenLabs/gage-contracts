// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IRehypoVault} from "../interfaces/rehypo/IRehypoVault.sol";
import {IIntentFactoryRegistry} from "../interfaces/IIntentFactoryRegistry.sol";
import {GageRehypoSource} from "./GageRehypoSource.sol";

/// @title GageRehypoSourceFactory
/// @notice Creates rehypo sources in one call, so a partner's Safe sets up a pool's sources in the same batch as
/// its hook: no owner, no settings, open to anyone. Each source is the creator's to configure through its own owner.
/// @dev CREATE2 salted with the creator, so nobody can take another creator's address first. The source's creation code
/// lives in a data contract the constructor writes once (`SOURCE_CODE`, its runtime a zero byte then the code), so it
/// counts against that contract's EIP-170 limit rather than this factory's.
contract GageRehypoSourceFactory {
    /// @notice The Uniswap v4 PoolManager every source this factory creates holds its float in.
    IPoolManager public immutable POOL_MANAGER;
    /// @notice The generation deployer's record of the Intent factories whose vaults a source may lend through (2b).
    IIntentFactoryRegistry public immutable REGISTRY;
    /// @dev The data contract holding `GageRehypoSource`'s creation code after a leading zero byte.
    address internal immutable SOURCE_CODE;

    /// @notice Whether this factory created `source`.
    mapping(address source => bool created) public isSource;

    /// @notice A new source: its asset, its vault (zero for float-only), its owner and the creator.
    event SourceCreated(
        address indexed source,
        address indexed asset,
        address indexed vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        address creator
    );

    error InvalidConfiguration();
    error SourceCodeNotWritten();

    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param registry The generation deployer (`IIntentFactoryRegistry`).
    constructor(IPoolManager poolManager, IIntentFactoryRegistry registry) {
        if (address(poolManager).code.length == 0 || address(registry).code.length == 0) revert InvalidConfiguration();
        POOL_MANAGER = poolManager;
        REGISTRY = registry;
        // A data contract: an initcode that returns everything after its 12 bytes, a STOP byte then the source's code.
        bytes memory data = abi.encodePacked(hex"00", type(GageRehypoSource).creationCode);
        bytes memory init = abi.encodePacked(hex"61", uint16(data.length), hex"80600c6000396000f3", data);
        address code;
        assembly ("memory-safe") {
            code := create(0, add(init, 0x20), mload(init))
        }
        if (code == address(0)) revert SourceCodeNotWritten();
        SOURCE_CODE = code;
    }

    /// @notice Create a source for one pool token. The owner then binds the hook (`bind`) and names keepers.
    /// @param asset The pool token.
    /// @param vault A gage partner vault of `asset` from a recorded Intent factory, or zero for a float-only source.
    /// @param owner The source's owner: the partner's Safe.
    /// @param beneficiary Where the source's sGAGE and recovered collateral go.
    /// @param floatBps The float target, in basis points of the backing.
    /// @param salt The creator's salt.
    /// @return source The new source.
    function create(IERC20 asset, IRehypoVault vault, address owner, address beneficiary, uint16 floatBps, bytes32 salt)
        external
        returns (GageRehypoSource source)
    {
        bytes memory init = _initCode(asset, vault, owner, beneficiary, floatBps);
        bytes32 key = keccak256(abi.encode(msg.sender, salt));
        assembly ("memory-safe") {
            source := create2(0, add(init, 0x20), mload(init), key)
            if iszero(source) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
        isSource[address(source)] = true;
        emit SourceCreated(address(source), address(asset), address(vault), owner, beneficiary, floatBps, msg.sender);
    }

    /// @notice The address `create` gives `creator` for these arguments.
    function predict(
        address creator,
        IERC20 asset,
        IRehypoVault vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        bytes32 salt
    ) external view returns (address) {
        bytes32 initCodeHash = keccak256(_initCode(asset, vault, owner, beneficiary, floatBps));
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), keccak256(abi.encode(creator, salt)), initCodeHash)
        );
        return address(uint160(uint256(hash)));
    }

    /// @dev The source's creation code, read from `SOURCE_CODE`, followed by its constructor arguments.
    function _initCode(IERC20 asset, IRehypoVault vault, address owner, address beneficiary, uint16 floatBps)
        internal
        view
        returns (bytes memory)
    {
        (string memory name, string memory symbol) = _names(asset);
        address code = SOURCE_CODE;
        uint256 size = code.code.length - 1;
        bytes memory creation = new bytes(size);
        assembly ("memory-safe") {
            extcodecopy(code, add(creation, 0x20), 1, size)
        }
        return abi.encodePacked(
            creation, abi.encode(asset, vault, POOL_MANAGER, REGISTRY, owner, beneficiary, floatBps, name, symbol)
        );
    }

    /// @dev "gage rehypo source <SYMBOL>" and "grs<SYMBOL>".
    function _names(IERC20 asset) internal view returns (string memory name, string memory symbol) {
        string memory s = IERC20Metadata(address(asset)).symbol();
        return (string.concat("gage rehypo source ", s), string.concat("grs", s));
    }
}

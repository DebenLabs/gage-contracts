// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPrivacyPool} from "../../src/private/IPrivacyPools.sol";

/// @notice The Privacy Pools v1.3.0 Entrypoint as the router reads it: one pool per asset and the latest root.
contract MockPrivacyPoolsEntrypoint {
    mapping(address asset => address pool) internal _pools;
    uint256 public latestRoot;

    function register(address asset, address pool) external {
        _pools[asset] = pool;
    }

    function setRoot(uint256 root) external {
        latestRoot = root;
    }

    function assetConfig(address asset) external view returns (address, uint256, uint256, uint256) {
        return (_pools[asset], 0, 0, 0);
    }
}

/// @notice `PrivacyPool.withdraw` of v1.3.0 with its checks in the pool's order and the Groth16 verification left out:
///         the caller is the processooor, the context hashes the withdrawal with the scope, the ASP root is the
///         Entrypoint's latest, and the nullifier is unspent; then the withdrawn value goes to the processooor.
/// @dev `short` makes the pool push less than the proof's withdrawn value, as a taxed first leg would.
contract MockPrivacyPool {
    using SafeERC20 for IERC20;

    uint256 internal constant SNARK_SCALAR_FIELD =
        21_888_242_871_839_275_222_246_405_745_257_275_088_548_364_400_416_034_343_698_204_186_575_808_495_617;

    address public immutable ASSET;
    uint256 public immutable SCOPE;
    MockPrivacyPoolsEntrypoint public immutable ENTRYPOINT;
    mapping(uint256 nullifierHash => bool) public nullifierHashes;
    uint256 public short;

    error InvalidProcessooor();
    error ContextMismatch();
    error IncorrectASPRoot();
    error NullifierAlreadySpent();

    constructor(address asset, MockPrivacyPoolsEntrypoint entrypoint, uint256 scope) {
        ASSET = asset;
        ENTRYPOINT = entrypoint;
        SCOPE = scope;
    }

    function setShort(uint256 amount) external {
        short = amount;
    }

    /// @notice The context a proof for `withdrawal` must carry in this pool.
    function context(IPrivacyPool.Withdrawal memory withdrawal) public view returns (uint256) {
        return uint256(keccak256(abi.encode(withdrawal, SCOPE))) % SNARK_SCALAR_FIELD;
    }

    function withdraw(IPrivacyPool.Withdrawal memory withdrawal, IPrivacyPool.WithdrawProof memory proof) external {
        if (msg.sender != withdrawal.processooor) revert InvalidProcessooor();
        if (proof.pubSignals[7] != context(withdrawal)) revert ContextMismatch();
        if (proof.pubSignals[5] != ENTRYPOINT.latestRoot()) revert IncorrectASPRoot();
        if (nullifierHashes[proof.pubSignals[1]]) revert NullifierAlreadySpent();
        nullifierHashes[proof.pubSignals[1]] = true;
        IERC20(ASSET).safeTransfer(withdrawal.processooor, proof.pubSignals[2] - short);
    }
}

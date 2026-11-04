// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

/// @notice The rehypo source factory: create and predict a pool token's source. Generated from its build; not deployed yet.
/// @dev Generated from the build of `src/rehypo/GageRehypoSourceFactory.sol` at f19f3be0a21d.
interface IGageRehypoSourceFactory {
    error InvalidConfiguration();
    error SourceCodeNotWritten();

    event SourceCreated(
        address indexed source,
        address indexed asset,
        address indexed vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        address creator
    );

    function POOL_MANAGER() external view returns (address);
    function REGISTRY() external view returns (address);
    function create(address asset, address vault, address owner, address beneficiary, uint16 floatBps, bytes32 salt)
        external
        returns (address source);
    function isSource(address source) external view returns (bool created);
    function predict(
        address creator,
        address asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        bytes32 salt
    ) external view returns (address);
}

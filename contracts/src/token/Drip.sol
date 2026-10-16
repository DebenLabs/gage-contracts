// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IDrip} from "../interfaces/token/IDrip.sol";

/// @title Drip
/// @notice Locked sGAGE that unlocks on the quadratic curve (D48). Deal drips are keyed by (dealId, party) and run over the
///         deal's term; LP drips are keyed by tokenId and a collect nonce and run 7 days. No function releases
///         early or slows a drip; there is no owner (T3).
contract Drip is IDrip, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IERC20 public immutable SGAGE;
    address public immutable DEPLOYER;

    address public dealRewards;
    address public lpRewards;
    uint256 public totalLocked;
    mapping(address account => mapping(bytes32 dripId => DripAccount)) internal _drips;

    error NotDeployer();

    /// @param admin The account allowed to call `setGrantors` once (explicit: CREATE2 factories are `msg.sender`).
    constructor(IERC20 sgage, address admin) {
        if (address(sgage) == address(0) || admin == address(0)) revert ZeroAddress();
        SGAGE = sgage;
        DEPLOYER = admin;
    }

    /// @notice Deployer, once: the only two contracts that may open drips.
    function setGrantors(address dealRewards_, address lpRewards_) external {
        if (msg.sender != DEPLOYER) revert NotDeployer();
        if (dealRewards != address(0)) revert GrantorsAlreadySet();
        if (dealRewards_ == address(0) || lpRewards_ == address(0)) revert ZeroAddress();
        dealRewards = dealRewards_;
        lpRewards = lpRewards_;
        emit GrantorsSet(dealRewards_, lpRewards_);
    }

    /// @inheritdoc IDrip
    function grant(address account, bytes32 dripId, uint128 total, uint40 start, uint32 length) external nonReentrant {
        if (!isGrantor(msg.sender)) revert NotGrantor(msg.sender);
        if (account == address(0)) revert ZeroAddress();
        if (total == 0) revert ZeroAmount();
        if (length == 0) revert ZeroLength();
        DripAccount storage d = _drips[account][dripId];
        if (d.total != 0) revert DripExists(account, dripId);

        d.total = total;
        d.start = start;
        d.length = length;
        totalLocked += total;
        SGAGE.safeTransferFrom(msg.sender, address(this), total);
        emit Granted(account, dripId, total, start, length, msg.sender);
    }

    /// @inheritdoc IDrip
    function claim(bytes32 dripId) external nonReentrant returns (uint128 amount) {
        amount = _claim(msg.sender, dripId);
        if (amount == 0) revert NothingClaimable();
    }

    /// @inheritdoc IDrip
    function claimMany(bytes32[] calldata dripIds) external nonReentrant returns (uint128 amount) {
        for (uint256 i = 0; i < dripIds.length; ++i) {
            amount += _claim(msg.sender, dripIds[i]);
        }
        if (amount == 0) revert NothingClaimable();
    }

    // ----------------------------------------------------------------- views

    function unlocked(address account, bytes32 dripId) public view returns (uint128) {
        return _unlocked(_drips[account][dripId]);
    }

    function claimable(address account, bytes32 dripId) external view returns (uint128) {
        DripAccount storage d = _drips[account][dripId];
        return _unlocked(d) - d.claimed;
    }

    function getDrip(address account, bytes32 dripId) external view returns (DripAccount memory) {
        return _drips[account][dripId];
    }

    function isGrantor(address account) public view returns (bool) {
        return account != address(0) && (account == dealRewards || account == lpRewards);
    }

    // ----------------------------------------------------------------- internal

    function _claim(address account, bytes32 dripId) internal returns (uint128 amount) {
        DripAccount storage d = _drips[account][dripId];
        if (d.total == 0) revert NoDrip(account, dripId);
        uint128 u = _unlocked(d);
        amount = u - d.claimed;
        if (amount == 0) return 0;
        d.claimed = u;
        totalLocked -= amount;
        SGAGE.safeTransfer(account, amount);
        emit Claimed(account, dripId, amount);
    }

    /// @dev unlocked = total * e^2 / L^2 with e = min(now - start, L): a quarter half way, 81% at nine tenths (D48).
    ///      total <= 5e27 and e^2 < 2^64 for any uint32 length, so the product stays far inside uint256 and one
    ///      division keeps it exact at e == L.
    function _unlocked(DripAccount storage d) internal view returns (uint128) {
        if (d.total == 0 || block.timestamp <= d.start) return 0;
        uint256 e = block.timestamp - d.start;
        uint256 l = d.length;
        if (e >= l) return d.total;
        return uint128((uint256(d.total) * e * e) / (l * l));
    }
}

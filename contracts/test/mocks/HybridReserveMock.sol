// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Local test reserve only. The unrestricted controls model a reserve's yield, losses and limits.
/// @dev This contract is not Morpho and must never be presented as a live Morpho integration.
contract HybridReserveMock is ERC4626 {
    using SafeERC20 for IERC20;

    uint256 public depositLimit = type(uint256).max;
    uint256 public withdrawLimit = type(uint256).max;
    uint256 public redeemLimit = type(uint256).max;
    bool public reportZeroMax = true;

    constructor(IERC20 asset_) ERC20("Local USDG Reserve", "localUSDG") ERC4626(asset_) {}

    /// @notice Match Morpho V2's eighteen-decimal shares for six-decimal USDG.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 12;
    }

    /// @notice Virtual shares used in the Morpho V2 conversion denominator.
    function virtualShares() external pure returns (uint256) {
        return 1e12;
    }

    /// @notice This mock has no reserve-level fees; expose the same accrued conversion inputs.
    function accrueInterestView() external view returns (uint256, uint256, uint256) {
        return (totalAssets(), 0, 0);
    }

    function setLimits(uint256 depositLimit_, uint256 withdrawLimit_, uint256 redeemLimit_) external {
        depositLimit = depositLimit_;
        withdrawLimit = withdrawLimit_;
        redeemLimit = redeemLimit_;
    }

    /// @notice Model a reserve whose max* views conservatively report zero while operations remain executable.
    function setReportZeroMax(bool enabled) external {
        reportZeroMax = enabled;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return reportZeroMax ? 0 : depositLimit;
    }

    function maxMint(address) public view override returns (uint256) {
        return reportZeroMax ? 0 : depositLimit == type(uint256).max ? type(uint256).max : previewDeposit(depositLimit);
    }

    function _availableAssets(address owner) internal view returns (uint256) {
        return Math.min(
            Math.min(previewRedeem(balanceOf(owner)), withdrawLimit),
            previewRedeem(Math.min(balanceOf(owner), redeemLimit))
        );
    }

    function _availableShares(address owner) internal view returns (uint256) {
        uint256 shares = Math.min(balanceOf(owner), redeemLimit);
        if (previewRedeem(shares) <= withdrawLimit) return shares;
        return Math.min(shares, convertToShares(withdrawLimit));
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return reportZeroMax ? 0 : _availableAssets(owner);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return reportZeroMax ? 0 : _availableShares(owner);
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        if (assets > depositLimit) revert ERC4626ExceededMaxDeposit(receiver, assets, depositLimit);
        shares = previewDeposit(assets);
        _deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        assets = previewMint(shares);
        if (assets > depositLimit) revert ERC4626ExceededMaxDeposit(receiver, assets, depositLimit);
        _deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        virtual
        override
        returns (uint256 shares)
    {
        uint256 available = _availableAssets(owner);
        if (assets > available) revert ERC4626ExceededMaxWithdraw(owner, assets, available);
        shares = previewWithdraw(assets);
        _withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        uint256 available = Math.min(balanceOf(owner), redeemLimit);
        if (shares > available) revert ERC4626ExceededMaxRedeem(owner, shares, available);
        assets = previewRedeem(shares);
        if (assets > withdrawLimit) revert ERC4626ExceededMaxWithdraw(owner, assets, withdrawLimit);
        _withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function donate(uint256 assets) external {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
    }

    function simulateLoss(uint256 assets, address recipient) external {
        IERC20(asset()).safeTransfer(recipient, assets);
    }
}

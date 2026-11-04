// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IDealRewards
/// @notice Permissionless registration of funded deals. Reward = fee × rate[term][epoch], capped at 80% of the fee
///         valued at the epoch's posted price, reserved from the epoch's term budget, granted as two drips.
interface IDealRewards {
    struct EpochRates {
        /// @dev sGAGE (18 decimals) per 1 USDG of fee (USDG raw units, `USDG_UNIT`).
        uint128 rate7;
        uint128 rate21;
        /// @dev USDG raw units per 1e18 sGAGE, from the pool TWAP. Enforces the 80% cap.
        uint128 priceUSDGPerSGAGE;
        uint16 lenderShareBps;
        bool set;
    }

    event RatesSet(
        uint256 indexed epoch, uint128 rate7, uint128 rate21, uint128 priceUSDGPerSGAGE, uint16 lenderShareBps
    );
    event Registered(
        uint256 indexed dealId,
        uint256 indexed epoch,
        uint32 term,
        uint128 fee,
        uint128 reward,
        uint128 lenderAmount,
        uint128 borrowerAmount,
        bool budgetExhausted
    );

    error AlreadyRegistered(uint256 dealId);
    error DealNotFunded(uint256 dealId);
    error RatesForPastEpoch(uint256 epoch);
    error InvalidRates();
    error ZeroAddress();

    function USDG_UNIT() external view returns (uint256);
    function MAX_REWARD_SHARE_BPS() external view returns (uint16);

    function register(uint256 dealId) external;
    function registered(uint256 dealId) external view returns (bool);
    function rewardOf(uint256 dealId)
        external
        view
        returns (uint128 total, uint128 lenderAmount, uint128 borrowerAmount);
    function dripIdOf(uint256 dealId, address party) external pure returns (bytes32);
    /// @notice What a deal with this fee would earn if funded now. `budgetAvailable == false` means
    ///         "This week's rewards are fully allocated" (design brief 6).
    function quote(uint32 term, uint128 fee)
        external
        view
        returns (uint128 reward, uint256 epoch, bool budgetAvailable, uint256 budgetRemaining);

    function epochRates(uint256 epoch) external view returns (EpochRates memory);
    /// @notice Rates in force for `epoch`: the posted rates, or the latest posted rates before it (carry-forward).
    function effectiveRates(uint256 epoch) external view returns (EpochRates memory);
    /// @notice Owner (Safe), for the current or a future epoch.
    function setEpochRates(
        uint256 epoch,
        uint128 rate7,
        uint128 rate21,
        uint128 priceUSDGPerSGAGE,
        uint16 lenderShareBps
    ) external;
}

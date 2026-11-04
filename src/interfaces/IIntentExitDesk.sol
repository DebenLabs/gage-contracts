// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice What a vault's lender market asks of its factory's exit desk: the floor of an exit listing, and
/// the leaver's payment once it sells; and what the vault's views ask of the desk its factory bound: the debit an exit
/// sale charged its leaver.
interface IIntentExitDesk {
    /// @notice The share of the interest still to come, in basis points, that a sale of exit listing `id` of `vault`
    /// must leave its holders above book value however far the price has fallen: none for the part of the holding the
    /// leaver's shortfall covers, and what a listing starts at (`START_KEEP_BPS`) for the rest and for no shortfall;
    /// never below the share of the holding's loan-days the leaver's committed shares did not carry, of that start;
    /// the curator floor for a holding with no exit listing.
    /// @param vault The selling vault.
    /// @param id The listed loan.
    /// @return floor Between zero and `IntentLenderMarket.START_KEEP_BPS`.
    function floorBps(address vault, uint256 id) external view returns (uint256 floor);

    /// @notice Redeem the leaver's shares behind exit listing `id`, sold in this transaction, and credit what they pay
    /// to the leaver: called by the selling vault's market after the vault booked the sale, and reverts the whole sale
    /// when nothing can be redeemed. Before redeeming, records the sale's discount below what a listing starts at
    /// against the leaver's own part of the earnings claim the sale opened (`exitDebit`).
    /// @param id The sold loan.
    /// @param nonce The sold listing's nonce.
    function onSale(uint256 id, uint64 nonce) external;

    /// @notice What the exit sale of holding `id` of `vault` charged its leaver: the sale's discount below
    /// what a listing starts at, which the vault's earnings claim on the sale takes from the leaver's own part of it.
    /// @param vault The vault that sold.
    /// @param id The sold loan.
    /// @return owner The leaver the desk named for the listing when it sold; zero for no debit.
    /// @return debit The debit, in the vault asset's raw units; zero for none.
    function exitDebit(address vault, uint256 id) external view returns (address owner, uint256 debit);
}

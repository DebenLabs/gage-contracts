// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice The facts an adapter reads from one position: what a quote binds and what admission checks.
struct PositionFacts {
    address pool;
    address token0;
    address token1;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
}

/// @notice A loan's life: ACTIVE until repaid before its end, DEFAULTED once settled at or after it. ABANDONED is the
/// last resort for a position that could not be unwound for weeks: the vault books the loss and the position may
/// still be recovered later. ROLLED: repaid before its end by a new loan on the same position, which stays in the same
/// escrow (appended last, so the other states keep their numbers).
enum LoanState {
    NONE,
    ACTIVE,
    REPAID,
    DEFAULTED,
    ABANDONED,
    ROLLED
}

/// @notice One loan against one position, held by its own escrow.
struct Loan {
    address borrower;
    address vault;
    address adapter;
    address escrow;
    address pool;
    uint256 tokenId;
    uint128 principal;
    uint128 repayment;
    uint40 start;
    uint40 end;
    LoanState state;
    bool positionReturned;
}

/// @notice The rates signer's offer for one exact position (EIP-712, single use).
/// @dev Every field is static, so `abi.encode(TYPEHASH, quote)` is its EIP-712 struct encoding.
struct LoanQuote {
    address borrower;
    address vault;
    address adapter;
    uint256 tokenId;
    uint128 liquidity;
    int24 tickLower;
    int24 tickUpper;
    uint128 collateralValue;
    uint128 principal;
    uint128 repayment;
    uint32 term;
    uint16 feeBps;
    uint64 deadline;
}

/// @notice The rates signer's floor for removing a defaulted loan's liquidity.
struct UnwindQuote {
    uint256 loanId;
    uint256 min0;
    uint256 min1;
    uint64 deadline;
}

/// @notice The rates signer's floor for selling one token a vault recovered from one defaulted loan.
struct SaleQuote {
    address vault;
    uint256 loanId;
    address token;
    uint256 amountIn;
    uint256 minOut;
    address executor;
    uint64 deadline;
}

/// @notice A pool's admission and caps under one adapter.
struct PoolConfig {
    bool allowed;
    uint24 minHalfWidthTicks;
    uint128 minLoanPrincipal;
    uint128 maxLoanPrincipal;
    uint128 maxOutstanding;
}

/// @notice One pool under one adapter: an entry of a vault's mandate.
struct PoolRef {
    address adapter;
    address pool;
}

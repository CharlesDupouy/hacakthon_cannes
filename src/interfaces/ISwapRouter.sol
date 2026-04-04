// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @title ISwapRouter — Simplified Uniswap V3 SwapRouter interface
/// @notice We define a local simplified version instead of importing the full
///         v3-periphery interface because that interface inherits from
///         IUniswapV3SwapCallback (pragma >=0.7.5) and has complex OZ v3 dependencies.
///         Our project uses OZ v5 + Solidity 0.8.24, so a local copy avoids conflicts.
///
/// @dev We only need `exactInputSingle` for our use case:
///      - User wants to swap USDe → sUSDe (or vice versa)
///      - Vault wraps tokens into staticATokens (waUSDe / wasUSDe)
///      - Vault calls exactInputSingle to swap wrapped tokens on the Uniswap v3 pool
///      - Vault unwraps the output back to the underlying token
interface ISwapRouter {
    /// @notice Parameters for a single-pool exact-input swap
    /// @param tokenIn The address of the input token (staticAToken, e.g., waUSDe)
    /// @param tokenOut The address of the output token (staticAToken, e.g., wasUSDe)
    /// @param fee The fee tier of the pool (500 = 0.05%, 3000 = 0.3%)
    /// @param recipient Who receives the output tokens (our Vault contract)
    /// @param deadline Unix timestamp after which the swap reverts (prevents stale txs)
    /// @param amountIn The exact amount of input tokens to swap
    /// @param amountOutMinimum Minimum output; reverts if slippage exceeds this
    /// @param sqrtPriceLimitX96 Price limit for the swap; 0 = no limit
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    /// @param params The parameters for the swap (see ExactInputSingleParams above)
    /// @return amountOut The amount of the output token received
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IStaticATokenLM — Interface for Aave's StaticATokenLM wrapper
/// @notice StaticATokenLM is an ERC-4626 vault that wraps rebasing aTokens into
///         non-rebasing "static" tokens. This is critical because Uniswap v3 pools
///         cannot handle rebasing tokens (the extra balance becomes phantom reserves
///         that break AMM pricing).
///
/// @dev Key ERC-4626 concepts:
///   - "assets"  = the underlying token (e.g., USDe or sUSDe)
///   - "shares"  = the wrapped static token (e.g., waUSDe or wasUSDe)
///   - deposit(assets, receiver) → mints shares to receiver
///   - redeem(shares, receiver, owner) → burns shares from owner, sends assets to receiver
///   - convertToShares(assets) → preview how many shares for given assets
///   - convertToAssets(shares) → preview how many assets for given shares
///
/// @dev The share price increases over time as Aave yield accrues, but the share
///      balance stays constant. This makes it safe for Uniswap pools.
interface IStaticATokenLM is IERC20 {
    // ═══════════════════════════════════════════════════════════════════
    //                    ERC-4626 CORE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Deposits `assets` amount of underlying tokens and mints shares
    /// @param assets The amount of underlying tokens to deposit (e.g., 100 USDe)
    /// @param receiver The address that will receive the minted shares (waUSDe)
    /// @return shares The amount of shares minted to the receiver
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Burns `shares` from `owner` and sends the equivalent `assets` to `receiver`
    /// @param shares The amount of shares to burn (e.g., 100 waUSDe)
    /// @param receiver The address that receives the underlying tokens (USDe)
    /// @param owner The address whose shares are being burned
    /// @return assets The amount of underlying tokens sent to the receiver
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// @notice Burns shares from `owner` to send exactly `assets` underlying to `receiver`
    /// @param assets The exact amount of underlying tokens desired
    /// @param receiver The address that receives the underlying tokens
    /// @param owner The address whose shares are being burned
    /// @return shares The amount of shares that were burned
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Converts an amount of underlying assets to the equivalent shares
    /// @dev Used to calculate slippage parameters: convert user's amountOutMin
    ///      (in underlying) to shares for the Uniswap swap's amountOutMinimum
    /// @param assets The amount of underlying tokens
    /// @return shares The equivalent amount of shares
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /// @notice Converts an amount of shares to the equivalent underlying assets
    /// @dev Useful for displaying actual underlying value of wrapped positions
    /// @param shares The amount of shares
    /// @return assets The equivalent amount of underlying tokens
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice Returns the address of the underlying asset token
    /// @return The address of the underlying ERC-20 token (USDe or sUSDe)
    function asset() external view returns (address);

    // ═══════════════════════════════════════════════════════════════════
    //                  AAVE-SPECIFIC: REWARD CLAIMS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Claims accrued Aave incentive rewards and sends them to `receiver`
    /// @dev This is an Aave-specific extension — not part of standard ERC-4626.
    ///      Rewards come from Aave's liquidity mining program (e.g., stkAAVE).
    /// @param receiver The address that will receive the reward tokens
    function claimRewards(address receiver) external;
}

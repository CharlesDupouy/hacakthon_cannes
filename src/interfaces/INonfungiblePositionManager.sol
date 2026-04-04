// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @title INonfungiblePositionManager — Simplified Uniswap V3 Position Manager
/// @notice Local simplified version of Uniswap's INonfungiblePositionManager.
///         The full v3-periphery version inherits from IPoolInitializer,
///         IERC721Metadata, IERC721Enumerable, IERC721Permit, IPeripheryPayments, etc.
///         Those interfaces use OZ v3 (pragma >=0.7.5) which conflicts with our 0.8.24.
///
/// @dev We only need four functions:
///   1. createAndInitializePoolIfNecessary — creates the waUSDe/wasUSDe pool
///   2. mint — adds liquidity and creates an NFT position
///   3. decreaseLiquidity — removes liquidity from a position
///   4. collect — actually transfers the tokens out after decreaseLiquidity
///
///   IMPORTANT: decreaseLiquidity only "accounts" the tokens to the position.
///   You MUST call collect() afterward to actually receive them. Forgetting this
///   is a very common bug (mentioned in CLAUDE.md common mistakes).
interface INonfungiblePositionManager {
    // ═══════════════════════════════════════════════════════════════════
    //                        POOL CREATION
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Creates a pool (if it doesn't exist) and initializes it with a price
    /// @dev token0 MUST be < token1 (sorted by address). Get this wrong and it reverts.
    /// @param token0 The lower-address token of the pair
    /// @param token1 The higher-address token of the pair
    /// @param fee The fee tier (500, 3000, 10000)
    /// @param sqrtPriceX96 The initial sqrt(price) * 2^96 of the pool
    ///        For 1:1 price: sqrtPriceX96 = 79228162514264337593543950336
    /// @return pool The address of the created/existing pool
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);

    // ═══════════════════════════════════════════════════════════════════
    //                       MINT (ADD LIQUIDITY)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Parameters for minting a new LP position
    /// @param token0 Lower-address token (MUST be sorted!)
    /// @param token1 Higher-address token (MUST be sorted!)
    /// @param fee Pool fee tier — must match the pool
    /// @param tickLower Lower bound of the price range (must be multiple of tick spacing)
    /// @param tickUpper Upper bound of the price range (must be multiple of tick spacing)
    /// @param amount0Desired Desired amount of token0 to deposit
    /// @param amount1Desired Desired amount of token1 to deposit
    /// @param amount0Min Minimum token0 (slippage protection; 0 for hackathon)
    /// @param amount1Min Minimum token1 (slippage protection; 0 for hackathon)
    /// @param recipient Who receives the NFT (our Vault — it holds NFTs for users)
    /// @param deadline Transaction deadline (timestamp)
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    /// @notice Creates a new position wrapped in an NFT
    /// @param params The mint parameters (see MintParams struct)
    /// @return tokenId The NFT ID representing this position
    /// @return liquidity The amount of liquidity created
    /// @return amount0 Actual amount of token0 used
    /// @return amount1 Actual amount of token1 used
    function mint(MintParams calldata params)
        external
        payable
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    // ═══════════════════════════════════════════════════════════════════
    //                  DECREASE LIQUIDITY (STEP 1/2)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Parameters for decreasing liquidity in a position
    /// @param tokenId The NFT position ID
    /// @param liquidity How much liquidity to remove
    /// @param amount0Min Minimum token0 to receive (slippage protection)
    /// @param amount1Min Minimum token1 to receive (slippage protection)
    /// @param deadline Transaction deadline
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Decreases liquidity in a position — tokens are NOT transferred yet!
    /// @dev This only "accounts" the tokens. You MUST call collect() to get them.
    /// @param params The decrease parameters
    /// @return amount0 The amount of token0 accounted to the position
    /// @return amount1 The amount of token1 accounted to the position
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    // ═══════════════════════════════════════════════════════════════════
    //                     COLLECT (STEP 2/2)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Parameters for collecting tokens owed to a position
    /// @param tokenId The NFT position ID
    /// @param recipient Where to send the collected tokens
    /// @param amount0Max Maximum amount of token0 to collect (use type(uint128).max for all)
    /// @param amount1Max Maximum amount of token1 to collect (use type(uint128).max for all)
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice Collects tokens owed to a position (from fees or decreased liquidity)
    /// @dev Must be called after decreaseLiquidity to actually receive the tokens
    /// @param params The collect parameters
    /// @return amount0 The amount of token0 collected
    /// @return amount1 The amount of token1 collected
    function collect(CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);
}

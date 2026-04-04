// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// PURPOSE:
//   This Vault sits between users and the Uniswap v3 pool. Users deposit plain
//   USDe or sUSDe, and the Vault wraps them into Aave StaticATokenLM tokens
//   (waUSDe / wasUSDe) before interacting with the Uniswap pool.
//
// WHY THIS ARCHITECTURE?
//   • Aave aTokens are REBASING — their balance silently increases as yield
//     accrues. If you put rebasing tokens directly into a Uniswap pool, the AMM
//     can't track the extra balance. This creates "phantom reserves" that break
//     pricing and can be arbitraged by MEV bots.
//
//   • StaticATokenLM (ERC-4626) wraps aTokens into NON-REBASING tokens. The
//     share balance stays constant; only the share PRICE increases over time.
//     This is safe for Uniswap v3 concentrated liquidity pools.
//
//   • Result: LPs earn Uniswap swap fees + Aave lending yield on both sides
//     of the pair. Best of both worlds.
//
// FLOW OVERVIEW:
//   User ──(USDe)──> Vault ──(wrap)──> waUSDe ──(swap)──> wasUSDe ──(unwrap)──> sUSDe ──> User
//
// ═══════════════════════════════════════════════════════════════════════════════

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticATokenLM} from "./interfaces/IStaticATokenLM.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";

/// @title YieldEnhancedSwapVault
/// @author Hackathon Team — Uniswap API Track
/// @notice A vault that lets users swap USDe <> sUSDe or provide LP, while the
///         underlying Uniswap pool holds Aave-wrapped versions for extra yield.
/// @dev This contract holds Uniswap v3 LP NFTs on behalf of users and tracks
///      ownership via the `userPositions` mapping.
contract Vault {
    // ═══════════════════════════════════════════════════════════════════
    //                       STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════
    //
    // All protocol addresses are immutable — set once in constructor, never
    // changed. This saves gas (stored in bytecode, not storage) and prevents
    // admin-key attacks.
    // ═══════════════════════════════════════════════════════════════════

    /// @notice The underlying token: USDe (Ethena's USD stablecoin)
    IERC20 public immutable usde;

    /// @notice The underlying token: sUSDe (Ethena's staked/yield-bearing USDe)
    IERC20 public immutable susde;

    /// @notice Aave StaticATokenLM wrapper for USDe.
    ///         Deposits USDe → mints waUSDe (non-rebasing, ERC-4626 shares).
    ///         The share price increases as Aave lending yield accrues.
    IStaticATokenLM public immutable waUSDe;

    /// @notice Aave StaticATokenLM wrapper for sUSDe.
    ///         Deposits sUSDe → mints wasUSDe (non-rebasing, ERC-4626 shares).
    IStaticATokenLM public immutable wasUSDe;

    /// @notice Uniswap v3 NonfungiblePositionManager — used for:
    ///         1. Creating the waUSDe/wasUSDe pool
    ///         2. Minting LP positions (NFTs)
    ///         3. Decreasing liquidity + collecting tokens
    INonfungiblePositionManager public immutable positionManager;

    /// @notice Uniswap v3 SwapRouter — used for executing single-pool swaps
    ///         between waUSDe and wasUSDe.
    ISwapRouter public immutable swapRouter;

    /// @notice The Uniswap v3 pool fee tier for our waUSDe/wasUSDe pool.
    ///         500 = 0.05% (recommended for correlated pairs like stablecoins).
    ///         3000 = 0.3% (fallback if 0.05% pool has issues).
    uint24 public immutable poolFee;

    /// @notice The deployer/owner of the vault — receives claimed Aave rewards.
    ///         In production, rewards would be distributed proportionally to LPs.
    ///         For hackathon simplicity, they go to the admin.
    address public immutable owner;

    /// @notice Tracks which Uniswap v3 LP NFT positions belong to which user.
    ///         When a user adds liquidity, the Vault mints an NFT and stores its
    ///         tokenId here. Only the original depositor can remove their liquidity.
    /// @dev Key: user address → Value: array of NFT position IDs
    mapping(address => uint256[]) public userPositions;

    // ═══════════════════════════════════════════════════════════════════
    //                            EVENTS
    // ═══════════════════════════════════════════════════════════════════
    //
    // Events are critical for off-chain tracking (The Graph, block explorers,
    // demo scripts). They cost minimal gas and provide audit trails.
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Emitted when a user successfully swaps through the Vault
    /// @param user The user who initiated the swap
    /// @param tokenIn The input token address (USDe or sUSDe)
    /// @param tokenOut The output token address (sUSDe or USDe)
    /// @param amountIn The amount of input tokens the user provided
    /// @param amountOut The amount of output tokens the user received
    event Swapped(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice Emitted when a user adds liquidity through the Vault
    /// @param user The LP who deposited
    /// @param tokenId The Uniswap v3 NFT position ID created
    /// @param amountUSDe The amount of USDe actually used (after Uniswap optimization)
    /// @param amountsUSDe The amount of sUSDe actually used
    /// @param liquidity The actual liquidity minted in the pool
    event LiquidityAdded(
        address indexed user,
        uint256 indexed tokenId,
        uint256 amountUSDe,
        uint256 amountsUSDe,
        uint128 liquidity
    );

    /// @notice Emitted when a user removes liquidity from the Vault
    /// @param user The LP who withdrew
    /// @param tokenId The NFT position that was (partially) liquidated
    /// @param amountUSDe The amount of USDe returned to the user
    /// @param amountsUSDe The amount of sUSDe returned to the user
    event LiquidityRemoved(
        address indexed user,
        uint256 indexed tokenId,
        uint256 amountUSDe,
        uint256 amountsUSDe
    );

    /// @notice Emitted when Aave rewards are claimed by the admin
    event RewardsClaimed(address indexed admin);

    // ═══════════════════════════════════════════════════════════════════
    //                         CUSTOM ERRORS
    // ═══════════════════════════════════════════════════════════════════
    //
    // Custom errors are cheaper than require(string) — they save gas by
    // not storing string data on-chain. They also give better error messages
    // in etherscan and debugging tools.
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Thrown when tokenIn is neither USDe nor sUSDe
    error InvalidToken();

    /// @notice Thrown when amountIn is zero (nothing to swap)
    error ZeroAmount();

    /// @notice Thrown when the user tries to remove a position they don't own
    error NotPositionOwner();

    /// @notice Thrown when only the owner/admin can call a function
    error OnlyOwner();

    /// @notice Thrown when a token transfer fails (transferFrom returns false)
    error TransferFailed();

    // ═══════════════════════════════════════════════════════════════════
    //                         CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════
    //
    // Sets all immutable addresses and pre-approves Aave and Uniswap contracts
    // with max allowance. This is safe because:
    //   - Aave and Uniswap are battle-tested, audited protocols
    //   - Max approval avoids repeated approve() calls (saves ~20k gas each)
    //   - The Vault only holds tokens transiently during operations
    //
    // The approval chain is:
    //   USER → approve(Vault) → done per-tx by user
    //   VAULT → approve(Aave) → done once in constructor (max)
    //   VAULT → approve(Uniswap) → done once in constructor (max)
    // ═══════════════════════════════════════════════════════════════════

    /// @param _usde Address of the USDe token contract
    /// @param _susde Address of the sUSDe token contract
    /// @param _waUSDe Address of the Aave StaticATokenLM wrapper for USDe
    /// @param _wasUSDe Address of the Aave StaticATokenLM wrapper for sUSDe
    /// @param _positionManager Address of the Uniswap v3 NonfungiblePositionManager
    /// @param _swapRouter Address of the Uniswap v3 SwapRouter
    /// @param _poolFee The fee tier for the Uniswap pool (500 or 3000)
    constructor(
        address _usde,
        address _susde,
        address _waUSDe,
        address _wasUSDe,
        address _positionManager,
        address _swapRouter,
        uint24 _poolFee
    ) {
        // ── Store immutable references ────────────────────────────────
        usde = IERC20(_usde);
        susde = IERC20(_susde);
        waUSDe = IStaticATokenLM(_waUSDe);
        wasUSDe = IStaticATokenLM(_wasUSDe);
        positionManager = INonfungiblePositionManager(_positionManager);
        swapRouter = ISwapRouter(_swapRouter);
        poolFee = _poolFee;
        owner = msg.sender;

        // ── Pre-approve Aave StaticAToken wrappers ────────────────────
        //    The Vault needs to approve the staticAToken contracts to
        //    pull USDe/sUSDe from the Vault when we call deposit().
        //    Using type(uint256).max so we never need to re-approve.
        IERC20(_usde).approve(_waUSDe, type(uint256).max);
        IERC20(_susde).approve(_wasUSDe, type(uint256).max);

        // ── Pre-approve Uniswap SwapRouter ────────────────────────────
        //    The SwapRouter needs to pull waUSDe/wasUSDe from the Vault
        //    when we call exactInputSingle(). Max approval for efficiency.
        IERC20(_waUSDe).approve(_swapRouter, type(uint256).max);
        IERC20(_wasUSDe).approve(_swapRouter, type(uint256).max);

        // ── Pre-approve Uniswap NonfungiblePositionManager ────────────
        //    The PositionManager needs to pull waUSDe/wasUSDe from the
        //    Vault when we call mint() to add liquidity.
        IERC20(_waUSDe).approve(_positionManager, type(uint256).max);
        IERC20(_wasUSDe).approve(_positionManager, type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════
    //
    //    ███████╗██╗    ██╗ █████╗ ██████╗
    //    ██╔════╝██║    ██║██╔══██╗██╔══██╗
    //    ███████╗██║ █╗ ██║███████║██████╔╝
    //    ╚════██║██║███╗██║██╔══██║██╔═══╝
    //    ███████║╚███╔███╔╝██║  ██║██║
    //    ╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝
    //
    //    THE MOST IMPORTANT FUNCTION — BUILD & TEST FIRST
    //
    // ═══════════════════════════════════════════════════════════════════
    //
    // WHAT IT DOES (high level):
    //   User sends USDe → gets sUSDe back (or vice versa).
    //   Under the hood, the Vault wraps/unwraps through Aave and swaps
    //   the wrapped versions on Uniswap v3.
    //
    // DETAILED FLOW:
    //   1. User calls swap(USDe, 100, 99)     — "swap 100 USDe, want ≥99 sUSDe"
    //   2. Vault pulls 100 USDe from user     — transferFrom(user → vault)
    //   3. Vault wraps USDe via Aave          — deposit(100 USDe) → ~100 waUSDe
    //   4. Vault swaps on Uniswap             — waUSDe → wasUSDe via SwapRouter
    //   5. Vault unwraps wasUSDe via Aave     — redeem(wasUSDe) → sUSDe sent to user
    //   6. Emit Swapped event
    //
    // WHY THIS WORKS:
    //   - The Uniswap pool only ever sees waUSDe/wasUSDe (non-rebasing, safe)
    //   - The user only ever sees USDe/sUSDe (familiar, simple)
    //   - Aave yield accrues in the pool because the staticAToken share price
    //     increases over time → pool reserves become worth more in underlying terms
    //
    // SLIPPAGE PROTECTION:
    //   amountOutMin is specified in UNDERLYING terms (how many sUSDe the user
    //   expects). We convert it to SHARES using convertToShares() before passing
    //   it to Uniswap, because Uniswap deals in wrapped token amounts.
    //
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Swap USDe for sUSDe, or sUSDe for USDe, through the yield-enhanced pool
    /// @param tokenIn The address of the input token (must be USDe or sUSDe)
    /// @param amountIn The amount of input tokens to swap
    /// @param amountOutMin The minimum amount of output tokens (in underlying terms)
    ///        that the user is willing to accept. Reverts if slippage is too high.
    /// @return amountOut The actual amount of output tokens received by the user
    function swap(
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin
    ) external returns (uint256 amountOut) {
        // ── Step 0: Input validation ──────────────────────────────────
        //    We only support USDe and sUSDe as input tokens. Anything
        //    else would have no corresponding staticAToken wrapper.
        if (tokenIn != address(usde) && tokenIn != address(susde)) {
            revert InvalidToken();
        }
        if (amountIn == 0) revert ZeroAmount();

        // ── Step 1: Determine which tokens are input vs output ────────
        //    If the user sends USDe, they want sUSDe back (and vice versa).
        //    We also determine the corresponding staticAToken wrappers:
        //      USDe  → waUSDe  (input wrapper)
        //      sUSDe → wasUSDe (output wrapper)
        //
        //    isUsdeIn is a boolean flag used to select the right path.
        bool isUsdeIn = (tokenIn == address(usde));

        // Select the underlying input/output tokens
        IERC20 underlyingIn = isUsdeIn ? usde : susde;
        // underlyingOut is not directly used since we redeem to user via Aave

        // Select the corresponding Aave staticAToken wrappers
        IStaticATokenLM staticIn = isUsdeIn ? waUSDe : wasUSDe;
        IStaticATokenLM staticOut = isUsdeIn ? wasUSDe : waUSDe;

        // ── Step 2: Pull input tokens from user to Vault ──────────────
        //    The user must have called underlyingIn.approve(vault, amountIn)
        //    BEFORE calling this function. If they haven't, transferFrom reverts.
        //
        //    We use a require check on the return value because some ERC-20
        //    tokens (like USDT) return false instead of reverting on failure.
        bool success = underlyingIn.transferFrom(msg.sender, address(this), amountIn);
        if (!success) revert TransferFailed();

        // ── Step 3: Wrap input tokens via Aave StaticATokenLM ─────────
        //    deposit(assets, receiver) is the ERC-4626 standard function.
        //    - assets = amountIn (e.g., 100 USDe)
        //    - receiver = address(this) (the Vault receives the waUSDe shares)
        //
        //    Returns the number of shares minted. Due to the Aave exchange rate,
        //    wrappedAmount may differ slightly from amountIn (e.g., 99.98 waUSDe
        //    for 100 USDe if some yield has already accrued).
        //
        //    NOTE: We already approved staticIn to pull tokens from the Vault
        //    in the constructor (max approval to Aave), so no approve needed here.
        uint256 wrappedAmount = staticIn.deposit(amountIn, address(this));

        // ── Step 4: Swap on Uniswap v3 ───────────────────────────────
        //    Now we swap the wrapped input (waUSDe) for the wrapped output
        //    (wasUSDe) through the Uniswap v3 pool.
        //
        //    Key parameters:
        //    - tokenIn/tokenOut: the staticAToken addresses (NOT underlying!)
        //    - fee: the pool fee tier (500 = 0.05% for correlated pairs)
        //    - recipient: address(this) — Vault receives output, will unwrap next
        //    - amountIn: the exact wrapped amount from step 3
        //    - amountOutMinimum: convert user's slippage from underlying to shares
        //      because Uniswap deals in wrapped token amounts
        //    - sqrtPriceLimitX96: 0 means no price limit (accept any execution price)
        //    - deadline: block.timestamp means the tx must execute in this block
        //
        //    WHY convertToShares for amountOutMinimum?
        //    The user specified amountOutMin in underlying terms (e.g., "I want at
        //    least 99 sUSDe"). But Uniswap's amountOutMinimum is in wrapped token
        //    terms (wasUSDe shares). We convert: 99 sUSDe → ~99 wasUSDe shares.
        //    This ensures slippage protection is correctly applied in Uniswap's
        //    terms while the user thinks in familiar underlying token amounts.
        //
        //    NOTE: Approval already set in constructor (max to SwapRouter).
        uint256 wrappedOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(staticIn),
                tokenOut: address(staticOut),
                fee: poolFee,
                recipient: address(this),  // Vault receives wrapped output
                deadline: block.timestamp, // Must execute in this block
                amountIn: wrappedAmount,
                amountOutMinimum: staticOut.convertToShares(amountOutMin),
                sqrtPriceLimitX96: 0       // No price limit
            })
        );

        // ── Step 5: Unwrap output via Aave StaticATokenLM ─────────────
        //    redeem(shares, receiver, owner) is the ERC-4626 standard function.
        //    - shares = wrappedOut (the wasUSDe we got from Uniswap)
        //    - receiver = msg.sender (user gets the underlying tokens directly!)
        //    - owner = address(this) (the Vault owns the shares being redeemed)
        //
        //    This burns the wasUSDe shares and sends the equivalent sUSDe
        //    directly to the user. The user never touches wrapped tokens.
        //
        //    amountOut is the actual underlying amount the user receives.
        //    Due to the Aave exchange rate, this may be slightly more than
        //    the wrappedOut amount (shares are worth more than 1:1 in underlying).
        amountOut = staticOut.redeem(wrappedOut, msg.sender, address(this));

        // ── Step 6: Emit event for off-chain tracking ─────────────────
        //    This event is indexed by The Graph, block explorers, and our
        //    demo scripts to show successful swaps with all details.
        address tokenOut = isUsdeIn ? address(susde) : address(usde);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    // ═══════════════════════════════════════════════════════════════════
    //
    //    ██╗     ██████╗      █████╗ ██████╗ ██████╗
    //    ██║     ██╔══██╗    ██╔══██╗██╔══██╗██╔══██╗
    //    ██║     ██████╔╝    ███████║██║  ██║██║  ██║
    //    ██║     ██╔═══╝     ██╔══██║██║  ██║██║  ██║
    //    ███████╗██║         ██║  ██║██████╔╝██████╔╝
    //    ╚══════╝╚═╝         ╚═╝  ╚═╝╚═════╝ ╚═════╝
    //
    //    DEPOSIT UNDERLYING + ADD LIQUIDITY TO UNISWAP
    //
    // ═══════════════════════════════════════════════════════════════════
    //
    // WHAT IT DOES (high level):
    //   User deposits USDe + sUSDe → Vault wraps both → adds liquidity
    //   to the Uniswap v3 pool → user gets an LP position tracked by the Vault.
    //
    // DETAILED FLOW:
    //   1. Pull USDe + sUSDe from user
    //   2. Wrap both into waUSDe + wasUSDe via Aave
    //   3. Sort token addresses (Uniswap requires token0 < token1)
    //   4. Mint LP position via NonfungiblePositionManager
    //   5. Store NFT position ID for the user
    //   6. Refund any leftover tokens not used by the position
    //
    // WHY LEFTOVER REFUND?
    //   Uniswap v3 concentrated liquidity may not use all deposited tokens.
    //   The actual ratio depends on the current price vs the tick range.
    //   If the price is closer to one end of the range, more of one token
    //   is used. We refund the unused portion so user funds aren't stuck.
    //
    // TICK RANGE:
    //   User specifies tickLower and tickUpper to define their price range.
    //   IMPORTANT: These must be multiples of the tick spacing!
    //     - Fee 500 (0.05%)  → tick spacing = 10
    //     - Fee 3000 (0.3%)  → tick spacing = 60
    //   For full range on 0.05%: tickLower = -887270, tickUpper = 887270.
    //
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Deposit USDe and sUSDe, wrap them, and add as liquidity to Uniswap v3
    /// @param amountUSDe The amount of USDe to deposit (user must have approved Vault)
    /// @param amountsUSDe The amount of sUSDe to deposit (user must have approved Vault)
    /// @param tickLower The lower tick of the concentration range (must be multiple of tick spacing)
    /// @param tickUpper The upper tick of the concentration range (must be multiple of tick spacing)
    /// @return tokenId The Uniswap v3 NFT position ID (tracked in userPositions)
    /// @return liquidity The actual liquidity minted in the pool
    function depositAndAddLiquidity(
        uint256 amountUSDe,
        uint256 amountsUSDe,
        int24 tickLower,
        int24 tickUpper
    ) external returns (uint256 tokenId, uint128 liquidity) {
        // ── Step 1: Pull BOTH underlying tokens from user ─────────────
        //    User must have called both:
        //      usde.approve(vault, amountUSDe)
        //      susde.approve(vault, amountsUSDe)
        //    before calling this function.
        if (!usde.transferFrom(msg.sender, address(this), amountUSDe)) revert TransferFailed();
        if (!susde.transferFrom(msg.sender, address(this), amountsUSDe)) revert TransferFailed();

        // ── Step 2: Wrap both into staticATokens via Aave ─────────────
        //    deposit(assets, receiver) → returns shares minted
        //    USDe  → waUSDe  (wrappedUSDe shares)
        //    sUSDe → wasUSDe (wrappedsUSDe shares)
        //
        //    The wrapped amounts may differ from input amounts due to the
        //    Aave exchange rate (share price > 1.0 if yield has accrued).
        uint256 wrappedUSDe = waUSDe.deposit(amountUSDe, address(this));
        uint256 wrappedsUSDe = wasUSDe.deposit(amountsUSDe, address(this));

        // ── Step 3 + 4: Sort tokens + mint LP position ────────────────
        //    Delegated to internal _mintPosition to avoid "stack too deep" error.
        //    The EVM limits 16 stack slots per function scope. By extracting
        //    the mint logic, we keep each function under the limit.
        //
        //    _mintPosition handles:
        //      - Sorting waUSDe/wasUSDe by address (Uniswap requires token0 < token1)
        //      - Calling positionManager.mint() with correct parameters
        //      - Refunding leftover wrapped tokens that Uniswap didn't use
        //
        //    Returns the NFT tokenId and liquidity amount.
        (tokenId, liquidity) = _mintPosition(wrappedUSDe, wrappedsUSDe, tickLower, tickUpper);

        // ── Step 5: Store position NFT ID for the user ────────────────
        //    The Vault holds all LP NFTs, but we track which NFT belongs
        //    to which user. This is checked in removeLiquidityAndWithdraw
        //    to ensure only the original depositor can pull their liquidity.
        userPositions[msg.sender].push(tokenId);

        // ── Step 6: Emit event ────────────────────────────────────────
        emit LiquidityAdded(msg.sender, tokenId, amountUSDe, amountsUSDe, liquidity);
    }

    /// @dev Internal helper: sorts tokens, mints the LP position, and refunds leftovers.
    ///      Extracted from depositAndAddLiquidity to avoid "stack too deep" error —
    ///      the EVM limits each function to 16 stack slots, and the combined logic
    ///      exceeds that limit.
    ///
    ///      CRITICAL: Uniswap v3 requires token0 < token1 (sorted by address).
    ///      If you get this wrong, EVERY call to the pool reverts with a cryptic error.
    ///      This is listed as the #1 common mistake in CLAUDE.md.
    function _mintPosition(
        uint256 wrappedUSDe,
        uint256 wrappedsUSDe,
        int24 tickLower,
        int24 tickUpper
    ) internal returns (uint256 tokenId, uint128 liquidity) {
        // ── Sort token addresses for Uniswap ──────────────────────────
        //    We sort the addresses and corresponding amounts together so
        //    amount0 always matches token0 and amount1 matches token1.
        address token0;
        address token1;
        uint256 amount0;
        uint256 amount1;

        if (address(waUSDe) < address(wasUSDe)) {
            // waUSDe has a lower address → it's token0
            token0 = address(waUSDe);
            token1 = address(wasUSDe);
            amount0 = wrappedUSDe;
            amount1 = wrappedsUSDe;
        } else {
            // wasUSDe has a lower address → it's token0
            token0 = address(wasUSDe);
            token1 = address(waUSDe);
            amount0 = wrappedsUSDe;
            amount1 = wrappedUSDe;
        }

        // ── Mint LP position via NonfungiblePositionManager ───────────
        //    This creates a new concentrated liquidity position in the pool
        //    and mints an ERC-721 NFT representing ownership.
        //
        //    Parameters explained:
        //    - token0/token1: sorted wrapped token addresses
        //    - fee: must match the pool's fee tier
        //    - tickLower/tickUpper: the user-defined concentration range
        //    - amount0Desired/amount1Desired: how much we want to deposit
        //    - amount0Min/amount1Min: 0 for hackathon (skip slippage protection)
        //      In production, set these to ~98% of desired to prevent frontrunning
        //    - recipient: address(this) — the Vault holds the NFT
        //    - deadline: 10 minutes from now
        //
        //    NOTE: Approvals already set in constructor (max to positionManager).
        uint256 actualAmount0;
        uint256 actualAmount1;

        (tokenId, liquidity, actualAmount0, actualAmount1) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: poolFee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0, // No slippage protection (hackathon simplification)
                amount1Min: 0, // In production: set to ~98% of desired amounts
                recipient: address(this), // Vault holds the NFT on behalf of user
                deadline: block.timestamp + 600 // 10-minute deadline
            })
        );

        // ── Refund leftover wrapped tokens ────────────────────────────
        //    Uniswap v3 concentrated liquidity often doesn't use 100% of both
        //    tokens. The actual usage depends on the current pool price relative
        //    to the tick range. Whatever wasn't used stays in the Vault contract.
        //
        //    We redeem any leftover wrapped tokens back to underlying and
        //    send them to the user. This prevents user funds being locked.
        //
        //    leftover = deposited - actuallyUsed
        //    If token0 is waUSDe, we redeem waUSDe → USDe back to user.
        //    If token0 is wasUSDe, we redeem wasUSDe → sUSDe back to user.
        _refundLeftover(token0, amount0 - actualAmount0);
        _refundLeftover(token1, amount1 - actualAmount1);
    }

    /// @dev Internal helper: refunds leftover wrapped tokens to the caller.
    ///      Determines which staticAToken the wrapped address corresponds to,
    ///      then redeems the leftover shares back to underlying for the user.
    ///      Extracted to keep _mintPosition under the stack limit.
    function _refundLeftover(address wrappedToken, uint256 leftover) internal {
        if (leftover == 0) return; // Nothing to refund

        if (wrappedToken == address(waUSDe)) {
            // Redeem leftover waUSDe → USDe back to user
            waUSDe.redeem(leftover, msg.sender, address(this));
        } else {
            // Redeem leftover wasUSDe → sUSDe back to user
            wasUSDe.redeem(leftover, msg.sender, address(this));
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //
    //    ██╗     ██████╗     ██████╗ ███████╗███╗   ███╗ ██████╗ ██╗   ██╗███████╗
    //    ██║     ██╔══██╗    ██╔══██╗██╔════╝████╗ ████║██╔═══██╗██║   ██║██╔════╝
    //    ██║     ██████╔╝    ██████╔╝█████╗  ██╔████╔██║██║   ██║██║   ██║█████╗
    //    ██║     ██╔═══╝     ██╔══██╗██╔══╝  ██║╚██╔╝██║██║   ██║╚██╗ ██╔╝██╔══╝
    //    ███████╗██║         ██║  ██║███████╗██║ ╚═╝ ██║╚██████╔╝ ╚████╔╝ ███████╗
    //    ╚══════╝╚═╝         ╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝ ╚═════╝   ╚═══╝  ╚══════╝
    //
    //    REMOVE LIQUIDITY AND WITHDRAW UNDERLYING TOKENS
    //
    // ═══════════════════════════════════════════════════════════════════
    //
    // WHAT IT DOES:
    //   Reverse of depositAndAddLiquidity. Takes liquidity out of Uniswap,
    //   unwraps the staticATokens via Aave, and sends underlying back to user.
    //
    // IMPORTANT TWO-STEP PROCESS:
    //   Uniswap v3 has a two-step withdrawal:
    //     1. decreaseLiquidity() — "accounts" the tokens (records they are owed)
    //     2. collect() — actually TRANSFERS the tokens out
    //   If you only call decreaseLiquidity without collect, the tokens stay
    //   locked in the PositionManager! This is the #1 most common LP bug.
    //
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Remove liquidity from a Uniswap position and withdraw underlying tokens
    /// @param positionId The NFT position ID (must be owned by msg.sender via userPositions)
    /// @param liquidity The amount of liquidity to remove from the position
    function removeLiquidityAndWithdraw(uint256 positionId, uint128 liquidity) external {
        // ── Step 1: Verify ownership ──────────────────────────────────
        //    Only the user who created this position (stored in userPositions)
        //    can remove its liquidity. This is a critical security check.
        //
        //    We loop through the user's positions to find the matching ID.
        //    If not found, the function reverts with NotPositionOwner().
        //
        //    Note: In production, you might use a more gas-efficient data
        //    structure (like a mapping). Array lookup is O(n) but fine for
        //    a hackathon where users have few positions.
        bool isOwner = false;
        uint256[] storage positions = userPositions[msg.sender];
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i] == positionId) {
                isOwner = true;
                break;
            }
        }
        if (!isOwner) revert NotPositionOwner();

        // ── Step 2: Decrease liquidity (accounting step) ──────────────
        //    This tells Uniswap to "mark" the tokens as owed to our position.
        //    The tokens are NOT transferred yet — they remain in the
        //    PositionManager until collect() is called.
        //
        //    amount0Min/amount1Min = 0 for hackathon simplicity.
        //    In production, set slippage protection here.
        positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: positionId,
                liquidity: liquidity,
                amount0Min: 0, // No slippage protection (hackathon)
                amount1Min: 0, // In production: calculate based on expected amounts
                deadline: block.timestamp + 600
            })
        );

        // ── Step 3: Collect the tokens (actual transfer step) ─────────
        //    NOW we actually transfer the tokens out of the PositionManager.
        //    We set amount0Max and amount1Max to type(uint128).max to collect
        //    ALL owed tokens (both from the liquidity removal AND any
        //    accumulated swap fees).
        //
        //    recipient = address(this) — the Vault receives the wrapped tokens
        //    so we can unwrap them before sending to the user.
        (uint256 collected0, uint256 collected1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionId,
                recipient: address(this), // Vault receives for unwrapping
                amount0Max: type(uint128).max, // Collect everything owed
                amount1Max: type(uint128).max  // Including accumulated fees
            })
        );

        // ── Step 4: Determine token ordering ──────────────────────────
        //    The collected amounts (collected0, collected1) correspond to
        //    the sorted order (token0, token1). We need to figure out
        //    which is waUSDe and which is wasUSDe to unwrap correctly.
        //
        //    Same sorting logic as in depositAndAddLiquidity.
        uint256 waUsdeAmount;
        uint256 wasUsdeAmount;

        if (address(waUSDe) < address(wasUSDe)) {
            // waUSDe is token0, wasUSDe is token1
            waUsdeAmount = collected0;
            wasUsdeAmount = collected1;
        } else {
            // wasUSDe is token0, waUSDe is token1
            waUsdeAmount = collected1;
            wasUsdeAmount = collected0;
        }

        // ── Step 5: Unwrap staticATokens back to underlying ──────────
        //    redeem(shares, receiver, owner)
        //    - shares: the wrapped token amount to burn
        //    - receiver: msg.sender (user gets underlying directly)
        //    - owner: address(this) (the Vault owns the wrapped tokens)
        //
        //    waUSDe.redeem() → sends USDe to user
        //    wasUSDe.redeem() → sends sUSDe to user
        uint256 usdeReceived = 0;
        uint256 susdeReceived = 0;

        if (waUsdeAmount > 0) {
            usdeReceived = waUSDe.redeem(waUsdeAmount, msg.sender, address(this));
        }
        if (wasUsdeAmount > 0) {
            susdeReceived = wasUSDe.redeem(wasUsdeAmount, msg.sender, address(this));
        }

        // ── Step 6: Emit event ────────────────────────────────────────
        emit LiquidityRemoved(msg.sender, positionId, usdeReceived, susdeReceived);
    }

    // ═══════════════════════════════════════════════════════════════════
    //
    //    ██████╗ ███████╗██╗    ██╗ █████╗ ██████╗ ██████╗ ███████╗
    //    ██╔══██╗██╔════╝██║    ██║██╔══██╗██╔══██╗██╔══██╗██╔════╝
    //    ██████╔╝█████╗  ██║ █╗ ██║███████║██████╔╝██║  ██║███████╗
    //    ██╔══██╗██╔══╝  ██║███╗██║██╔══██║██╔══██╗██║  ██║╚════██║
    //    ██║  ██║███████╗╚███╔███╔╝██║  ██║██║  ██║██████╔╝███████║
    //    ╚═╝  ╚═╝╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝ ╚══════╝
    //
    //    CLAIM AAVE INCENTIVE REWARDS — CHERRY ON TOP
    //
    // ═══════════════════════════════════════════════════════════════════
    //
    // WHAT IT DOES:
    //   Claims accrued Aave liquidity mining rewards (e.g., stkAAVE) from
    //   both StaticAToken wrappers and sends them to the admin.
    //
    // WHY ADMIN ONLY (HACKATHON SIMPLIFICATION):
    //   In production, rewards would be distributed proportionally to each
    //   LP based on their share of total liquidity. This requires tracking
    //   each user's liquidity share, implementing a reward accumulator
    //   pattern, and handling precise math. For the hackathon demo, we
    //   simply send all rewards to the admin and explain proportional
    //   distribution as "future work" in the demo video.
    //
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Claim Aave incentive rewards from both StaticAToken wrappers
    /// @dev Only callable by the contract owner/deployer (hackathon simplification)
    function claimRewards() external {
        // Only the admin can call this function
        if (msg.sender != owner) revert OnlyOwner();

        // Claim rewards from the USDe wrapper (waUSDe)
        // claimRewards(receiver) sends any accrued Aave rewards to the receiver
        waUSDe.claimRewards(owner);

        // Claim rewards from the sUSDe wrapper (wasUSDe)
        wasUSDe.claimRewards(owner);

        // Emit event for tracking
        emit RewardsClaimed(owner);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                        VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════
    //
    // Read-only helper functions for the frontend/scripts to query
    // the Vault's state without executing transactions.
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Returns all Uniswap v3 LP position IDs owned by a user
    /// @param user The address to query
    /// @return An array of NFT position IDs belonging to the user
    function getUserPositions(address user) external view returns (uint256[] memory) {
        return userPositions[user];
    }

    /// @notice Returns the number of LP positions a user has
    /// @param user The address to query
    /// @return The count of positions
    function getUserPositionCount(address user) external view returns (uint256) {
        return userPositions[user].length;
    }

    /// @notice Preview how many output tokens a user would get for a given swap
    /// @dev This is an APPROXIMATE calculation using only the Aave exchange rates.
    ///      It does NOT account for Uniswap pool slippage, price impact, or fees.
    ///      For accurate quotes, use the Uniswap API (POST /v2/quote).
    ///
    ///      Formula:
    ///      1. Convert input amount to wrapped shares: shares_in = convertToShares(amountIn)
    ///      2. Assume 1:1 swap on Uniswap (approximation for correlated pairs)
    ///      3. Convert output shares to underlying: amountOut = convertToAssets(shares_in)
    ///
    /// @param tokenIn The input token address (must be USDe or sUSDe)
    /// @param amountIn The amount of input tokens
    /// @return estimatedOut The approximate output amount (before Uniswap fees/slippage)
    function previewSwap(address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256 estimatedOut)
    {
        if (tokenIn != address(usde) && tokenIn != address(susde)) {
            revert InvalidToken();
        }

        bool isUsdeIn = (tokenIn == address(usde));
        IStaticATokenLM staticIn = isUsdeIn ? waUSDe : wasUSDe;
        IStaticATokenLM staticOut = isUsdeIn ? wasUSDe : waUSDe;

        // Step 1: How many wrapped shares would we get for the input amount?
        uint256 sharesIn = staticIn.convertToShares(amountIn);

        // Step 2: Assume ~1:1 swap ratio on Uniswap (approximation for stablecoins)
        // Step 3: Convert output shares back to underlying
        estimatedOut = staticOut.convertToAssets(sharesIn);
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ─── Uniswap v4 core ──────────────────────────────────────────────────────────
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

// ─── External ─────────────────────────────────────────────────────────────────
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticATokenLM} from "./interfaces/IStaticATokenLM.sol";

/// @title YieldHook
/// @notice Uniswap v4 hook that lets users swap and LP with underlying tokens
///         (USDC/USDT or USDe/sUSDe) while the pool internally holds
///         Aave StaticATokenLM wrappers (stataUSDC/stataUSDT).
///
/// @dev Architecture:
///   - Pool currencies: stataToken0 / stataToken1  (non-rebasing ERC-4626 shares)
///   - Users interact with: token0Underlying / token1Underlying  (e.g. USDC/USDT)
///   - This hook wraps/unwraps via Aave on every user interaction
///   - LP positions are tracked internally by positionId
///
/// @dev Uniswap v4 key concepts:
///   - All pool interactions happen inside poolManager.unlock() → unlockCallback()
///   - Flash accounting: token deltas must net to zero before unlock() returns
///   - Negative delta = you owe tokens to PoolManager  → sync → transfer → settle
///   - Positive delta = PoolManager owes you tokens    → take
///
/// @dev Hook address constraint:
///   Only the afterInitialize callback is enabled (bit 12 = 0x1000).
///   The hook contract address MUST have bit 12 set in its lower 14 bits.
///   Use HookMiner (see script/DeployYieldHook.s.sol) to find a valid CREATE2 salt.
contract YieldHook is IHooks {
    // ─── State ────────────────────────────────────────────────────────────────

    IPoolManager public immutable poolManager;

    /// @notice Underlying tokens that users deposit/receive (e.g. USDC and USDT)
    IERC20 public immutable token0Underlying;
    IERC20 public immutable token1Underlying;

    /// @notice Aave StaticATokenLM wrappers — what the Uniswap pool actually holds.
    ///         stataToken0 must correspond to token0Underlying, and its address
    ///         must be < stataToken1 (Uniswap's currency0 < currency1 requirement).
    IStaticATokenLM public immutable stataToken0;
    IStaticATokenLM public immutable stataToken1;

    /// @notice The Uniswap v4 PoolKey for the stataToken0/stataToken1 pool.
    ///         Stored when the pool is initialized (afterInitialize callback).
    PoolKey public poolKey;
    bool public poolKeySet;

    address public immutable owner;

    // ─── LP position tracking ─────────────────────────────────────────────────
    // In v4, positions are not NFTs. The hook owns all positions and tracks
    // per-user ownership internally using a positionId → Position mapping.
    // The `salt` field in ModifyLiquidityParams ensures positions at the same
    // tick range are distinct per user.

    uint256 public nextPositionId;

    struct Position {
        address user;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bytes32 salt;
    }

    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) private _userPositionIds;

    // ─── Unlock callback dispatch types ───────────────────────────────────────
    enum Op { SWAP, ADD_LIQ, REMOVE_LIQ }

    // ─── Events ───────────────────────────────────────────────────────────────
    event Swapped(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    event LiquidityAdded(address indexed user, uint256 indexed positionId, uint128 liquidity);
    event LiquidityRemoved(address indexed user, uint256 indexed positionId, uint256 amount0Out, uint256 amount1Out);
    event RewardsClaimed(address indexed admin);

    // ─── Errors ───────────────────────────────────────────────────────────────
    error InvalidToken();
    error ZeroAmount();
    error OnlyOwner();
    error TransferFailed();
    error PoolNotSet();
    error NotPositionOwner();
    error OnlyPoolManager();
    error SlippageExceeded();
    error TokensMustBeSorted();
    error HookNotImplemented();

    // ─── Constructor ──────────────────────────────────────────────────────────
    /// @param _poolManager The Uniswap v4 PoolManager
    /// @param _token0Underlying Underlying token for currency0 (e.g. USDC)
    /// @param _token1Underlying Underlying token for currency1 (e.g. USDT)
    /// @param _stataToken0 Aave StaticATokenLM wrapper for token0 — MUST be the
    ///        lower address (will be currency0 in the Uniswap pool)
    /// @param _stataToken1 Aave StaticATokenLM wrapper for token1 — MUST be the
    ///        higher address (will be currency1 in the Uniswap pool)
    constructor(
        IPoolManager _poolManager,
        address _token0Underlying,
        address _token1Underlying,
        address _stataToken0,
        address _stataToken1
    ) {
        if (_stataToken0 >= _stataToken1) revert TokensMustBeSorted();

        poolManager = _poolManager;
        token0Underlying = IERC20(_token0Underlying);
        token1Underlying = IERC20(_token1Underlying);
        stataToken0 = IStaticATokenLM(_stataToken0);
        stataToken1 = IStaticATokenLM(_stataToken1);
        owner = msg.sender;

        // Pre-approve Aave wrappers: hook deposits underlying → receives stata shares
        IERC20(_token0Underlying).approve(_stataToken0, type(uint256).max);
        IERC20(_token1Underlying).approve(_stataToken1, type(uint256).max);
    }

    // ─── Hook permissions ─────────────────────────────────────────────────────
    /// @notice Declares which hook callbacks are active.
    ///         ONLY afterInitialize is enabled — bit 12 = 0x1000.
    ///         The hook contract's address lower 14 bits must match these flags.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,     // ← used to store poolKey + approve tokens
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                          IHooks implementation
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Called by PoolManager after the pool is initialized.
    ///         Stores the PoolKey and approves stataTokens to the PoolManager
    ///         so the hook can settle token deltas during swaps and LP operations.
    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        override
        returns (bytes4)
    {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        poolKey = key;
        poolKeySet = true;

        // Approve stataTokens to PoolManager.
        // Required for the sync → transfer → settle pattern inside unlockCallback.
        IERC20(Currency.unwrap(key.currency0)).approve(address(poolManager), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).approve(address(poolManager), type(uint256).max);

        return IHooks.afterInitialize.selector;
    }

    // The following callbacks are never called (permissions set to false above).
    // They must be implemented to satisfy the IHooks interface.
    function beforeInitialize(address, PoolKey calldata, uint160)
        external pure override returns (bytes4) { revert HookNotImplemented(); }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4) { revert HookNotImplemented(); }

    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4) { revert HookNotImplemented(); }

    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external pure override returns (bytes4, BeforeSwapDelta, uint24) { revert HookNotImplemented(); }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, int128) { revert HookNotImplemented(); }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4) { revert HookNotImplemented(); }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4) { revert HookNotImplemented(); }

    // ─────────────────────────────────────────────────────────────────────────
    //                          Unlock callback
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Called by PoolManager when we call poolManager.unlock(data).
    ///         This is the only entry point for interacting with pool state.
    ///         All token deltas must net to zero before this function returns.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (Op op, bytes memory params) = abi.decode(data, (Op, bytes));
        if (op == Op.SWAP)      return _executeSwap(params);
        if (op == Op.ADD_LIQ)   return _executeAddLiquidity(params);
                                return _executeRemoveLiquidity(params);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                          SWAP
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Swap token0Underlying ↔ token1Underlying through the yield-enhanced pool.
    ///         The hook wraps input via Aave, executes the swap on the stataToken pool,
    ///         then unwraps the output back to underlying before sending to the user.
    /// @param tokenIn  Must be token0Underlying or token1Underlying
    /// @param amountIn Amount of underlying tokens to swap
    /// @param amountOutMin Minimum underlying tokens to receive (slippage protection)
    function swap(address tokenIn, uint256 amountIn, uint256 amountOutMin)
        external
        returns (uint256 amountOut)
    {
        if (tokenIn != address(token0Underlying) && tokenIn != address(token1Underlying)) revert InvalidToken();
        if (amountIn == 0) revert ZeroAmount();
        if (!poolKeySet) revert PoolNotSet();

        bool isZeroForOne = (tokenIn == address(token0Underlying));
        IERC20 underlyingIn  = isZeroForOne ? token0Underlying : token1Underlying;
        IStaticATokenLM stataIn  = isZeroForOne ? stataToken0 : stataToken1;
        IStaticATokenLM stataOut = isZeroForOne ? stataToken1 : stataToken0;

        // 1. Pull underlying from user → wrap into stataToken
        if (!underlyingIn.transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();
        uint256 wrappedIn = stataIn.deposit(amountIn, address(this));

        // 2. Execute swap inside PoolManager unlock context.
        //    The callback settles stataToken deltas with the PoolManager.
        bytes memory result = poolManager.unlock(
            abi.encode(Op.SWAP, abi.encode(isZeroForOne, wrappedIn))
        );
        uint256 wrappedOut = abi.decode(result, (uint256));

        // 3. Unwrap stataToken → underlying, send directly to user
        amountOut = stataOut.redeem(wrappedOut, msg.sender, address(this));
        if (amountOut < amountOutMin) revert SlippageExceeded();

        address tokenOut = isZeroForOne ? address(token1Underlying) : address(token0Underlying);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    function _executeSwap(bytes memory params) internal returns (bytes memory) {
        (bool zeroForOne, uint256 wrappedAmountIn) = abi.decode(params, (bool, uint256));

        // Execute the Uniswap v4 swap. amountSpecified is negative for exact-input.
        // sqrtPriceLimitX96 of MIN/MAX ensures no price limit (swap fills fully).
        BalanceDelta delta = poolManager.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(wrappedAmountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        _settleDelta(delta);

        // The output is the positive side of the delta
        uint256 wrappedOut = zeroForOne
            ? uint256(uint128(delta.amount1()))   // zeroForOne: paid token0, received token1
            : uint256(uint128(delta.amount0()));  // oneForZero: paid token1, received token0
        return abi.encode(wrappedOut);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                          ADD LIQUIDITY
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Wrap underlying tokens via Aave and add them as concentrated
    ///         liquidity to the stataToken Uniswap v4 pool.
    ///
    /// @dev `liquidity` is in Uniswap v4 liquidity units (not token amounts).
    ///      Compute off-chain using LiquidityAmounts.getLiquidityForAmounts()
    ///      from v4-periphery/src/libraries/LiquidityAmounts.sol.
    ///
    /// @param amount0Underlying Max token0Underlying to deposit (excess is refunded)
    /// @param amount1Underlying Max token1Underlying to deposit (excess is refunded)
    /// @param tickLower  Lower tick (must be a multiple of pool's tickSpacing)
    /// @param tickUpper  Upper tick (must be a multiple of pool's tickSpacing)
    /// @param liquidity  Liquidity units to add
    /// @return positionId Internal ID used to remove this position later
    function addLiquidity(
        uint256 amount0Underlying,
        uint256 amount1Underlying,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external returns (uint256 positionId) {
        if (!poolKeySet) revert PoolNotSet();
        if (liquidity == 0) revert ZeroAmount();

        // Pull + wrap both tokens
        if (amount0Underlying > 0) {
            if (!token0Underlying.transferFrom(msg.sender, address(this), amount0Underlying)) revert TransferFailed();
            stataToken0.deposit(amount0Underlying, address(this));
        }
        if (amount1Underlying > 0) {
            if (!token1Underlying.transferFrom(msg.sender, address(this), amount1Underlying)) revert TransferFailed();
            stataToken1.deposit(amount1Underlying, address(this));
        }

        positionId = nextPositionId++;
        bytes32 salt = bytes32(positionId);

        // Add liquidity inside unlock context
        poolManager.unlock(
            abi.encode(Op.ADD_LIQ, abi.encode(tickLower, tickUpper, int256(uint256(liquidity)), salt))
        );

        positions[positionId] = Position({
            user:      msg.sender,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            salt:      salt
        });
        _userPositionIds[msg.sender].push(positionId);

        // Refund any leftover stataTokens that Uniswap didn't use.
        // (v4 concentrated liquidity may not consume both tokens fully depending on price.)
        uint256 excess0 = stataToken0.balanceOf(address(this));
        uint256 excess1 = stataToken1.balanceOf(address(this));
        if (excess0 > 0) stataToken0.redeem(excess0, msg.sender, address(this));
        if (excess1 > 0) stataToken1.redeem(excess1, msg.sender, address(this));

        emit LiquidityAdded(msg.sender, positionId, liquidity);
    }

    function _executeAddLiquidity(bytes memory params) internal returns (bytes memory) {
        (int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt) =
            abi.decode(params, (int24, int24, int256, bytes32));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower:      tickLower,
                tickUpper:      tickUpper,
                liquidityDelta: liquidityDelta,
                salt:           salt
            }),
            ""
        );

        // Settle the tokens owed to the pool (both amounts will be negative)
        _settleDelta(delta);

        uint256 used0 = delta.amount0() < 0 ? uint256(uint128(-delta.amount0())) : 0;
        uint256 used1 = delta.amount1() < 0 ? uint256(uint128(-delta.amount1())) : 0;
        return abi.encode(used0, used1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                          REMOVE LIQUIDITY
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Remove liquidity from a position, unwrap stataTokens, and return
    ///         underlying tokens to the user (including any accrued swap fees).
    /// @param positionId The ID returned by addLiquidity
    function removeLiquidity(uint256 positionId) external {
        Position storage pos = positions[positionId];
        if (pos.user != msg.sender) revert NotPositionOwner();
        if (!poolKeySet) revert PoolNotSet();

        bytes memory result = poolManager.unlock(
            abi.encode(Op.REMOVE_LIQ, abi.encode(
                pos.tickLower,
                pos.tickUpper,
                -int256(uint256(pos.liquidity)),
                pos.salt
            ))
        );
        (uint256 received0, uint256 received1) = abi.decode(result, (uint256, uint256));

        // Unwrap stataTokens → underlying and send to user.
        // The user receives more underlying than they deposited if:
        //   a) Aave yield accrued (stataToken share price increased)
        //   b) Swap fees were earned (collected during removeLiquidity)
        uint256 out0 = received0 > 0 ? stataToken0.redeem(received0, msg.sender, address(this)) : 0;
        uint256 out1 = received1 > 0 ? stataToken1.redeem(received1, msg.sender, address(this)) : 0;

        pos.liquidity = 0;
        emit LiquidityRemoved(msg.sender, positionId, out0, out1);
    }

    function _executeRemoveLiquidity(bytes memory params) internal returns (bytes memory) {
        (int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt) =
            abi.decode(params, (int24, int24, int256, bytes32));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower:      tickLower,
                tickUpper:      tickUpper,
                liquidityDelta: liquidityDelta,
                salt:           salt
            }),
            ""
        );

        // Pool owes us tokens (positive deltas) — take them
        _settleDelta(delta);

        uint256 received0 = delta.amount0() > 0 ? uint256(uint128(delta.amount0())) : 0;
        uint256 received1 = delta.amount1() > 0 ? uint256(uint128(delta.amount1())) : 0;
        return abi.encode(received0, received1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                          CLAIM AAVE REWARDS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Claim Aave liquidity mining rewards from both stataToken wrappers.
    /// @dev Only callable by owner. In production this would distribute rewards
    ///      proportionally to LPs — for now they go to the admin.
    function claimRewards() external {
        if (msg.sender != owner) revert OnlyOwner();
        stataToken0.claimRewards(owner, new address[](0));
        stataToken1.claimRewards(owner, new address[](0));
        emit RewardsClaimed(owner);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                          VIEW HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    function getUserPositions(address user) external view returns (uint256[] memory) {
        return _userPositionIds[user];
    }

    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                          INTERNAL: SETTLE DELTA
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Resolves a BalanceDelta with the PoolManager.
    ///
    ///   Negative amount = hook owes the pool  → sync → transfer ERC-20 → settle
    ///   Positive amount = pool owes the hook  → take
    ///
    ///   This hook always holds stataTokens inside the unlock context.
    ///   The stataTokens were approved to poolManager in afterInitialize.
    function _settleDelta(BalanceDelta delta) internal {
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();

        if (d0 < 0) {
            uint256 owed = uint256(uint128(-d0));
            poolManager.sync(poolKey.currency0);
            IERC20(Currency.unwrap(poolKey.currency0)).transfer(address(poolManager), owed);
            poolManager.settle();
        } else if (d0 > 0) {
            poolManager.take(poolKey.currency0, address(this), uint256(uint128(d0)));
        }

        if (d1 < 0) {
            uint256 owed = uint256(uint128(-d1));
            poolManager.sync(poolKey.currency1);
            IERC20(Currency.unwrap(poolKey.currency1)).transfer(address(poolManager), owed);
            poolManager.settle();
        } else if (d1 > 0) {
            poolManager.take(poolKey.currency1, address(this), uint256(uint128(d1)));
        }
    }
}

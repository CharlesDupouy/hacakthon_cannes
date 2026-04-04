// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {YieldHook} from "../src/YieldHook.sol";

/// @notice Adds 100 USDC + 100 USDT as full-range liquidity through the YieldHook.
///         Reads the current pool sqrtPrice from PoolManager and computes the
///         optimal liquidity units via LiquidityAmounts.getLiquidityForAmounts().
///
/// HOW TO RUN:
///   source .env
///   forge script script/AddLiquidityV4.s.sol \
///     --rpc-url $BASE_SEPOLIA_RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract AddLiquidityV4 is Script {
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address constant USDC         = 0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f;
    address constant USDT         = 0x0a215D8ba66387DCA84B284D18c3B4ec3de6E54a;
    address constant STATA_USDC   = 0xf430cb6E2b85f99222fBFA6dFEa18Ff60FA6B32a;
    address constant STATA_USDT   = 0xf63dA51069FAe9448747FA425F8Cb84B0149eC0F;

    uint256 constant AMOUNT_USDC = 100 * 1e6;
    uint256 constant AMOUNT_USDT = 100 * 1e6;

    // Full range for 0.05% fee (tick spacing = 10)
    int24 constant TICK_LOWER = -887270;
    int24 constant TICK_UPPER =  887270;
    uint24 constant FEE        = 500;
    int24 constant TICK_SPACING = 10;

    function run() external {
        address hookAddress = vm.envAddress("YIELD_HOOK_ADDRESS");
        require(hookAddress != address(0), "Set YIELD_HOOK_ADDRESS in .env");

        // Read current pool sqrtPrice to compute liquidity
        IPoolManager poolManager = IPoolManager(POOL_MANAGER);
        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(STATA_USDC),
            currency1:   Currency.wrap(STATA_USDT),
            fee:         FEE,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(hookAddress)
        });

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        require(sqrtPriceX96 != 0, "Pool not initialized, run InitializePool.s.sol first");

        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);

        // The pool holds stataTokens, so liquidity must be computed from stata amounts.
        // stataUSDC has a higher liquidityIndex (~1.24) so 100 USDC -> ~80 stataUSDC.
        // Using underlying amounts directly would cause the hook to ask the pool for more
        // stataTokens than it has, causing an ERC20InsufficientBalance revert.
        uint256 stataAmount0 = IERC4626(STATA_USDC).previewDeposit(AMOUNT_USDC);
        uint256 stataAmount1 = IERC4626(STATA_USDT).previewDeposit(AMOUNT_USDT);
        console.log("Expected stataUSDC from 100 USDC:", stataAmount0);
        console.log("Expected stataUSDT from 100 USDT:", stataAmount1);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceLower,
            sqrtPriceUpper,
            stataAmount0,
            stataAmount1
        );

        require(liquidity > 0, "Computed liquidity is zero");
        console.log("Computed liquidity:", uint256(liquidity));

        vm.startBroadcast();

        // Approve hook to pull both tokens
        IERC20(USDC).approve(hookAddress, AMOUNT_USDC);
        IERC20(USDT).approve(hookAddress, AMOUNT_USDT);

        // Add liquidity: hook wraps to stata, adds to pool
        uint256 positionId = YieldHook(hookAddress).addLiquidity(
            AMOUNT_USDC,
            AMOUNT_USDT,
            TICK_LOWER,
            TICK_UPPER,
            liquidity
        );

        vm.stopBroadcast();

        console.log("-- YieldHook v4 Add Liquidity --");
        console.log("Position ID:", positionId);
        console.log("Liquidity:  ", uint256(liquidity));
        console.log("USDC deposited: 100 (some may be refunded)");
        console.log("USDT deposited: 100 (some may be refunded)");
        console.log("LPs now earn: Uniswap swap fees + Aave lending yield");
    }
}

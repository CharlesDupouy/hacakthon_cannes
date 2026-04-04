// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Initializes the stataUSDC/stataUSDT Uniswap v4 pool with the YieldHook.
///
/// PREREQUISITES:
///   - YieldHook is deployed (YIELD_HOOK_ADDRESS in .env)
///
/// HOW TO RUN:
///   source .env
///   forge script script/InitializePool.s.sol \
///     --rpc-url $BASE_SEPOLIA_RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
///
/// AFTER RUNNING:
///   The pool is initialized. You can now call:
///   - YieldHook.addLiquidity() to add LP positions
///   - YieldHook.swap() to swap USDC <> USDT
contract InitializePool is Script {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address constant STATA_USDC   = 0xf430cb6E2b85f99222fBFA6dFEa18Ff60FA6B32a; // currency0
    address constant STATA_USDT   = 0xf63dA51069FAe9448747FA425F8Cb84B0149eC0F; // currency1

    // Fee tiers: 100=0.01%, 500=0.05%, 3000=0.3%, 10000=1%
    // For correlated stablecoins, 500 (0.05%) is appropriate
    uint24 constant FEE = 500;

    // Tick spacing for 500 fee tier is 10
    int24 constant TICK_SPACING = 10;

    // Initial price: 1:1 (both stablecoins ≈ $1)
    // sqrtPriceX96 = sqrt(1) * 2^96 = 79228162514264337593543950336
    uint160 constant INITIAL_SQRT_PRICE = 79228162514264337593543950336;

    function run() external {
        address hookAddress = vm.envAddress("YIELD_HOOK_ADDRESS");
        require(hookAddress != address(0), "Set YIELD_HOOK_ADDRESS in .env");

        vm.startBroadcast();

        IPoolManager poolManager = IPoolManager(POOL_MANAGER);

        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(STATA_USDC),
            currency1:   Currency.wrap(STATA_USDT),
            fee:         FEE,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(hookAddress)
        });

        // Initialize the pool. This triggers afterInitialize on the hook,
        // which stores the PoolKey and approves stataTokens to the PoolManager.
        int24 tick = poolManager.initialize(key, INITIAL_SQRT_PRICE);

        PoolId poolId = key.toId();
        console.log("Pool initialized!");
        console.log("Tick at initialization:", tick);
        console.log("Pool ID:", uint256(PoolId.unwrap(poolId)));
        console.log("Hook address:", hookAddress);
        console.log("");
        console.log("PoolKey details:");
        console.log("  currency0 (stataUSDC):", STATA_USDC);
        console.log("  currency1 (stataUSDT):", STATA_USDT);
        console.log("  fee:", FEE);
        console.log("  tickSpacing:", TICK_SPACING);

        vm.stopBroadcast();
    }
}

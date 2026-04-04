// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "../lib/forge-std/src/Script.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface INonfungiblePositionManager {
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);
}

/// @notice Creates the Uniswap v3 pool on Base Sepolia using real Aave stata tokens.
///         No mock deployments needed — Aave v3 is live on Base Sepolia.
contract DeployPool is Script {
    // Real Aave v3 StaticATokenLM on Base Sepolia
    address constant STATA_USDC = 0xf430cb6E2b85f99222fBFA6dFEa18Ff60FA6B32a; // stataUSDC
    address constant STATA_USDT = 0xf63dA51069FAe9448747FA425F8Cb84B0149eC0F; // stataUSDT

    // Uniswap v3 on Base Sepolia
    address constant POSITION_MANAGER = 0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2;

    // 1:1 price (USDC ≈ USDT), sqrt(1) * 2^96
    uint160 constant SQRT_PRICE_1_TO_1 = 79228162514264337593543950336;

    // 0.05% fee tier — best for stablecoin pairs
    uint24 constant FEE = 500;

    function run() external {
        vm.startBroadcast();

        // Uniswap requires token0 < token1 by address
        (address token0, address token1) = STATA_USDC < STATA_USDT
            ? (STATA_USDC, STATA_USDT)
            : (STATA_USDT, STATA_USDC);

        address pool = INonfungiblePositionManager(POSITION_MANAGER)
            .createAndInitializePoolIfNecessary(token0, token1, FEE, SQRT_PRICE_1_TO_1);

        vm.stopBroadcast();

        console.log("token0:     ", token0);
        console.log("token1:     ", token1);
        console.log("Pool:       ", pool);
        console.log("Fee tier:    0.05% (500)");
    }
}

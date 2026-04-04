// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldHook} from "../src/YieldHook.sol";

/// @notice Removes liquidity from a YieldHook v4 position.
///         The hook unwraps stataTokens → underlying before returning funds.
///         The returned amount will exceed the original deposit if:
///           - Swap fees were earned while in range
///           - Aave yield accrued on the stataToken share price
///
/// HOW TO RUN:
///   source .env
///   POSITION_ID=0   # replace with the ID from AddLiquidityV4
///   forge script script/RemoveLiquidityV4.s.sol \
///     --rpc-url $BASE_SEPOLIA_RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract RemoveLiquidityV4 is Script {
    address constant USDC = 0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f;
    address constant USDT = 0x0a215D8ba66387DCA84B284D18c3B4ec3de6E54a;

    function run() external {
        address hookAddress = vm.envAddress("YIELD_HOOK_ADDRESS");
        require(hookAddress != address(0), "Set YIELD_HOOK_ADDRESS in .env");

        uint256 positionId = vm.envUint("POSITION_ID");

        uint256 usdcBefore = IERC20(USDC).balanceOf(msg.sender);
        uint256 usdtBefore = IERC20(USDT).balanceOf(msg.sender);

        vm.startBroadcast();

        // Remove liquidity: hook takes stataTokens from pool, unwraps to underlying
        YieldHook(hookAddress).removeLiquidity(positionId);

        vm.stopBroadcast();

        uint256 usdcAfter = IERC20(USDC).balanceOf(msg.sender);
        uint256 usdtAfter = IERC20(USDT).balanceOf(msg.sender);

        console.log("-- YieldHook v4 Remove Liquidity --");
        console.log("Position ID:", positionId);
        console.log("USDC received:", usdcAfter - usdcBefore, "(raw, divide by 1e6)");
        console.log("USDT received:", usdtAfter - usdtBefore, "(raw, divide by 1e6)");
    }
}

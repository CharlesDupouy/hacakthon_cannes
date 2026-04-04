// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {YieldHook} from "../src/YieldHook.sol";

/// @notice Deploys YieldHook on Base Sepolia using CREATE2 to get the right hook address.
///
/// WHY CREATE2?
///   Uniswap v4 encodes hook permissions in the contract address itself.
///   The lower 14 bits of the address must match the permission flags.
///   YieldHook only enables afterInitialize (bit 12 = 0x1000).
///   We brute-force a CREATE2 salt until we find an address with bit 12 set.
///
/// HOW TO RUN:
///   source .env
///   forge script script/DeployYieldHook.s.sol \
///     --rpc-url $BASE_SEPOLIA_RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
///
/// AFTER DEPLOYMENT:
///   Copy the deployed hook address to .env as YIELD_HOOK_ADDRESS.
///   Then run InitializePool.s.sol to create the pool.
contract DeployYieldHook is Script {
    // ─── Base Sepolia addresses ────────────────────────────────────────────────
    address constant POOL_MANAGER    = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    // Aave v3 Base Sepolia — underlying tokens
    address constant USDC            = 0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f;
    address constant USDT            = 0x0a215D8ba66387DCA84B284D18c3B4ec3de6E54a;

    // Aave v3 Base Sepolia — StaticATokenLM wrappers
    // NOTE: stataUSDC address (0xf430...) < stataUSDT address (0xf63d...)
    //       so stataUSDC = currency0, stataUSDT = currency1
    address constant STATA_USDC      = 0xf430cb6E2b85f99222fBFA6dFEa18Ff60FA6B32a;
    address constant STATA_USDT      = 0xf63dA51069FAe9448747FA425F8Cb84B0149eC0F;

    // ─── Permission flag ──────────────────────────────────────────────────────
    // afterInitialize only → bit 12
    uint160 constant HOOK_FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG);

    function run() external {
        vm.startBroadcast();

        // Mine a CREATE2 salt that produces a hook address with the right permission bits.
        // The deployer of a CREATE2 contract is the tx origin (msg.sender in the script).
        address deployer = msg.sender;
        bytes memory creationCode = type(YieldHook).creationCode;
        bytes memory constructorArgs = abi.encode(
            IPoolManager(POOL_MANAGER),
            USDC,
            USDT,
            STATA_USDC,
            STATA_USDT
        );
        bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);

        (address hookAddress, bytes32 salt) = _mineAddress(deployer, initCode, HOOK_FLAGS);
        console.log("Mined hook address:", hookAddress);
        console.log("Salt:", uint256(salt));

        // Deploy using the mined salt
        YieldHook hook = new YieldHook{salt: salt}(
            IPoolManager(POOL_MANAGER),
            USDC,
            USDT,
            STATA_USDC,
            STATA_USDT
        );

        require(address(hook) == hookAddress, "Address mismatch, salt incorrect");
        console.log("YieldHook deployed at:", address(hook));
        console.log("Pool will use currencies:");
        console.log("  currency0 (stataUSDC):", STATA_USDC);
        console.log("  currency1 (stataUSDT):", STATA_USDT);

        vm.stopBroadcast();
    }

    /// @dev Brute-forces a CREATE2 salt until the resulting address has
    ///      the required hook permission bits in its lower 14 bits.
    function _mineAddress(address deployer, bytes memory initCode, uint160 flags)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(initCode);
        uint256 nonce = 0;

        while (true) {
            salt = bytes32(nonce);
            hookAddress = _computeCreate2Address(deployer, salt, initCodeHash);

            // Check if lower 14 bits match required flags
            if (uint160(hookAddress) & 0x3FFF == flags & 0x3FFF) {
                break;
            }
            nonce++;

            // Safety limit — should find a match well before this
            require(nonce < 200_000, "Could not mine a valid hook address");
        }
    }

    function _computeCreate2Address(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            deployer,
            salt,
            initCodeHash
        )))));
    }
}

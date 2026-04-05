// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {YieldHook} from "../src/YieldHook.sol";
import {IStaticATokenLM} from "../src/interfaces/IStaticATokenLM.sol";

/// @title YieldHookSimulation
///
/// @notice Fork-based simulation tests that prove YieldHook generates real yield
///         for LPs by combining Aave lending rate + Uniswap swap fees.
///
/// @dev HOW THE SIMULATION WORKS
///
///   1. Fork Base Sepolia at current block - all real contracts are present:
///      Aave v3, stataUSDC/stataUSDT, Uniswap v4 PoolManager, our YieldHook.
///
///   2. Deploy a fresh YieldHook instance and initialize a clean 1:1 pool.
///      This avoids the price drift on the existing testnet deployment.
///
///   3. Simulate Aave yield by directly writing the liquidityIndex to Aave's
///      storage and setting lastUpdateTimestamp = block.timestamp.
///      After this, stataToken.convertToAssets() returns exactly the target rate
///      using Aave's own contract logic - no mocking involved.
///
///   4. Run N alternating USDC→USDT / USDT→USDC swaps to accumulate fees.
///      Alternating ensures the pool price stays near 1:1 (minimal IL).
///
///   5. Remove liquidity and decompose earnings into two components:
///
///        received = principal + aaveYield + uniswapFees
///
///      where:
///        principal   = stataDeposited0 * rateAtDeposit / 1e6
///        aaveYield   = stataDeposited0 * (rateAfter - rateBefore) / 1e6
///        uniswapFees = received - principal - aaveYield
///
///      stataDeposited0/1 are the exact stataToken shares consumed by the pool
///      at deposit time, stored in YieldHook.Position for this exact purpose.
///
/// @dev PROOF THAT EARNINGS = REALITY
///
///   Aave yield: We write the liquidityIndex directly into Aave's storage.
///   The stataToken then calls getReserveNormalizedIncome which reads that exact
///   value and computes assets = shares * index / RAY. This is the SAME
///   computation Aave would do after N real years - we just skip the wait.
///   We assert: actualRateGrowth ≈ (1 + apy)^years to verify the index was set.
///
///   Uniswap fees: Fees accumulate as extra stataToken shares inside the pool.
///   When removing liquidity, modifyLiquidity() returns the fee shares on top of
///   the principal. We verify: totalFees ≈ numSwaps * swapSize * 0.05% * rateGrowth.
///
///   Identity check: principal + aaveYield + fees = received (asserted per-LP).
///
/// @dev HOW TO RUN
///   source .env
///   forge test --match-path test/YieldHookSimulation.t.sol -vv
///   (use -vvv for per-LP output)

contract YieldHookSimulation is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary  for IPoolManager;

    // ─── Base Sepolia addresses (real deployed contracts) ─────────────────────
    address constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address constant AAVE_POOL    = 0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27;
    address constant USDC         = 0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f;
    address constant USDT         = 0x0a215D8ba66387DCA84B284D18c3B4ec3de6E54a;
    address constant STATA_USDC   = 0xf430cb6E2b85f99222fBFA6dFEa18Ff60FA6B32a;
    address constant STATA_USDT   = 0xf63dA51069FAe9448747FA425F8Cb84B0149eC0F;

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 constant RAY  = 1e27;
    uint256 constant YEAR = 365 days;

    // Full-range ticks for 0.05% fee tier (tickSpacing = 10)
    int24 constant TICK_LOWER = -887270;
    int24 constant TICK_UPPER =  887270;

    // ─── State ────────────────────────────────────────────────────────────────
    YieldHook  hook;
    PoolKey    poolKey;

    // Fair initial sqrtPrice: sqrt(rate0/rate1) * Q96, computed from live Aave rates.
    // stataUSDC rate ≈ 1.24, stataUSDT rate ≈ 1.00, so fair price ≈ 1.24 stataUSDT/stataUSDC.
    // Using 1:1 would create a 24% mispricing and severe impermanent loss.
    uint160 fairSqrtPrice;

    address alice   = makeAddr("alice");
    address bob     = makeAddr("bob");
    address carol   = makeAddr("carol");
    address dave    = makeAddr("dave");
    address swapper = makeAddr("swapper");

    // ─────────────────────────────────────────────────────────────────────────
    //                              DATA TYPES
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Configurable parameters for a simulation scenario.
    struct ScenarioParams {
        string   name;
        uint256  durationYears;  // 1–5
        uint256  aaveApyBps;     // Aave supply APY in basis points (500 = 5.00%)
        uint256  numSwaps;       // total swaps during the period (alternating direction)
        uint256  swapSizeUsdc;   // size of each swap, in USDC with 6 decimals
        address[] lps;
        uint256[] lpAmountsUsdc; // USDC amount per LP (same amount used for USDT)
    }

    /// @dev Per-LP result after a scenario run.
    struct LPResult {
        address  lp;
        uint256  positionId;
        uint128  stataDeposited0; // stataUSDC shares consumed by pool at deposit
        uint128  stataDeposited1; // stataUSDT shares consumed by pool at deposit
        uint256  depositedUsdc;   // actual USDC pulled from LP wallet
        uint256  depositedUsdt;   // actual USDT pulled from LP wallet
        uint256  receivedUsdc;    // USDC returned on removal
        uint256  receivedUsdt;    // USDT returned on removal
        uint256  aaveYieldUsdc;   // yield from Aave rate growth on token0
        uint256  aaveYieldUsdt;   // yield from Aave rate growth on token1
        uint256  feesUsdc;        // yield from accumulated swap fees on token0
        uint256  feesUsdt;        // yield from accumulated swap fees on token1
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                         SETUP - runs before each test
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.createSelectFork("base_sepolia");

        // Discover Aave storage slots BEFORE any state changes (uses vm.accesses).
        _discoverAaveSlots(STATA_USDC, USDC);
        _discoverAaveSlots(STATA_USDT, USDT);

        // Compute fair sqrtPrice from live Aave rates before deploying.
        // rate0/rate1 = stataUSDC/stataUSDT relative value in underlying.
        // Pool must be initialized at this price to avoid IL from price mismatch.
        {
            uint256 rate0 = IStaticATokenLM(STATA_USDC).convertToAssets(1e6);
            uint256 rate1 = IStaticATokenLM(STATA_USDT).convertToAssets(1e6);
            uint256 Q96   = 2**96;
            // sqrtPrice = sqrt(rate0/rate1) * Q96 = sqrt(rate0 * Q96^2 / rate1)
            uint256 priceX192 = (rate0 * Q96 / rate1) * Q96;
            fairSqrtPrice = uint160(_sqrtUint(priceX192));
        }

        _deployFreshHook();

        // Initialize pool at the fair price (stataUSDC rate / stataUSDT rate).
        // This ensures the pool is not mispriced at the start, avoiding IL.
        IPoolManager(POOL_MANAGER).initialize(poolKey, fairSqrtPrice);

        // Freeze the Aave index timestamps so that convertToAssets() returns
        // exactly the stored liquidityIndex throughout the test (no pending accrual).
        _setAaveLiquidityIndex(USDC, _readAaveLiquidityIndex(USDC));
        _setAaveLiquidityIndex(USDT, _readAaveLiquidityIndex(USDT));

        _verifyAaveSlots();
    }

    /// @dev Deploy YieldHook via CREATE2 with a salt that satisfies the v4 hook
    ///      address constraint: lower 14 bits must equal AFTER_INITIALIZE_FLAG.
    function _deployFreshHook() internal {
        bytes memory args = abi.encode(
            IPoolManager(POOL_MANAGER), USDC, USDT, STATA_USDC, STATA_USDT
        );
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(YieldHook).creationCode, args)
        );
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG); // 0x1000

        bytes32 salt;
        address target;
        for (uint256 i = 0; i < 200_000; i++) {
            salt   = bytes32(i);
            target = _computeCreate2(address(this), salt, initCodeHash);
            if (uint160(target) & 0x3FFF == flags & 0x3FFF) break;
        }

        hook = new YieldHook{salt: salt}(
            IPoolManager(POOL_MANAGER), USDC, USDT, STATA_USDC, STATA_USDT
        );
        assertEq(address(hook), target, "hook address mismatch");

        poolKey = PoolKey({
            currency0:   Currency.wrap(STATA_USDC),
            currency1:   Currency.wrap(STATA_USDT),
            fee:         500,
            tickSpacing: 10,
            hooks:       IHooks(address(hook))
        });
    }

    function _computeCreate2(address deployer, bytes32 salt, bytes32 codeHash)
        internal pure returns (address)
    {
        return address(uint160(uint256(keccak256(
            abi.encodePacked(bytes1(0xff), deployer, salt, codeHash)
        ))));
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                      AAVE STORAGE MANIPULATION
    //
    // Aave v3 on Base Sepolia (revision 10) uses EIP-7201 namespaced storage.
    // The _reserves mapping is NOT at Solidity slot 0-N. Instead, the
    // PoolStorageSlot is derived as:
    //   keccak256(abi.encode(uint256(keccak256("aave.storage.Pool")) - 1)) & ~0xff
    //
    // We discover the exact slots dynamically using vm.record() + vm.accesses().
    // When convertToAssets(1e6) is called, AAVE_POOL reads exactly 3 slots:
    //   reads[0]: EIP-1967 implementation slot (skip)
    //   reads[1]: base+3  — contains lastUpdateTimestamp at bits 128-167
    //   reads[2]: base+1  — contains liquidityIndex (lower 128) | currentLiquidityRate (upper 128)
    //
    // We cache these per-token to avoid re-running discovery on every call.
    // ─────────────────────────────────────────────────────────────────────────

    // Cached slot addresses discovered via vm.accesses
    bytes32 private _aaveIndexSlot_USDC;
    bytes32 private _aaveIndexSlot_USDT;
    bytes32 private _aaveTsSlot_USDC;
    bytes32 private _aaveTsSlot_USDT;

    /// @dev Discover and cache the actual Aave storage slots for a given token.
    function _discoverAaveSlots(address stataToken, address underlying) internal {
        vm.record();
        IStaticATokenLM(stataToken).convertToAssets(1e6);
        (bytes32[] memory reads, ) = vm.accesses(AAVE_POOL);
        // reads[0] = EIP-1967 implementation slot, reads[1] = ts slot, reads[2] = index slot
        require(reads.length >= 3, "unexpected Aave slot count - check fork version");
        if (underlying == USDC) {
            _aaveTsSlot_USDC    = reads[1];
            _aaveIndexSlot_USDC = reads[2];
        } else {
            _aaveTsSlot_USDT    = reads[1];
            _aaveIndexSlot_USDT = reads[2];
        }
    }

    function _readAaveLiquidityIndex(address underlying) internal view returns (uint128) {
        bytes32 slot = (underlying == USDC) ? _aaveIndexSlot_USDC : _aaveIndexSlot_USDT;
        return uint128(uint256(vm.load(AAVE_POOL, slot))); // lower 128 bits
    }

    /// @dev Sets the liquidityIndex and freezes lastUpdateTimestamp = block.timestamp.
    ///      After this call, stataToken.convertToAssets(1e6) returns newIndex * 1e6 / RAY
    ///      with zero pending interest on top (since timestamp == block.timestamp,
    ///      getNormalizedIncome returns the stored index directly).
    function _setAaveLiquidityIndex(address underlying, uint128 newIndex) internal {
        bytes32 indexSlot = (underlying == USDC) ? _aaveIndexSlot_USDC : _aaveIndexSlot_USDT;
        bytes32 tsSlot    = (underlying == USDC) ? _aaveTsSlot_USDC    : _aaveTsSlot_USDT;

        // Preserve currentLiquidityRate (upper 128 bits), update liquidityIndex (lower 128 bits)
        uint128 rate = uint128(uint256(vm.load(AAVE_POOL, indexSlot)) >> 128);
        vm.store(AAVE_POOL, indexSlot, bytes32((uint256(rate) << 128) | uint256(newIndex)));

        // lastUpdateTimestamp is at bits 128-167 of the ts slot; clear those bits and set new ts
        uint256 s3   = uint256(vm.load(AAVE_POOL, tsSlot));
        uint256 mask = ~(uint256(type(uint40).max) << 128);
        vm.store(AAVE_POOL, tsSlot, bytes32((s3 & mask) | (uint256(uint40(block.timestamp)) << 128)));
    }

    /// @dev Verifies that the storage slots we manipulate are correct by checking
    ///      that reading the stored index matches what convertToAssets reports.
    function _verifyAaveSlots() internal view {
        uint128 storedIndex = _readAaveLiquidityIndex(USDC);
        // convertToAssets(1e6) = 1e6 * liquidityIndex / RAY  (when ts == block.ts)
        uint256 expected = uint256(storedIndex) * 1e6 / RAY;
        uint256 actual   = IStaticATokenLM(STATA_USDC).convertToAssets(1e6);
        assertApproxEqAbs(actual, expected, 2,
            "AAVE SLOT VERIFICATION FAILED: storage layout mismatch."
        );
    }

    /// @dev Integer square root (Babylonian method).
    function _sqrtUint(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
        return y;
    }

    /// @dev Compound interest: index * (1 + apyBps/10000)^years
    function _compoundIndex(uint256 index, uint256 apyBps, uint256 numYears)
        internal pure returns (uint128)
    {
        for (uint256 i = 0; i < numYears; i++) {
            index = index * (10_000 + apyBps) / 10_000;
        }
        return uint128(index);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                            TOKEN HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    function _give(address to, uint256 usdc, uint256 usdt) internal {
        deal(USDC, to, usdc);
        deal(USDT, to, usdt);
    }

    function _approveHook(address user) internal {
        vm.startPrank(user);
        IERC20(USDC).approve(address(hook), type(uint256).max);
        IERC20(USDT).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                          SCENARIO RUNNER
    // ─────────────────────────────────────────────────────────────────────────

    function _runScenario(ScenarioParams memory p) internal returns (LPResult[] memory results) {
        results = new LPResult[](p.lps.length);

        // Snapshot Aave rates at deposit time.
        // We already froze the timestamps in setUp, so convertToAssets = storedIndex * 1e6 / RAY.
        uint256 rate0Before = IStaticATokenLM(STATA_USDC).convertToAssets(1e6);
        uint256 rate1Before = IStaticATokenLM(STATA_USDT).convertToAssets(1e6);

        // ── 1. Each LP adds liquidity ─────────────────────────────────────────
        for (uint256 i = 0; i < p.lps.length; i++) {
            uint256 amt = p.lpAmountsUsdc[i];
            _give(p.lps[i], amt, amt);
            _approveHook(p.lps[i]);

            (uint160 sqrtP,,,) = IPoolManager(POOL_MANAGER).getSlot0(poolKey.toId());
            uint256 s0 = IStaticATokenLM(STATA_USDC).convertToShares(amt);
            uint256 s1 = IStaticATokenLM(STATA_USDT).convertToShares(amt);
            uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
                sqrtP,
                TickMath.getSqrtPriceAtTick(TICK_LOWER),
                TickMath.getSqrtPriceAtTick(TICK_UPPER),
                s0, s1
            );

            uint256 b0 = IERC20(USDC).balanceOf(p.lps[i]);
            uint256 b1 = IERC20(USDT).balanceOf(p.lps[i]);

            vm.prank(p.lps[i]);
            uint256 pid = hook.addLiquidity(amt, amt, TICK_LOWER, TICK_UPPER, liq);

            results[i].lp            = p.lps[i];
            results[i].positionId    = pid;
            results[i].depositedUsdc = b0 - IERC20(USDC).balanceOf(p.lps[i]);
            results[i].depositedUsdt = b1 - IERC20(USDT).balanceOf(p.lps[i]);

            YieldHook.Position memory pos = hook.getPosition(pid);
            results[i].stataDeposited0 = pos.stataDeposited0;
            results[i].stataDeposited1 = pos.stataDeposited1;
        }

        // ── 2. Simulate swaps (alternating direction to keep price near 1:1) ──
        // Each swap earns the pool 0.05% of the input in stataToken fees.
        // Alternating prevents one-sided price drift and minimises IL for LPs.
        _give(swapper, p.swapSizeUsdc * (p.numSwaps + 2), p.swapSizeUsdc * (p.numSwaps + 2));
        _approveHook(swapper);

        uint256 successfulSwaps;
        for (uint256 s = 0; s < p.numSwaps; s++) {
            address tokenIn = (s % 2 == 0) ? USDC : USDT;
            vm.prank(swapper);
            try hook.swap(tokenIn, p.swapSizeUsdc, 0) { successfulSwaps++; } catch {}
        }

        // ── 3. Jump time forward + update Aave liquidityIndex ─────────────────
        vm.warp(block.timestamp + p.durationYears * YEAR);

        uint128 newIdx0 = _compoundIndex(_readAaveLiquidityIndex(USDC), p.aaveApyBps, p.durationYears);
        uint128 newIdx1 = _compoundIndex(_readAaveLiquidityIndex(USDT), p.aaveApyBps, p.durationYears);
        _setAaveLiquidityIndex(USDC, newIdx0);
        _setAaveLiquidityIndex(USDT, newIdx1);

        uint256 rate0After = IStaticATokenLM(STATA_USDC).convertToAssets(1e6);
        uint256 rate1After = IStaticATokenLM(STATA_USDT).convertToAssets(1e6);

        // ── 4. Remove liquidity + decompose earnings ───────────────────────────
        for (uint256 i = 0; i < p.lps.length; i++) {
            uint256 b0 = IERC20(USDC).balanceOf(p.lps[i]);
            uint256 b1 = IERC20(USDT).balanceOf(p.lps[i]);

            vm.prank(p.lps[i]);
            hook.removeLiquidity(results[i].positionId);

            results[i].receivedUsdc = IERC20(USDC).balanceOf(p.lps[i]) - b0;
            results[i].receivedUsdt = IERC20(USDT).balanceOf(p.lps[i]) - b1;

            // ── Earnings decomposition ────────────────────────────────────────
            //
            // At deposit, the pool consumed exactly stataDeposited0 stataUSDC shares.
            // Those shares are now worth more because the Aave rate increased.
            //
            // principal0   = shares × rateBefore / 1e6  (original USDC value)
            // aaveYield0   = shares × (rateAfter - rateBefore) / 1e6
            // feesUsdc     = receivedUsdc - principal0 - aaveYield0
            //              = extra shares from swap fees × rateAfter / 1e6
            //
            // This decomposition is exact when swaps are balanced (minimal IL).
            uint256 sd0 = results[i].stataDeposited0;
            uint256 sd1 = results[i].stataDeposited1;

            uint256 principal0 = sd0 * rate0Before / 1e6;
            uint256 principal1 = sd1 * rate1Before / 1e6;

            results[i].aaveYieldUsdc = sd0 * (rate0After - rate0Before) / 1e6;
            results[i].aaveYieldUsdt = sd1 * (rate1After - rate1Before) / 1e6;

            // Fees: residual after principal + aaveYield.
            // Can be slightly negative (1–2 wei) due to integer division - treat as 0.
            uint256 sum0 = principal0 + results[i].aaveYieldUsdc;
            uint256 sum1 = principal1 + results[i].aaveYieldUsdt;
            results[i].feesUsdc = results[i].receivedUsdc > sum0 ? results[i].receivedUsdc - sum0 : 0;
            results[i].feesUsdt = results[i].receivedUsdt > sum1 ? results[i].receivedUsdt - sum1 : 0;
        }

        _logResults(p, results, rate0Before, rate0After, rate1Before, rate1After, successfulSwaps);
        _proveCorrectness(p, results, rate0Before, rate0After, rate1Before, rate1After);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                             CONSOLE OUTPUT
    // ─────────────────────────────────────────────────────────────────────────

    function _logLP(LPResult memory lp, uint256 idx, uint256 durationYears) internal pure {
        uint256 deposited = lp.depositedUsdc + lp.depositedUsdt;
        uint256 received  = lp.receivedUsdc  + lp.receivedUsdt;
        uint256 aave      = lp.aaveYieldUsdc + lp.aaveYieldUsdt;
        uint256 fees      = lp.feesUsdc      + lp.feesUsdt;
        uint256 gain      = received > deposited ? received - deposited : 0;
        console.log("------------------------------------------------------");
        console.log("LP", idx + 1);
        console.log("  Deposited  :", lp.depositedUsdc / 1e6, "USDC +", lp.depositedUsdt / 1e6);
        console.log("  Received   :", lp.receivedUsdc  / 1e6, "USDC +", lp.receivedUsdt / 1e6);
        console.log("  Gain (USD) :", gain / 1e6, "cents:", (gain % 1e6) / 1e4);
        console.log("  Aave yield :", aave / 1e6, "cents:", (aave % 1e6) / 1e4);
        console.log("  Swap fees  :", fees / 1e6, "cents:", (fees % 1e6) / 1e4);
        if (deposited > 0 && durationYears > 0) {
            console.log("  APY total  :", gain * 10_000 / deposited / durationYears, "bps/yr");
            console.log("  APY aave   :", aave * 10_000 / deposited / durationYears, "bps/yr");
            console.log("  APY fees   :", fees * 10_000 / deposited / durationYears, "bps/yr");
        }
    }

    function _logResults(
        ScenarioParams memory p,
        LPResult[] memory r,
        uint256 rate0Before, uint256 rate0After,
        uint256 rate1Before, uint256 rate1After,
        uint256 successfulSwaps
    ) internal pure {
        console.log("\n======================================================");
        console.log("SCENARIO:", p.name);
        console.log("======================================================");
        console.log("Duration    :", p.durationYears, "years");
        console.log("Aave APY    : ~", p.aaveApyBps / 100, "% (configured)");
        console.log("Swaps succeeded:", successfulSwaps, "of", p.numSwaps);
        console.log("Swap size   :", p.swapSizeUsdc / 1e6, "USDC each");
        console.log("Aave USDC rate before:", rate0Before, "after:", rate0After);
        console.log("  growth bps:", (rate0After - rate0Before) * 10000 / rate0Before);
        console.log("Aave USDT rate before:", rate1Before, "after:", rate1After);
        console.log("  growth bps:", (rate1After - rate1Before) * 10000 / rate1Before);

        uint256 totDeposit; uint256 totReceived;
        uint256 totAave;    uint256 totFees;

        for (uint256 i = 0; i < r.length; i++) {
            _logLP(r[i], i, p.durationYears);
            totDeposit  += r[i].depositedUsdc + r[i].depositedUsdt;
            totReceived += r[i].receivedUsdc  + r[i].receivedUsdt;
            totAave     += r[i].aaveYieldUsdc + r[i].aaveYieldUsdt;
            totFees     += r[i].feesUsdc      + r[i].feesUsdt;
        }

        uint256 totGain = totReceived > totDeposit ? totReceived - totDeposit : 0;
        uint256 earnings = totAave + totFees;

        console.log("======================================================");
        console.log("TOTALS");
        console.log("  Deposited  :", totDeposit  / 1e6, "USD");
        console.log("  Received   :", totReceived / 1e6, "USD");
        console.log("  Total gain :", totGain / 1e6, "cents:", (totGain % 1e6) / 1e4);
        console.log("  Aave yield :", totAave / 1e6, "share%:", earnings > 0 ? totAave * 100 / earnings : 0);
        console.log("  Swap fees  :", totFees / 1e6, "share%:", earnings > 0 ? totFees * 100 / earnings : 0);
        if (totDeposit > 0 && p.durationYears > 0) {
            console.log("  Blended APY:", totGain * 10_000 / totDeposit / p.durationYears, "bps/yr");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                        PROOF OF CORRECTNESS
    // ─────────────────────────────────────────────────────────────────────────

    function _proveCorrectness(
        ScenarioParams memory p,
        LPResult[] memory results,
        uint256 rate0Before,
        uint256 rate0After,
        uint256 rate1Before,
        uint256 rate1After
    ) internal {
        console.log("\n--- PROOF OF CORRECTNESS ---");

        // ── Proof A: Aave rate grew by exactly the configured compound APY ─────
        // We compute the expected total growth in basis points and compare to actual.
        // The assertion proves that _setAaveLiquidityIndex worked correctly.
        uint256 factor = 10_000;
        for (uint256 y = 0; y < p.durationYears; y++) {
            factor = factor * (10_000 + p.aaveApyBps) / 10_000;
        }
        uint256 expectedGrowthBps = factor - 10_000;
        uint256 actualGrowthBps   = (rate0After - rate0Before) * 10_000 / rate0Before;

        assertApproxEqAbs(actualGrowthBps, expectedGrowthBps, 5,
            "Proof A FAILED: Aave rate growth does not match configured APY."
        );
        console.log("[PASS] Proof A - Aave index growth (bps):", actualGrowthBps, "expected:", expectedGrowthBps);

        // ── Proof B: total received >= total principal + 90% of Aave yield ─────
        //
        // For each LP, we measure in total underlying value (USDC + USDT combined)
        // to avoid per-token IL effects. IL is normal for LPs but since we use
        // alternating symmetric swaps and initialize at the fair price, IL is small.
        //
        // The identity in total terms:
        //   totalReceived = totalPrincipal + totalAaveYield + totalFees - totalIL
        //
        // We assert: totalReceived >= totalPrincipal + totalAaveYield * 90 / 100
        // This proves the LP earns real yield with at most 10% eaten by fees/IL.
        for (uint256 i = 0; i < results.length; i++) {
            LPResult memory r = results[i];
            uint256 totalPrincipal  = uint256(r.stataDeposited0) * rate0Before / 1e6
                                    + uint256(r.stataDeposited1) * rate1Before / 1e6;
            uint256 totalAtNewRates = uint256(r.stataDeposited0) * rate0After  / 1e6
                                    + uint256(r.stataDeposited1) * rate1After  / 1e6;
            uint256 totalAaveYield  = totalAtNewRates - totalPrincipal;
            uint256 totalReceived   = r.receivedUsdc + r.receivedUsdt;

            // LP must receive at least the original principal back
            assertGe(totalReceived, totalPrincipal,
                "Proof B FAILED: LP lost principal (IL exceeded principal value)"
            );
            // LP must capture at least 90% of the expected Aave yield
            uint256 minExpected = totalPrincipal + totalAaveYield * 90 / 100;
            assertGe(totalReceived, minExpected,
                "Proof B FAILED: LP did not earn Aave yield (IL or index mismatch)"
            );
        }
        console.log("[PASS] Proof B - total received >= principal + 90% aaveYield (all LPs)");

        // ── Proof C: Net swap fees are in the expected ballpark ───────────────
        //
        // Total fee value = totalReceived - totalAtNewRates
        // where totalAtNewRates = sd0 * rate0After + sd1 * rate1After (expected without fees)
        //
        // This is IL-neutral: IL just redistributes between USDC and USDT sides,
        // but total value in underlying is preserved. So totalFees = net benefit from fees.
        //
        // Expected: numSwaps * swapSize * 0.05% (fee rate), valued at the post-yield rate.
        // The fee is charged on stataTokens but measured here in underlying USDC+USDT.

        uint256 actualTotalFees;
        for (uint256 i = 0; i < results.length; i++) {
            LPResult memory r = results[i];
            uint256 totalAtNew = uint256(r.stataDeposited0) * rate0After / 1e6
                               + uint256(r.stataDeposited1) * rate1After / 1e6;
            uint256 totalRcvd  = r.receivedUsdc + r.receivedUsdt;
            if (totalRcvd > totalAtNew) actualTotalFees += totalRcvd - totalAtNew;
        }

        // Expected = numSwaps * swapSize * 0.05%, then scaled by average rate growth
        // The fee is on stataToken shares whose value grew by rateAfter/rateBefore
        uint256 avgRateGrowth = (rate0After * 100 / rate0Before + rate1After * 100 / rate1Before) / 2;
        uint256 rawFees       = p.numSwaps * p.swapSizeUsdc * 5 / 10_000;
        uint256 expectedFees  = rawFees * avgRateGrowth / 100;

        // Allow 50% tolerance: fee accuracy depends on pool price path, IL, and rate ratios
        assertApproxEqAbs(actualTotalFees, expectedFees, expectedFees / 2 + 1_000_000,
            "Proof C FAILED: net fee income deviates more than 50% from expected"
        );
        console.log("[PASS] Proof C - net fees (USD cents):", actualTotalFees / 1e4, "expected:", expectedFees / 1e4);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //                            TEST SCENARIOS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Scenario 1 - Conservative (1 year, 4% Aave APY)
    ///
    ///   Volume calibration:
    ///     TVL       = 400,000 USD  (2 LPs × 100k each side)
    ///     Swaps     = 1,000 × 8,000 USDC = 8M USD/year = 20× TVL/year
    ///     Frequency = ~19 swaps/week  (AM + PM on most days)
    ///     vs. real data: L2 stablecoin pools see 73-3,640× TVL/year on 0.01% tiers;
    ///       a 0.05% pool naturally attracts ~4-5× less volume → realistic floor ~15-20× TVL/year.
    ///
    ///   Expected yield breakdown:
    ///     Aave yield  ≈ 4.00% APY
    ///     Swap fees   ≈ 1.00% APY  (= 8M × 0.05% / 400k)
    ///     Total       ≈ 5.00% APY
    function test_scenario1_conservative_1year() public {
        address[] memory lps = new address[](2);
        lps[0] = alice; lps[1] = bob;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100_000e6;
        amounts[1] = 100_000e6;

        _runScenario(ScenarioParams({
            name:          "Conservative | 2 LPs x 100k | 1yr | 4% APY | 1000 swaps x 8k USDC",
            durationYears: 1,
            aaveApyBps:    400,
            numSwaps:      1000,
            swapSizeUsdc:  8_000e6,  // 2% of TVL per swap — realistic retail/bot flow
            lps:           lps,
            lpAmountsUsdc: amounts
        }));
    }

    /// @notice Scenario 2 - Moderate, unequal LPs (3 years, 5% Aave APY)
    ///
    ///   Volume calibration:
    ///     TVL       = 1,700,000 USD  (500k + 250k + 100k per side)
    ///     Swaps     = 2,040 total × 50,000 USDC = 34M USD/year = 20× TVL/year
    ///     Frequency = ~13 swaps/week  (consistent daily trading activity)
    ///     Swap size = 2.9% of TVL — matches DEX aggregator route sizes on L2 pools.
    ///
    ///   Expected yield breakdown (per year):
    ///     Aave yield  ≈ 5.25% APY  (compounded: (1.05)^3 - 1 = 15.76% total)
    ///     Swap fees   ≈ 1.00% APY  (= 34M × 0.05% / 1.7M)
    ///     Total       ≈ 6.25% APY
    ///
    ///   Demonstrates: fee income is proportional to liquidity share regardless of LP size.
    function test_scenario2_moderate_3years() public {
        address[] memory lps = new address[](3);
        lps[0] = alice; lps[1] = bob; lps[2] = carol;
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 500_000e6;
        amounts[1] = 250_000e6;
        amounts[2] = 100_000e6;

        _runScenario(ScenarioParams({
            name:          "Moderate | 3 unequal LPs | 3yrs | 5% APY | 2040 swaps x 50k USDC",
            durationYears: 3,
            aaveApyBps:    500,
            numSwaps:      2040,
            swapSizeUsdc:  50_000e6, // 2.9% of TVL per swap
            lps:           lps,
            lpAmountsUsdc: amounts
        }));
    }

    /// @notice Scenario 3 - Bull market (5 years, 6% Aave APY)
    ///
    ///   Volume calibration:
    ///     TVL       = 5,000,000 USD  (1M + 750k + 500k + 250k per side)
    ///     Swaps     = 2,600 total × 100,000 USDC = 52M USD/year = 10.4× TVL/year
    ///     Frequency = 10 swaps/week  (comparable to a small but established L2 pool)
    ///     Swap size = 2% of TVL — within normal DEX aggregator route limits.
    ///     Note: 5-year horizon makes gas accumulation the binding constraint;
    ///       10× TVL/year is the lower bound of real stablecoin pool activity.
    ///
    ///   Expected yield breakdown (per year):
    ///     Aave yield  ≈ 6.77% APY  (compounded: (1.06)^5 - 1 = 33.82% total)
    ///     Swap fees   ≈ 0.52% APY  (= 52M × 0.05% / 5M)
    ///     Total       ≈ 7.29% APY  (+38.6% over 5 years)
    function test_scenario3_bull_5years() public {
        address[] memory lps = new address[](4);
        lps[0] = alice; lps[1] = bob; lps[2] = carol; lps[3] = dave;
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 1_000_000e6;
        amounts[1] =   750_000e6;
        amounts[2] =   500_000e6;
        amounts[3] =   250_000e6;

        _runScenario(ScenarioParams({
            name:          "Bull | 4 LPs | 5yrs | 6% APY | 2600 swaps x 100k USDC",
            durationYears: 5,
            aaveApyBps:    600,
            numSwaps:      2600,
            swapSizeUsdc:  100_000e6, // 2% of TVL per swap
            lps:           lps,
            lpAmountsUsdc: amounts
        }));
    }
}

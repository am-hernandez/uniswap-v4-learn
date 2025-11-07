// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {CounterHook} from "../src/CounterHook.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {POOL_MANAGER, USDC} from "../src/Constants.sol";

contract CounterHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for int128;
    using SafeCast for uint128;

    IERC20 constant usdc = IERC20(USDC);
    IPoolManager constant poolManager = IPoolManager(POOL_MANAGER);
    PoolKey key;
    CounterHook hook;

    int24 constant TICK_SPACING = 10;
    int256 constant LIQUIDITY_DELTA = 1e12;

    uint256 constant SWAP = 1;
    uint256 constant ADD_LIQUIDITY = 2;
    uint256 constant REMOVE_LIQUIDITY = 3;
    uint256 action;

    function setUp() public {
        // Deploy a CounterHook that trusts a mocked PoolManager address.
        console.log("Deployer:");
        console.logAddress(address(this));

        bytes32 salt = vm.envBytes32("SALT");
        console.log("SALT:");
        console.logBytes32(salt);
        hook = new CounterHook{salt: salt}(POOL_MANAGER);
        console.log("Hook deployed to:");
        console.logAddress(address(hook));

        // Build a deterministic PoolKey that points back to the hook we just deployed.
        key = PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev Sanity-check that the PoolManager gate actually protects each hook callback.
    function test_only_pool_manager_can_call_hooks() public {
        vm.expectRevert(CounterHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, _basicSwapParams(), "");
    }

    /// @dev Ensures that invoking beforeSwap/afterSwap increments their respective counters.
    function test_swap_hooks_increment_counters() public {
        SwapParams memory swapParams = _basicSwapParams();

        // Act as the PoolManager and trigger the swap hooks.
        vm.prank(address(poolManager));
        hook.beforeSwap(address(this), key, swapParams, "");

        vm.prank(address(poolManager));
        hook.afterSwap(address(this), key, swapParams, BalanceDeltaLibrary.ZERO_DELTA, "");

        CounterHook.HookCounts memory counts = hook.getHookCountersById(key.toId());
        assertEq(counts.beforeSwap, 1, "beforeSwap counter mismatch");
        assertEq(counts.afterSwap, 1, "afterSwap counter mismatch");
    }

    /// @dev Verifies that the liquidity hooks keep independent counters.
    function test_liquidity_hooks_increment_counters() public {
        ModifyLiquidityParams memory liquidityParams = _basicLiquidityParams();

        vm.startPrank(address(poolManager));
        hook.beforeAddLiquidity(address(this), key, liquidityParams, "");
        hook.beforeRemoveLiquidity(address(this), key, liquidityParams, "");
        vm.stopPrank();

        CounterHook.HookCounts memory counts = hook.getHookCountersById(key.toId());
        assertEq(counts.beforeAddLiquidity, 1, "beforeAddLiquidity counter mismatch");
        assertEq(counts.beforeRemoveLiquidity, 1, "beforeRemoveLiquidity counter mismatch");
    }

    /// @dev Demonstrates how to pull individual counters via the helper accessor.
    function test_getHookCount_helper_returns_individual_values() public {
        SwapParams memory swapParams = _basicSwapParams();
        PoolId poolId = key.toId();

        // Fire the beforeSwap hook twice.
        vm.prank(address(poolManager));
        hook.beforeSwap(address(this), key, swapParams, "");
        vm.prank(address(poolManager));
        hook.beforeSwap(address(this), key, swapParams, "");

        // Fire afterSwap once.
        vm.prank(address(poolManager));
        hook.afterSwap(address(this), key, swapParams, BalanceDeltaLibrary.ZERO_DELTA, "");

        // Query the flattened getter rather than the struct-based helper above.
        assertEq(hook.getHookCount(poolId, CounterHook.CounterType.BeforeSwap), 2, "beforeSwap helper count mismatch");
        assertEq(hook.getHookCount(poolId, CounterHook.CounterType.AfterSwap), 1, "afterSwap helper count mismatch");
    }

    /// @dev Builds a bare-bones swap payload for the tests. Values themselves are irrelevant here.
    function _basicSwapParams() private pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
    }

    /// @dev Provides a simple liquidity payload shared across the liquidity tests.
    function _basicLiquidityParams() private pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: bytes32("test")});
    }
}

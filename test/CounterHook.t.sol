// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {MIN_SQRT_PRICE, MAX_TICK, MIN_TICK, POOL_MANAGER, USDC} from "../src/Constants.sol";

import {CounterHook} from "../src/CounterHook.sol";

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

    /// @dev The actions that can be performed.
    /// @notice These are used to track the action being performed in the swap or liquidity tests.
    uint256 constant SWAP = 1;
    uint256 constant ADD_LIQUIDITY = 2;
    uint256 constant REMOVE_LIQUIDITY = 3;

    error UnsupportedAction(uint256 action);

    /// @dev The action being performed.
    /// @notice This is used to track the action being performed in the swap or liquidity tests.
    uint256 action;

    function setUp() public {
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
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(USDC), // USDC
            fee: 500,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        poolManager.initialize(key, 1e6 * (1 << 96));

        deal(USDC, address(this), 1e6 * 1e6);
        deal(address(this), 1e6 * 1e18);
    }

    /// @dev Receive function to allow the contract to receive ETH.
    receive() external payable {}

    /// @dev Unlock callback function that is called when the pool manager is unlocked.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // Three possible actions: swap, add liquidity, remove liquidity.
        if (action == SWAP) {
            // Swap ETH -> USDC

            // Get the balance of USDC in the contract.
            uint256 bal = usdc.balanceOf(address(this));

            // Call pool manager's swap function to swap ETH -> USDC.
            BalanceDelta delta = poolManager.swap({
                key: key,
                params: IPoolManager.SwapParams({
                    zeroForOne: true, amountSpecified: -(int256(bal)), sqrtPriceLimitX96: MIN_SQRT_PRICE + 1
                }),
                hookData: ""
            });

            // get amounts for token 0 and token 1.
            int128 amount0 = delta.amount0();
            int128 amount1 = delta.amount1();

            // get currencies and amounts.
            (Currency currencyIn, Currency currencyOut, uint256 amountIn, uint256 amountOut) =
                (key.currency0, key.currency1, uint256(uint128(-amount0)), uint256(uint128(amount1)));

            // take the output.
            poolManager.take({currency: currencyOut, to: address(this), amount: amountOut});

            // sync the input.
            poolManager.sync(currencyIn);
            // pay + settle the input.
            poolManager.settle{value: amountIn}();
            return "";
        } else if (action == ADD_LIQUIDITY) {
            // add liquidity.

            (BalanceDelta delta,) = poolManager.modifyLiquidity({
                key: key,
                params: IPoolManager.ModifyLiquidityParams({
                    tickLower: MIN_TICK / TICK_SPACING * TICK_SPACING,
                    tickUpper: MAX_TICK / TICK_SPACING * TICK_SPACING,
                    liquidityDelta: LIQUIDITY_DELTA,
                    salt: bytes32(0)
                }),
                hookData: ""
            });

            // get amounts for token 0 and token 1.
            if (delta.amount0() < 0) {
                // if token 0 is negative
                uint256 amount0 = uint128(-delta.amount0());

                // sync
                poolManager.sync(key.currency0);

                // pay + settle
                poolManager.settle{value: amount0}();
            }
            if (delta.amount1() < 0) {
                // if token 1 is negative
                uint256 amount1 = uint128(-delta.amount1());

                // deal USDC to the contract.
                deal(USDC, address(this), amount1);

                // sync
                poolManager.sync(key.currency1);

                // pay USDC to the pool manager.
                usdc.transfer(address(poolManager), amount1);

                // settle
                poolManager.settle();
            }
            return "";
        } else if (action == REMOVE_LIQUIDITY) {
            // remove liquidity.
            (BalanceDelta delta,) = poolManager.modifyLiquidity({
                key: key,
                params: IPoolManager.ModifyLiquidityParams({
                    tickLower: MIN_TICK / TICK_SPACING * TICK_SPACING,
                    tickUpper: MAX_TICK / TICK_SPACING * TICK_SPACING,
                    liquidityDelta: -LIQUIDITY_DELTA,
                    salt: bytes32(0)
                }),
                hookData: ""
            });

            // get amounts for token 0 and token 1.
            if (delta.amount0() > 0) {
                // if token 0 is positive
                uint256 amount0 = uint128(delta.amount0());

                // sync
                poolManager.take({currency: key.currency0, to: address(this), amount: amount0});
            }
            if (delta.amount1() > 0) {
                // if token 1 is positive
                uint256 amount1 = uint128(delta.amount1());

                // sync
                poolManager.take({currency: key.currency1, to: address(this), amount: amount1});
            }
            return "";
        }

        revert UnsupportedAction(action);
    }

    /// @dev Verifies that the hook permissions are correct.
    function test_permissions() public view {
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions());
    }

    /// @dev Verifies that the liquidity hooks increment the counters correctly.
    function test_liquidity() public {
        // Set the action to add liquidity.
        action = ADD_LIQUIDITY;

        // Unlock the pool manager.
        poolManager.unlock("");
        assertEq(hook.getHookCount(key.toId(), CounterHook.CounterType.BeforeAddLiquidity), 1);
        assertEq(hook.getHookCount(key.toId(), CounterHook.CounterType.AfterAddLiquidity), 0);

        // Set the action to remove liquidity.
        action = REMOVE_LIQUIDITY;

        // Unlock the pool manager.
        poolManager.unlock("");
        assertEq(hook.getHookCount(key.toId(), CounterHook.CounterType.BeforeRemoveLiquidity), 1);
        assertEq(hook.getHookCount(key.toId(), CounterHook.CounterType.AfterRemoveLiquidity), 0);
    }

    function test_swap() public {
        action = SWAP;
        deal(USDC, address(this), 100 * 1e6);
        poolManager.unlock("");
        assertEq(hook.getHookCount(key.toId(), CounterHook.CounterType.BeforeSwap), 1);
        assertEq(hook.getHookCount(key.toId(), CounterHook.CounterType.AfterSwap), 1);
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

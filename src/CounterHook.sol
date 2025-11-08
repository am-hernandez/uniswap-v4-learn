// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// This hook contract purposefully mirrors the behaviour of the BaseHook helper that ships
// with the official Uniswap v4 periphery. Implementing it from scratch is a useful exercise
// to understand how every callback is wired: the PoolManager calls into the hook, the hook
// can react and optionally mutate some shared storage, then signals whether execution
// should continue by returning its function selector. Every function below is annotated
// so it is easy to follow what the PoolManager would expect during each phase.

// See here for explanation of function inputs and outputs
// https://github.com/Uniswap/v4-core/blob/main/src/interfaces/IHooks.sol

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract CounterHook {
    using PoolIdLibrary for PoolKey;

    /// @notice Aggregate counters that track how many times a specific hook fired for a pool.
    struct HookCounts {
        uint256 beforeSwap;
        uint256 afterSwap;
        uint256 beforeAddLiquidity;
        uint256 afterAddLiquidity;
        uint256 beforeRemoveLiquidity;
        uint256 afterRemoveLiquidity;
    }

    /// @notice Helper enum used when querying a single counter via `getHookCount`.
    enum CounterType {
        BeforeSwap,
        AfterSwap,
        BeforeAddLiquidity,
        AfterAddLiquidity,
        BeforeRemoveLiquidity,
        AfterRemoveLiquidity
    }

    error NotPoolManager();
    error HookNotImplemented();
    error CounterTypeNotImplemented(CounterType counterType);
    IPoolManager public immutable poolManager;

    // Each pool has its own set of counters, keyed by the deterministic PoolId.
    mapping(PoolId => HookCounts) private hookCounters;

    modifier onlyPoolManager() {
        // PoolManager is the only contract that should ever hit these callbacks.
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);

        // v4 validates hook permissions up-front. Failing to do this means the pool creation
        // transaction would later revert. Performing the validation here keeps feedback tight.
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice Permissions dictate which callbacks the PoolManager may invoke.
    /// @dev Keep this in sync with the functions implemented below. The HookMiner test relies
    /// on the same bitmask when searching for a CREATE2 salt that satisfies the hook mask.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Surface the counters for a full PoolKey (useful when the key is readily available).
    function getHookCounters(PoolKey calldata key) external view returns (HookCounts memory) {
        return hookCounters[key.toId()];
    }

    /// @notice Expose counters keyed by the cheaper PoolId for direct reads in tests/UIs.
    function getHookCountersById(PoolId poolId) external view returns (HookCounts memory) {
        return hookCounters[poolId];
    }

    /// @notice Convenience helper to grab a single counter without unpacking the struct.
    function getHookCount(PoolId poolId, CounterType counterType) external view returns (uint256) {
        HookCounts memory counts = hookCounters[poolId];
        if (counterType == CounterType.BeforeSwap) return counts.beforeSwap;
        if (counterType == CounterType.AfterSwap) return counts.afterSwap;
        if (counterType == CounterType.BeforeAddLiquidity) return counts.beforeAddLiquidity;
        if (counterType == CounterType.AfterAddLiquidity) return counts.afterAddLiquidity;
        if (counterType == CounterType.BeforeRemoveLiquidity) return counts.beforeRemoveLiquidity;
        if (counterType == CounterType.AfterRemoveLiquidity) return counts.afterRemoveLiquidity;
        revert CounterTypeNotImplemented(counterType);
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @dev Called right before the swap executes. We simply count the invocation and
    /// return the selector with a no-op delta so the PoolManager keeps going.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        hookCounters[poolId].beforeSwap++;

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Runs after swap settlement. Again we only track frequency and return "no-op" values.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        hookCounters[poolId].afterSwap++;

        return (this.afterSwap.selector, 0);
    }

    /// @dev Called before liquidity is added. We mark the event and allow the operation.
    function beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        hookCounters[poolId].beforeAddLiquidity++;

        return this.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @dev Called before liquidity is removed. Works like the add-liquidity hook above.
    function beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        hookCounters[poolId].beforeRemoveLiquidity++;

        return this.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}

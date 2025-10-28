// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// import {console} from "forge-std/Test.sol";
//
// Router is a minimal swap router that drives the PoolManager via unlock()/callback.
// It supports:
// - Exact input (single and multi-hop)
// - Exact output (single and multi-hop)
//
// Key ideas:
// - Transient storage (TStore) sets an "action" before calling PoolManager.unlock().
//   PoolManager re-enters this contract via unlockCallback(), where we branch
//   on the action and finish the swap flow.
// - CurrencyLib lets us treat native ETH (address(0)) and ERC20 uniformly for
//   transfer in/out and balance reads.
// - BalanceDelta from PoolManager.swap packs signed token0/token1 deltas where
//   negative = paid, positive = received. We map those to user-facing amounts.

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TStore} from "../src/TStore.sol";
import {MIN_SQRT_PRICE, MAX_SQRT_PRICE} from "./Constants.sol";

contract Router is TStore, IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for int128;
    using SafeCast for uint128;
    using CurrencyLibrary for Currency;

    // Actions
    // These transient action identifiers drive control-flow inside unlockCallback()
    uint256 private constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint256 private constant SWAP_EXACT_IN = 0x07;
    uint256 private constant SWAP_EXACT_OUT_SINGLE = 0x08;
    uint256 private constant SWAP_EXACT_OUT = 0x09;

    IPoolManager public immutable poolManager;

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMin;
        bytes hookData;
    }

    struct ExactOutputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMax;
        bytes hookData;
    }

    struct PathKey {
        address currency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }

    struct ExactInputParams {
        address currencyIn;
        // First element + currencyIn determines the first pool to swap
        // Last element + previous path element's currency determines the last pool to swap
        PathKey[] path;
        uint128 amountIn;
        uint128 amountOutMin;
    }

    struct ExactOutputParams {
        address currencyOut;
        // Last element + currencyOut determines the last pool to swap
        // First element + second path element's currency determines the first pool to swap
        PathKey[] path;
        uint128 amountOut;
        uint128 amountInMax;
    }

    error UnsupportedAction(uint256 action);

    // Only the PoolManager may call our unlockCallback()
    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "not pool manager");
        _;
    }

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
    }

    // Accept native ETH used during settlement/refunds
    receive() external payable {}

    // PoolManager invokes this during unlock(). We branch based on the
    // transient action (set by the public entry points) to complete the flow.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint256 action = _getAction();

        if (action == SWAP_EXACT_IN_SINGLE) {
            // Decode the caller and parameters for an exact-input single-hop swap
            (address msgSender, ExactInputSingleParams memory params) =
                abi.decode(data, (address, ExactInputSingleParams));

            // Perform the swap with amountSpecified < 0 to denote exact input
            (int128 amount0, int128 amount1) =
                _swap(params.poolKey, params.zeroForOne, -(params.amountIn.toInt256()), params.hookData);

            // Translate token0/token1 deltas into user-facing currencies/amounts
            (Currency currencyIn, Currency currencyOut, uint256 amountIn, uint256 amountOut) = params.zeroForOne
                ? (
                    params.poolKey.currency0,
                    params.poolKey.currency1,
                    uint256(uint128(-amount0)),
                    uint256(uint128(amount1))
                )
                : (
                    params.poolKey.currency1,
                    params.poolKey.currency0,
                    uint256(uint128(-amount1)),
                    uint256(uint128(amount0))
                );

            // Slippage guard
            require(amountOut >= params.amountOutMin, "amount out < min");

            // Deliver output and settle the owed input with PoolManager
            _takeAndSettle({
                dst: msgSender,
                currencyIn: Currency.unwrap(currencyIn),
                currencyOut: Currency.unwrap(currencyOut),
                amountIn: amountIn,
                amountOut: amountOut
            });

            return abi.encode(amountOut);
        } else if (action == SWAP_EXACT_OUT_SINGLE) {
            // Decode the caller and parameters for an exact-output single-hop swap
            (address msgSender, ExactOutputSingleParams memory params) =
                abi.decode(data, (address, ExactOutputSingleParams));

            // Perform the swap with amountSpecified > 0 to denote exact output
            (int128 amount0, int128 amount1) =
                _swap(params.poolKey, params.zeroForOne, params.amountOut.toInt256(), params.hookData);

            // Translate token0/token1 deltas into user-facing currencies/amounts
            (Currency currencyIn, Currency currencyOut, uint256 amountIn, uint256 amountOut) = params.zeroForOne
                ? (
                    params.poolKey.currency0,
                    params.poolKey.currency1,
                    uint256(uint128(-amount0)),
                    uint256(uint128(amount1))
                )
                : (
                    params.poolKey.currency1,
                    params.poolKey.currency0,
                    uint256(uint128(-amount1)),
                    uint256(uint128(amount0))
                );

            // Enforce maximum amount the user is willing to spend
            require(amountIn <= params.amountInMax, "amount in > max");

            // Deliver output and settle the owed input with PoolManager
            _takeAndSettle({
                dst: msgSender,
                currencyIn: Currency.unwrap(currencyIn),
                currencyOut: Currency.unwrap(currencyOut),
                amountIn: amountIn,
                amountOut: amountOut
            });

            return abi.encode(amountIn);
        } else if (action == SWAP_EXACT_IN) {
            // Multi-hop exact input: walk forward across the path
            (address msgSender, ExactInputParams memory params) = abi.decode(data, (address, ExactInputParams));

            uint256 n = params.path.length;
            Currency currencyIn = Currency.wrap(params.currencyIn);
            int256 amountIn = params.amountIn.toInt256();
            for (uint256 i = 0; i < n; i++) {
                PathKey memory path = params.path[i];
                // Canonicalize PoolKey ordering (currency0 < currency1)
                (Currency currency0, Currency currency1) = path.currency < Currency.unwrap(currencyIn)
                    ? (Currency.wrap(path.currency), currencyIn)
                    : (currencyIn, Currency.wrap(path.currency));

                PoolKey memory key = PoolKey({
                    currency0: currency0,
                    currency1: currency1,
                    fee: path.fee,
                    tickSpacing: path.tickSpacing,
                    hooks: IHooks(address(path.hooks))
                });

                // Determine direction for this hop
                bool zeroForOne = currencyIn == currency0;

                // amountSpecified < 0 = exact input for this hop
                (int128 amount0, int128 amount1) = _swap(key, zeroForOne, -amountIn, path.hookData);

                // Next params
                // Carry forward this hop's output as next hop's input
                currencyIn = Currency.wrap(path.currency);
                amountIn = zeroForOne ? int256(amount1) : int256(amount0);
            }
            // currencyIn and amountIn stores currency out and amount out
            // Final slippage check across the whole path
            require(uint256(amountIn) >= uint256(params.amountOutMin), "amount out < min");
            // Settle total input and deliver final output once
            _takeAndSettle({
                dst: msgSender,
                currencyIn: params.currencyIn,
                currencyOut: Currency.unwrap(currencyIn),
                amountIn: params.amountIn,
                amountOut: uint256(amountIn)
            });

            return abi.encode(uint256(amountIn));
        } else if (action == SWAP_EXACT_OUT) {
            // Multi-hop exact output: walk backward across the path
            (address msgSender, ExactOutputParams memory params) = abi.decode(data, (address, ExactOutputParams));

            uint256 n = params.path.length;
            address currencyOut = params.currencyOut;
            int256 amountOut = params.amountOut.toInt256();
            for (uint256 i = n; i > 0; i--) {
                PathKey memory path = params.path[i - 1];

                // Canonicalize PoolKey ordering (currency0 < currency1)
                (Currency currency0, Currency currency1) = path.currency < currencyOut
                    ? (Currency.wrap(path.currency), Currency.wrap(currencyOut))
                    : (Currency.wrap(currencyOut), Currency.wrap(path.currency));

                PoolKey memory key = PoolKey({
                    currency0: currency0,
                    currency1: currency1,
                    fee: path.fee,
                    tickSpacing: path.tickSpacing,
                    hooks: IHooks(address(path.hooks))
                });

                // Determine direction for this hop
                bool zeroForOne = Currency.wrap(currencyOut) == currency1;

                // amountSpecified > 0 = exact output for this hop
                (int128 amount0, int128 amount1) = _swap(key, zeroForOne, amountOut, path.hookData);

                // Next params
                // Carry backward the required input of this hop
                currencyOut = path.currency;
                amountOut = zeroForOne ? -int256(amount0) : -int256(amount1);
            }

            // currencyOut and amountOut stores currency in and amount in
            // Enforce maximum total input across the whole path
            require(uint256(amountOut) <= uint256(params.amountInMax), "amount in > max");
            // Settle total input and deliver final output once
            _takeAndSettle({
                dst: msgSender,
                currencyIn: currencyOut,
                currencyOut: params.currencyOut,
                amountIn: uint256(amountOut),
                amountOut: uint256(params.amountOut)
            });

            return abi.encode(uint256(amountOut));
        }

        revert UnsupportedAction(action);
    }

    function swapExactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        setAction(SWAP_EXACT_IN_SINGLE)
        returns (uint256 amountOut)
    {
        Currency currencyIn = params.zeroForOne ? params.poolKey.currency0 : params.poolKey.currency1;

        if (currencyIn.isAddressZero()) {
            require(msg.value == uint256(params.amountIn), "invalid msg.value");
        } else {
            IERC20(Currency.unwrap(currencyIn)).transferFrom(msg.sender, address(this), uint256(params.amountIn));
        }
        bytes memory res = poolManager.unlock(abi.encode(msg.sender, params));
        amountOut = abi.decode(res, (uint256));
        _refund(currencyIn, msg.sender);
    }

    function swapExactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        setAction(SWAP_EXACT_OUT_SINGLE)
        returns (uint256 amountIn)
    {
        Currency currencyIn = params.zeroForOne ? params.poolKey.currency0 : params.poolKey.currency1;

        if (currencyIn.isAddressZero()) {
            require(msg.value == uint256(params.amountInMax), "invalid msg.value");
        } else {
            IERC20(Currency.unwrap(currencyIn)).transferFrom(msg.sender, address(this), uint256(params.amountInMax));
        }
        poolManager.unlock(abi.encode(msg.sender, params));

        uint256 refunded = _refund(currencyIn, msg.sender);
        if (refunded < params.amountInMax) {
            return params.amountInMax - refunded;
        }
        return 0;
    }

    function swapExactInput(ExactInputParams calldata params)
        external
        payable
        setAction(SWAP_EXACT_IN)
        returns (uint256 amountOut)
    {
        require(params.path.length > 0, "path length = 0");

        if (params.currencyIn == address(0)) {
            require(msg.value == uint256(params.amountIn), "invalid msg.value");
        } else {
            IERC20(params.currencyIn).transferFrom(msg.sender, address(this), uint256(params.amountIn));
        }
        bytes memory res = poolManager.unlock(abi.encode(msg.sender, params));
        amountOut = abi.decode(res, (uint256));
        {
            Currency c = Currency.wrap(params.currencyIn);
            uint256 bal = c.balanceOfSelf();
            if (bal > 0) {
                c.transfer(msg.sender, bal);
            }
        }
    }

    function swapExactOutput(ExactOutputParams calldata params)
        external
        payable
        setAction(SWAP_EXACT_OUT)
        returns (uint256 amountIn)
    {
        require(params.path.length > 0, "path length = 0");

        PathKey memory path = params.path[0];
        address currencyIn = path.currency;

        if (currencyIn == address(0)) {
            require(msg.value == uint256(params.amountInMax), "invalid msg.value");
        } else {
            IERC20(currencyIn).transferFrom(msg.sender, address(this), uint256(params.amountInMax));
        }
        poolManager.unlock(abi.encode(msg.sender, params));

        uint256 refunded = _refund(Currency.wrap(currencyIn), msg.sender);
        if (refunded < params.amountInMax) {
            return params.amountInMax - refunded;
        }
        return 0;
    }

    function _refund(Currency currency, address dst) private returns (uint256) {
        uint256 bal = currency.balanceOfSelf();
        if (bal > 0) {
            currency.transfer(dst, bal);
        }
        return bal;
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        private
        returns (int128 amount0, int128 amount1)
    {
        BalanceDelta d = poolManager.swap({
            key: key,
            params: IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                // amountSpecified < 0 = amount in
                // amountSpecified > 0 = amount out
                amountSpecified: amountSpecified,
                // price = Currency 1 / currency 0
                // 0 for 1 = price decreases
                // 1 for 0 = price increases
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1
            }),
            hookData: hookData
        });
        return (d.amount0(), d.amount1());
    }

    function _takeAndSettle(address dst, address currencyIn, address currencyOut, uint256 amountIn, uint256 amountOut)
        private
    {
        poolManager.take({currency: Currency.wrap(currencyOut), to: dst, amount: amountOut});

        poolManager.sync(Currency.wrap(currencyIn));

        if (currencyIn == address(0)) {
            poolManager.settle{value: amountIn}();
        } else {
            IERC20(currencyIn).transfer(address(poolManager), amountIn);
            poolManager.settle();
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {MIN_SQRT_PRICE, MAX_SQRT_PRICE} from "../src/Constants.sol";

contract Swap is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for int128;
    using SafeCast for uint128;
    using CurrencyLibrary for address;

    IPoolManager public immutable poolManager;

    struct SwapExactInputSingleHop {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMin;
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "not pool manager");
        _;
    }

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
    }

    receive() external payable {}

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        // decode data
        (address sender, SwapExactInputSingleHop memory params) = abi.decode(data, (address, SwapExactInputSingleHop));

        // get swap params
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: params.zeroForOne,
            amountSpecified: -(params.amountIn.toInt256()),
            sqrtPriceLimitX96: params.zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1
        });

        // swap
        BalanceDelta swapDelta = poolManager.swap({key: params.poolKey, params: swapParams, hookData: new bytes(0)});

        // get amount0 and amount1
        int128 amount0 = swapDelta.amount0();
        int128 amount1 = swapDelta.amount1();

        // get currency in and out
        (Currency currencyIn, Currency currencyOut, int128 amountIn, int128 amountOut) = params.zeroForOne
            // direction: currency 0 -> currency 1
            ? (params.poolKey.currency0, params.poolKey.currency1, -amount0, amount1)
            // direction: currency 0 -> currency 1
            : (params.poolKey.currency1, params.poolKey.currency0, -amount1, amount0);

        // require amount out to be greater than amount out min
        require(amountOut >= int128(params.amountOutMin), "amount out less than amount out min");

        // take output
        poolManager.take({currency: currencyOut, to: sender, amount: uint256(uint128(amountOut))});

        // sync only for ERC20 before settle
        if (!currencyIn.isAddressZero()) {
            poolManager.sync({currency: currencyIn});
        }

        // settle input
        if (currencyIn.isAddressZero()) {
            // settle native currency
            poolManager.settle{value: uint256(uint128(amountIn))}();
        } else {
            // settle ERC20 currency
            IERC20(Currency.unwrap(currencyIn)).transfer(address(poolManager), uint256(uint128(amountIn)));
            poolManager.settle();
        }

        // return empty bytes
        return new bytes(0);
    }

    function swap(SwapExactInputSingleHop calldata params) external payable {
        // Determine input currency
        Currency currencyIn = params.zeroForOne ? params.poolKey.currency0 : params.poolKey.currency1;

        if (currencyIn.isAddressZero()) {
            // Native ETH path: user must send exact ETH equal to amountIn
            require(msg.value == uint256(params.amountIn), "invalid msg.value");
        } else {
            // ERC20 path: pull tokens from sender into this contract; manager will be settled in callback
            IERC20(Currency.unwrap(currencyIn)).transferFrom(msg.sender, address(this), uint256(params.amountIn));
        }

        poolManager.unlock(abi.encode(msg.sender, params));

        // Refund any leftover input currency back to the caller
        uint256 bal = currencyIn.balanceOf(address(this));
        if (bal > 0) {
            if (currencyIn.isAddressZero()) {
                payable(msg.sender).transfer(bal);
            } else {
                IERC20(Currency.unwrap(currencyIn)).transfer(msg.sender, bal);
            }
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

contract Flash is IUnlockCallback {
    using CurrencyLibrary for address;

    IPoolManager public immutable poolManager;
    // Contract address to test flash loan
    address private immutable tester;

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "not pool manager");
        _;
    }

    constructor(address _poolManager, address _tester) {
        poolManager = IPoolManager(_poolManager);
        tester = _tester;
    }

    receive() external payable {}

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));

        // take
        poolManager.take({currency: currency, to: address(this), amount: amount});

        // set balance on tester contract
        (bool ok,) = tester.call(abi.encodeWithSignature("setBalance()"));
        require(ok, "test failed");

        // sync
        poolManager.sync({currency: currency});

        // pay + settle
        if (currency.isAddressZero()) {
            // settle native currency
            poolManager.settle{value: amount}();
        } else {
            // settle ERC20 currency
            currency.transfer(address(poolManager), amount);
            poolManager.settle();
        }

        return "";
    }

    function flash(address currency, uint256 amount) external {
        // call unlock
        poolManager.unlock(abi.encode(currency, amount));
    }
}

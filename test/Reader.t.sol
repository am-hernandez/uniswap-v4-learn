// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Reader} from "../src/Reader.sol";
import {POOL_MANAGER, USDC} from "../src/Constants.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract ReaderTest is Test {
    Reader reader;
    IPoolManager poolManager;
    IERC20 constant usdc = IERC20(USDC);

    function setUp() public {
        reader = new Reader(POOL_MANAGER);
        poolManager = IPoolManager(POOL_MANAGER);
    }

    // call poolmanager unlock
    function test_getCurrencyDelta() public {
        poolManager.unlock("");
    }

    // handle the unlock callback
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        // get the delta before the take
        int256 deltaBefore = reader.getCurrencyDelta(address(this), USDC);
        assertEq(deltaBefore, 0);

        // take 100 USDC
        poolManager.take(Currency.wrap(USDC), address(this), 100000000);

        // get the delta after the take
        int256 deltaAfter = reader.getCurrencyDelta(address(this), USDC);
        assertLt(deltaAfter, 0);

        // sync
        poolManager.sync(Currency.wrap(USDC));

        // pay and settle 100 USDC
        usdc.transfer(address(poolManager), 100000000);
        poolManager.settle();

        // get the delta after the settle
        int256 deltaAfterSettle = reader.getCurrencyDelta(address(this), USDC);

        // After settle the delta should be 0 again
        assertEq(deltaAfterSettle, 0);

        // return the data
        return "";
    }
}
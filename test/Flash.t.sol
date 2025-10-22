// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {POOL_MANAGER, USDC} from "../src/Constants.sol";
import {Flash} from "../src/Flash.sol";

contract FlashTest is Test {
    address private coin;
    uint256 public coinBalance;

    Flash flash;
    receive() external payable {}

    function setUp() public {
        coin = USDC;
        flash = new Flash(POOL_MANAGER, address(this));
    }

    function test_flash() public {
        flash.flash(USDC, 1000 * 1e6);
        console.log("Borrowed amount: %e USDC", coinBalance);
        assertEq(coinBalance, 1000 * 1e6);
    }

    function setBalance() public {
        coinBalance = IERC20(coin).balanceOf(msg.sender);
    }
}

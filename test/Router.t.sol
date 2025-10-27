// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {POOL_MANAGER, USDC, WBTC} from "../src/Constants.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TestHelper} from "./TestHelper.sol";
import {Router} from "../src/Router.sol";

contract RouterTest is Test, TestHelper {
    // Common ERC20 interfaces for convenience
    IERC20 constant usdc = IERC20(USDC);
    IERC20 constant wbtc = IERC20(WBTC);

    TestHelper helper;
    Router router;
    // Pool key for single hop swaps
    PoolKey poolKey;

    receive() external payable {}

    function setUp() public {
        // Deploy the on-chain helpers (mocks, pool manager wiring, etc.)
        helper = new TestHelper();

        // Seed balances to the test contract
        deal(USDC, address(this), 1000 * 1e6);
        deal(WBTC, address(this), 1 * 1e8);
        // Deploy a fresh Router pointing at the shared POOL_MANAGER
        router = new Router(POOL_MANAGER);

        // Allow the router to pull tokens for swaps on our behalf
        usdc.approve(address(router), type(uint256).max);
        wbtc.approve(address(router), type(uint256).max);

        // Predefine a single-hop pool for ETH <-> USDC swaps in the tests
        poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(USDC),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
    }

    function test_swapExactInputSingle_ETH_USDC() public {
        // Swap exact 1 ETH for as many USDC as possible in a single pool
        helper.set("Before swap USDC", usdc.balanceOf(address(this)));
        helper.set("Before swap ETH", address(this).balance);

        uint128 amountIn = 1e18;
        uint256 amountOut = router.swapExactInputSingle{value: uint256(amountIn)}(
            Router.ExactInputSingleParams({
                poolKey: poolKey, zeroForOne: true, amountIn: amountIn, amountOutMin: 1, hookData: ""
            })
        );

        helper.set("After swap USDC", usdc.balanceOf(address(this)));
        helper.set("After swap ETH", address(this).balance);

        // d0 = ETH change, d1 = USDC change on the test contract (recipient)
        int256 d0 = helper.delta("After swap ETH", "Before swap ETH");
        int256 d1 = helper.delta("After swap USDC", "Before swap USDC");

        console.log("ETH delta: %e", d0);
        console.log("USDC delta: %e", d1);

        assertLt(d0, 0, "ETH delta");
        assertGt(d1, 0, "USDC delta");
        assertEq(amountOut, uint256(d1), "amount out");
    }

    function test_swapExactInputSingle_USDC_ETH() public {
        // Swap exact USDC for as much ETH as possible in a single pool
        helper.set("Before swap USDC", usdc.balanceOf(address(this)));
        helper.set("Before swap ETH", address(this).balance);

        uint128 amountIn = 1000 * 1e6;
        uint256 amountOut = router.swapExactInputSingle{value: uint256(amountIn)}(
            Router.ExactInputSingleParams({
                poolKey: poolKey, zeroForOne: false, amountIn: amountIn, amountOutMin: 1, hookData: ""
            })
        );

        helper.set("After swap USDC", usdc.balanceOf(address(this)));
        helper.set("After swap ETH", address(this).balance);

        // d0 = ETH received (>0), d1 = USDC spent (<0)
        int256 d0 = helper.delta("After swap ETH", "Before swap ETH");
        int256 d1 = helper.delta("After swap USDC", "Before swap USDC");

        console.log("ETH delta: %e", d0);
        console.log("USDC delta: %e", d1);

        assertGt(d0, 0, "ETH delta");
        assertLt(d1, 0, "USDC delta");
        assertApproxEqRel(amountOut, uint256(d0), 0.001e18, "amount out");
    }

    function test_swapExactOutputSingle_ETH_USDC() public {
        // Buy an exact amount of USDC, spending at most amountInMax ETH
        helper.set("Before swap USDC", usdc.balanceOf(address(this)));
        helper.set("Before swap ETH", address(this).balance);

        uint128 amountInMax = 1e18;
        uint128 amountOut = 100 * 1e6;
        uint256 amountIn = router.swapExactOutputSingle{value: uint256(amountInMax)}(
            Router.ExactOutputSingleParams({
                poolKey: poolKey, zeroForOne: true, amountOut: amountOut, amountInMax: amountInMax, hookData: ""
            })
        );

        helper.set("After swap USDC", usdc.balanceOf(address(this)));
        helper.set("After swap ETH", address(this).balance);

        // d0 = ETH spent (<0), d1 = USDC received (= amountOut)
        int256 d0 = helper.delta("After swap ETH", "Before swap ETH");
        int256 d1 = helper.delta("After swap USDC", "Before swap USDC");

        console.log("ETH delta: %e", d0);
        console.log("USDC delta: %e", d1);

        assertLt(d0, 0, "ETH delta");
        assertGt(d1, 0, "USDC delta");
        assertApproxEqRel(amountIn, uint256(-d0), 0.001e18, "amount in != delta");
        assertLe(amountIn, amountInMax, "amount in > max");
        assertEq(amountOut, uint256(d1), "amount out");
    }

    function test_swapExactOutputSingle_USDC_ETH() public {
        // Buy an exact amount of ETH, spending at most amountInMax USDC
        helper.set("Before swap USDC", usdc.balanceOf(address(this)));
        helper.set("Before swap ETH", address(this).balance);

        uint128 amountInMax = 1000 * 1e6;
        uint128 amountOut = 0.01e18;
        uint256 amountIn = router.swapExactOutputSingle{value: uint256(amountInMax)}(
            Router.ExactOutputSingleParams({
                poolKey: poolKey, zeroForOne: false, amountOut: amountOut, amountInMax: amountInMax, hookData: ""
            })
        );

        helper.set("After swap USDC", usdc.balanceOf(address(this)));
        helper.set("After swap ETH", address(this).balance);

        // d0 = ETH received (>0), d1 = USDC spent (<0)
        int256 d0 = helper.delta("After swap ETH", "Before swap ETH");
        int256 d1 = helper.delta("After swap USDC", "Before swap USDC");

        console.log("ETH delta: %e", d0);
        console.log("USDC delta: %e", d1);

        assertGt(d0, 0, "ETH delta");
        assertLt(d1, 0, "USDC delta");
        assertEq(amountIn, uint256(-d1), "amount in != delta");
        assertLe(amountIn, amountInMax, "amount in > max");
        assertApproxEqRel(amountOut, uint256(d0), 0.001e18, "amount out");
    }

    function test_swapExactInput_USDC_ETH_WBTC() public {
        // Multi-hop exact input: USDC -> ETH -> WBTC
        helper.set("Before swap USDC", usdc.balanceOf(address(this)));
        helper.set("Before swap WBTC", wbtc.balanceOf(address(this)));

        Router.PathKey[] memory path = new Router.PathKey[](2);
        path[0] = Router.PathKey({currency: address(0), fee: 500, tickSpacing: 10, hooks: address(0), hookData: ""});
        path[1] = Router.PathKey({currency: WBTC, fee: 3000, tickSpacing: 60, hooks: address(0), hookData: ""});

        uint128 amountIn = 1000 * 1e6;
        uint256 amountOut = router.swapExactInput(
            Router.ExactInputParams({currencyIn: USDC, path: path, amountIn: amountIn, amountOutMin: 1})
        );

        helper.set("After swap USDC", usdc.balanceOf(address(this)));
        helper.set("After swap WBTC", wbtc.balanceOf(address(this)));

        // d0 = USDC spent, d1 = WBTC received
        int256 d0 = helper.delta("After swap USDC", "Before swap USDC");
        int256 d1 = helper.delta("After swap WBTC", "Before swap WBTC");

        console.log("USDC delta: %e", d0);
        console.log("WBTC delta: %e", d1);

        assertLt(d0, 0, "USDC delta");
        assertGt(d1, 0, "WBTC delta");
        assertEq(amountOut, uint256(d1), "amount out");
    }

    function test_swapExactInput_ETH_USDC_WBTC() public {
        // Multi-hop exact input: ETH -> USDC -> WBTC
        helper.set("Before swap ETH", address(this).balance);
        helper.set("Before swap WBTC", wbtc.balanceOf(address(this)));

        Router.PathKey[] memory path = new Router.PathKey[](2);
        path[0] = Router.PathKey({currency: USDC, fee: 500, tickSpacing: 10, hooks: address(0), hookData: ""});
        path[1] = Router.PathKey({currency: WBTC, fee: 500, tickSpacing: 10, hooks: address(0), hookData: ""});

        uint128 amountIn = 1e18;
        uint256 amountOut = router.swapExactInput{value: amountIn}(
            Router.ExactInputParams({currencyIn: address(0), path: path, amountIn: amountIn, amountOutMin: 1})
        );

        helper.set("After swap ETH", address(this).balance);
        helper.set("After swap WBTC", wbtc.balanceOf(address(this)));

        // d0 = ETH spent, d1 = WBTC received
        int256 d0 = helper.delta("After swap ETH", "Before swap ETH");
        int256 d1 = helper.delta("After swap WBTC", "Before swap WBTC");

        console.log("ETH delta: %e", d0);
        console.log("WBTC delta: %e", d1);

        assertLt(d0, 0, "ETH delta");
        assertGt(d1, 0, "WBTC delta");
        assertEq(amountOut, uint256(d1), "amount out");
    }

    function test_swapExactOutput_USDC_ETH_WBTC() public {
        // Multi-hop exact output: USDC -> ETH -> WBTC
        helper.set("Before swap USDC", usdc.balanceOf(address(this)));
        helper.set("Before swap WBTC", wbtc.balanceOf(address(this)));

        Router.PathKey[] memory path = new Router.PathKey[](2);
        path[0] = Router.PathKey({currency: USDC, fee: 500, tickSpacing: 10, hooks: address(0), hookData: ""});
        path[1] = Router.PathKey({currency: address(0), fee: 3000, tickSpacing: 60, hooks: address(0), hookData: ""});

        uint128 amountInMax = 1000 * 1e6;
        uint128 amountOut = 0.0001e8;
        uint256 amountIn = router.swapExactOutput(
            Router.ExactOutputParams({currencyOut: WBTC, path: path, amountOut: amountOut, amountInMax: amountInMax})
        );

        helper.set("After swap USDC", usdc.balanceOf(address(this)));
        helper.set("After swap WBTC", wbtc.balanceOf(address(this)));

        // d0 = USDC spent, d1 = WBTC received (= amountOut)
        int256 d0 = helper.delta("After swap USDC", "Before swap USDC");
        int256 d1 = helper.delta("After swap WBTC", "Before swap WBTC");

        console.log("USDC delta: %e", d0);
        console.log("WBTC delta: %e", d1);

        assertLt(d0, 0, "USDC delta");
        assertGt(d1, 0, "WBTC delta");
        assertEq(amountIn, uint256(-d0), "amount in != delta");
        assertLe(amountIn, amountInMax, "amount in > max");
        assertEq(amountOut, uint256(d1), "amount out");
    }

    function test_swapExactOutput_ETH_USDC_WBTC() public {
        // Multi-hop exact output: ETH -> USDC -> WBTC
        helper.set("Before swap ETH", address(this).balance);
        helper.set("Before swap WBTC", wbtc.balanceOf(address(this)));

        Router.PathKey[] memory path = new Router.PathKey[](2);
        path[0] = Router.PathKey({currency: address(0), fee: 500, tickSpacing: 10, hooks: address(0), hookData: ""});
        path[1] = Router.PathKey({currency: USDC, fee: 500, tickSpacing: 10, hooks: address(0), hookData: ""});

        uint128 amountInMax = 1e18;
        uint128 amountOut = 0.0001e8;
        uint256 amountIn = router.swapExactOutput{value: amountInMax}(
            Router.ExactOutputParams({currencyOut: WBTC, path: path, amountOut: amountOut, amountInMax: amountInMax})
        );

        helper.set("After swap ETH", address(this).balance);
        helper.set("After swap WBTC", wbtc.balanceOf(address(this)));

        // d0 = ETH spent, d1 = WBTC received (= amountOut)
        int256 d0 = helper.delta("After swap ETH", "Before swap ETH");
        int256 d1 = helper.delta("After swap WBTC", "Before swap WBTC");

        console.log("ETH delta: %e", d0);
        console.log("WBTC delta: %e", d1);

        assertLt(d0, 0, "ETH delta");
        assertGt(d1, 0, "WBTC delta");
        assertApproxEqRel(amountIn, uint256(-d0), 0.0001e18, "amount in != delta");
        assertLe(amountIn, amountInMax, "amount in > max");
        assertEq(amountOut, uint256(d1), "amount out");
    }
}

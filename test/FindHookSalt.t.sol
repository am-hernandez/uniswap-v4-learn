// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// This test demonstrates how HookMiner is used to discover a CREATE2 salt
// for a hook contract. Running `forge test --match-path test/FindHookSalt.t.sol -vvv` will print
// the salt alongside the pre-computed address.

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {CounterHook} from "../src/CounterHook.sol";
import {POOL_MANAGER} from "../src/Constants.sol";

contract FindHookSaltTest is Test {
    /// @notice Mines a salt that satisfies CounterHook's permission bitmask and verifies deployment.
    function test_find_counter_hook_salt() public {
        // 1. Encode the constructor args exactly as they will be supplied during deployment.
        bytes memory constructorArgs = abi.encode(POOL_MANAGER);

        // 2. Assemble the flag mask that represents the callbacks implemented by CounterHook.
        uint160 desiredFlags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG
        );

        // 3. Ask HookMiner to brute-force a salt for our deployer (address(this) inside forge tests).
        (address predictedAddress, bytes32 salt) = HookMiner.find({
            deployer: address(this),
            flags: desiredFlags,
            creationCode: type(CounterHook).creationCode,
            constructorArgs: constructorArgs
        });

        // Logging the result makes it simple to copy the salt into a deployment script.
        console2.log("Hook deployer:", address(this));
        console2.log("Predicted address:", predictedAddress);
        console2.log("Mined salt:");
        console2.logBytes32(salt);

        // 4. Deploy the hook using the mined salt and verify that CREATE2 produced the address we computed.
        CounterHook deployed = new CounterHook{salt: salt}(POOL_MANAGER);
        assertEq(address(deployed), predictedAddress, "CREATE2 address mismatch");

        // 5. Finally, double-check that the hook address actually satisfies the requested flag mask.
        assertEq(
            uint160(predictedAddress) & Hooks.ALL_HOOK_MASK,
            desiredFlags & Hooks.ALL_HOOK_MASK,
            "hook flags do not match mask"
        );
    }
}

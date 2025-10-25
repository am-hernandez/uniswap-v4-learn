// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract Reader {
    IPoolManager public immutable poolManager;

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
    }

    function computeSlot(address target, address currency) public pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            mstore(0, and(target, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(32, and(currency, 0xffffffffffffffffffffffffffffffffffffffff))
            slot := keccak256(0, 64)
        }
    }

    function getCurrencyDelta(address target, address currency) external view returns (int256 delta) {
        // call computeSlot
        bytes32 slot = computeSlot(target, currency);

        // call exttload on poolManager
        bytes32 value = poolManager.exttload(slot);

        // convert the value to an int256
        delta = int256(uint256(value));

        // return the delta
        return delta;
    }
}

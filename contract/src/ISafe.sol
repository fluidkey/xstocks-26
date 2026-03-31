// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.24;

/**
 * Minimal interface for Gnosis Safe 1.3.0 module interactions.
 * Only includes the function needed by SafeEarnModule to execute
 * transactions on behalf of the Safe.
 */
interface ISafe {
    /**
     * Allows a Module to execute a Safe transaction without any further confirmations.
     * @param to Destination address of module transaction.
     * @param value Ether value of module transaction.
     * @param data Data payload of module transaction.
     * @param operation Operation type of module transaction (0 = Call, 1 = DelegateCall).
     * @return success Boolean flag indicating if the call succeeded.
     */
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes memory data,
        uint8 operation
    ) external returns (bool success);
}

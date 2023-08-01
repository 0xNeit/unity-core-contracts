pragma solidity ^0.5.16;

import "./VTokens/VCORE.sol";

/**
 * @title UnityCore's Maximillion Contract
 * @author UnityCore
 */
contract Maximillion {
    /**
     * @notice The default vCore market to repay in
     */
    VCORE public vCore;

    /**
     * @notice Construct a Maximillion to repay max in a VCORE market
     */
    constructor(VCORE vCore_) public {
        vCore = vCore_;
    }

    /**
     * @notice msg.sender sends CORE to repay an account's borrow in the vCore market
     * @dev The provided CORE is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     */
    function repayBehalf(address borrower) public payable {
        repayBehalfExplicit(borrower, vCore);
    }

    /**
     * @notice msg.sender sends CORE to repay an account's borrow in a vCore market
     * @dev The provided CORE is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     * @param vCore_ The address of the vCore contract to repay in
     */
    function repayBehalfExplicit(address borrower, VCORE vCore_) public payable {
        uint received = msg.value;
        uint borrows = vCore_.borrowBalanceCurrent(borrower);
        if (received > borrows) {
            vCore_.repayBorrowBehalf.value(borrows)(borrower);
            msg.sender.transfer(received - borrows);
        } else {
            vCore_.repayBorrowBehalf.value(received)(borrower);
        }
    }
}

pragma solidity ^0.5.16;

import "./VBep20.sol";

/**
 * @title UnityCore's VBep20Immutable Contract
 * @notice VTokens which wrap an EIP-20 underlying and are immutable
 * @author UnityCore
 */
contract VBep20Immutable is VBep20 {
    /**
     * @notice Construct a new money market
     * @param underlying_ The address of the underlying asset
     * @param controller_ The address of the controller
     * @param interestRateModel_ The address of the interest rate model
     * @param initialExchangeRateMantissa_ The initial exchange rate, scaled by 1e18
     * @param name_ BEP-20 name of this token
     * @param symbol_ BEP-20 symbol of this token
     * @param decimals_ BEP-20 decimal precision of this token
     * @param admin_ Address of the administrator of this token
     */
    constructor(
        address underlying_,
        ControllerInterface controller_,
        InterestRateModel interestRateModel_,
        uint initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address payable admin_
    ) public {
        // Creator of the contract is admin during initialization
        admin = msg.sender;

        // Initialize the market
        initialize(
            underlying_,
            controller_,
            interestRateModel_,
            initialExchangeRateMantissa_,
            name_,
            symbol_,
            decimals_
        );

        // Set the proper admin now that initialization is done
        admin = admin_;
    }
}

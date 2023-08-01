pragma solidity ^0.5.16;

import { Controller } from "../../Controller/Controller.sol";

contract UAIUnitrollerAdminStorage {
    /**
     * @notice Administrator for this contract
     */
    address public admin;

    /**
     * @notice Pending administrator for this contract
     */
    address public pendingAdmin;

    /**
     * @notice Active brains of Unitroller
     */
    address public uaiControllerImplementation;

    /**
     * @notice Pending brains of Unitroller
     */
    address public pendingUAIControllerImplementation;
}

contract UAIControllerStorageG1 is UAIUnitrollerAdminStorage {
    Controller public controller;

    struct VenusUAIState {
        /// @notice The last updated venusUAIMintIndex
        uint224 index;
        /// @notice The block number the index was last updated at
        uint32 block;
    }

    /// @notice The Venus UAI state
    VenusUAIState public venusUAIState;

    /// @notice The Venus UAI state initialized
    bool public isVenusUAIInitialized;

    /// @notice The Venus UAI minter index as of the last time they accrued XVS
    mapping(address => uint) public venusUAIMinterIndex;
}

contract UAIControllerStorageG2 is UAIControllerStorageG1 {
    /// @notice Treasury Guardian address
    address public treasuryGuardian;

    /// @notice Treasury address
    address public treasuryAddress;

    /// @notice Fee percent of accrued interest with decimal 18
    uint256 public treasuryPercent;

    /// @notice Guard variable for re-entrancy checks
    bool internal _notEntered;

    /// @notice The base rate for stability fee
    uint public baseRateMantissa;

    /// @notice The float rate for stability fee
    uint public floatRateMantissa;

    /// @notice The address for UAI interest receiver
    address public receiver;

    /// @notice Accumulator of the total earned interest rate since the opening of the market. For example: 0.6 (60%)
    uint public uaiMintIndex;

    /// @notice Block number that interest was last accrued at
    uint internal accrualBlockNumber;

    /// @notice Global uaiMintIndex as of the most recent balance-changing action for user
    mapping(address => uint) internal uaiMinterInterestIndex;

    /// @notice Tracks the amount of mintedUAI of a user that represents the accrued interest
    mapping(address => uint) public pastUAIInterest;

    /// @notice UAI mint cap
    uint public mintCap;

    /// @notice Access control manager address
    address public accessControl;
}

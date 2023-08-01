pragma solidity ^0.5.16;

import "../../Utils/SafeMath.sol";
import "../../Utils/IERC20.sol";
import "../UCore/IUCoreVesting.sol";

contract URTConverterAdminStorage {
    /**
     * @notice Administrator for this contract
     */
    address public admin;

    /**
     * @notice Pending administrator for this contract
     */
    address public pendingAdmin;

    /**
     * @notice Active brains of URTConverter
     */
    address public implementation;

    /**
     * @notice Pending brains of URTConverter
     */
    address public pendingImplementation;
}

contract URTConverterStorage is URTConverterAdminStorage {
    /// @notice Guard variable for re-entrancy checks
    bool public _notEntered;

    /// @notice indicator to check if the contract is initialized
    bool public initialized;

    /// @notice The URT TOKEN!
    IERC20 public urt;

    /// @notice The UCore TOKEN!
    IERC20 public ucore;

    /// @notice UCoreVesting Contract reference
    IUCoreVesting public ucoreVesting;

    /// @notice Conversion ratio from URT to UCore with decimal 18
    uint256 public conversionRatio;

    /// @notice total URT converted to UCore
    uint256 public totalUrtConverted;

    /// @notice Conversion Start time in EpochSeconds
    uint256 public conversionStartTime;

    /// @notice ConversionPeriod in Seconds
    uint256 public conversionPeriod;

    /// @notice Conversion End time in EpochSeconds
    uint256 public conversionEndTime;
}

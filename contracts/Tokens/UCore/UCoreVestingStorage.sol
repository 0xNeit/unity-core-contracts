pragma solidity ^0.5.16;

import "../../Utils/SafeMath.sol";
import "../../Utils/IERC20.sol";

contract UCoreVestingAdminStorage {
    /**
     * @notice Administrator for this contract
     */
    address public admin;

    /**
     * @notice Pending administrator for this contract
     */
    address public pendingAdmin;

    /**
     * @notice Active brains of UCoreVesting
     */
    address public implementation;

    /**
     * @notice Pending brains of UCoreVesting
     */
    address public pendingImplementation;
}

contract UCoreVestingStorage is UCoreVestingAdminStorage {
    struct VestingRecord {
        address recipient;
        uint256 startTime;
        uint256 amount;
        uint256 withdrawnAmount;
    }

    /// @notice Guard variable for re-entrancy checks
    bool public _notEntered;

    /// @notice indicator to check if the contract is initialized
    bool public initialized;

    /// @notice The UCore TOKEN!
    IERC20 public ucore;

    /// @notice URTConversion Contract Address
    address public urtConversionAddress;

    /// @notice mapping of VestingRecord(s) for user(s)
    mapping(address => VestingRecord[]) public vestings;
}

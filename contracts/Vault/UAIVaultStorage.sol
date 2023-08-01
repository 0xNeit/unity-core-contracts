pragma solidity ^0.5.16;
import "../Utils/SafeMath.sol";
import "../Utils/IBEP20.sol";

contract UAIVaultAdminStorage {
    /**
     * @notice Administrator for this contract
     */
    address public admin;

    /**
     * @notice Pending administrator for this contract
     */
    address public pendingAdmin;

    /**
     * @notice Active brains of UAI Vault
     */
    address public uaiVaultImplementation;

    /**
     * @notice Pending brains of UAI Vault
     */
    address public pendingUAIVaultImplementation;
}

contract UAIVaultStorage is UAIVaultAdminStorage {
    /// @notice The XVS TOKEN!
    IBEP20 public xvs;

    /// @notice The UAI TOKEN!
    IBEP20 public uai;

    /// @notice Guard variable for re-entrancy checks
    bool internal _notEntered;

    /// @notice XVS balance of vault
    uint256 public xvsBalance;

    /// @notice Accumulated XVS per share
    uint256 public accXVSPerShare;

    //// pending rewards awaiting anyone to update
    uint256 public pendingRewards;

    /// @notice Info of each user.
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    // Info of each user that stakes tokens.
    mapping(address => UserInfo) public userInfo;

    /// @notice pause indicator for Vault
    bool public vaultPaused;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;
}

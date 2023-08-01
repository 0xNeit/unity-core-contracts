pragma solidity ^0.5.16;

import "../../Utils/IBEP20.sol";
import "../../Utils/SafeBEP20.sol";
import "../UCORE/IUCOREVesting.sol";
import "./URTConverterStorage.sol";
import "./URTConverterProxy.sol";

/**
 * @title Venus's URTConversion Contract
 * @author Venus
 */
contract URTConverter is URTConverterStorage {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice decimal precision for URT
    uint256 public constant urtDecimalsMultiplier = 1e18;

    /// @notice decimal precision for UCORE
    uint256 public constant ucoreDecimalsMultiplier = 1e18;

    /// @notice Emitted when an admin set conversion info
    event ConversionInfoSet(
        uint256 conversionRatio,
        uint256 conversionStartTime,
        uint256 conversionPeriod,
        uint256 conversionEndTime
    );

    /// @notice Emitted when token conversion is done
    event TokenConverted(
        address reedeemer,
        address urtAddress,
        uint256 urtAmount,
        address ucoreAddress,
        uint256 ucoreAmount
    );

    /// @notice Emitted when an admin withdraw converted token
    event TokenWithdraw(address token, address to, uint256 amount);

    /// @notice Emitted when UCOREVestingAddress is set
    event UCOREVestingSet(address ucoreVestingAddress);

    constructor() public {}

    function initialize(
        address _urtAddress,
        address _ucoreAddress,
        uint256 _conversionRatio,
        uint256 _conversionStartTime,
        uint256 _conversionPeriod
    ) public {
        require(msg.sender == admin, "only admin may initialize the URTConverter");
        require(initialized == false, "URTConverter is already initialized");

        require(_urtAddress != address(0), "urtAddress cannot be Zero");
        urt = IBEP20(_urtAddress);

        require(_ucoreAddress != address(0), "ucoreAddress cannot be Zero");
        ucore = IBEP20(_ucoreAddress);

        require(_conversionRatio > 0, "conversionRatio cannot be Zero");
        conversionRatio = _conversionRatio;

        require(_conversionStartTime >= block.timestamp, "conversionStartTime must be time in the future");
        require(_conversionPeriod > 0, "_conversionPeriod is invalid");

        conversionStartTime = _conversionStartTime;
        conversionPeriod = _conversionPeriod;
        conversionEndTime = conversionStartTime.add(conversionPeriod);
        emit ConversionInfoSet(conversionRatio, conversionStartTime, conversionPeriod, conversionEndTime);

        totalUrtConverted = 0;
        _notEntered = true;
        initialized = true;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        require(_notEntered, "re-entered");
        _notEntered = false;
        _;
        _notEntered = true; // get a gas-refund post-Istanbul
    }

    /**
     * @notice sets UCOREVestingProxy Address
     * @dev Note: If UCOREVestingProxy is not set, then Conversion is not allowed
     * @param _ucoreVestingAddress The UCOREVestingProxy Address
     */
    function setUCOREVesting(address _ucoreVestingAddress) public {
        require(msg.sender == admin, "only admin may initialize the Vault");
        require(_ucoreVestingAddress != address(0), "ucoreVestingAddress cannot be Zero");
        ucoreVesting = IUCOREVesting(_ucoreVestingAddress);
        emit UCOREVestingSet(_ucoreVestingAddress);
    }

    modifier isInitialized() {
        require(initialized == true, "URTConverter is not initialized");
        _;
    }

    function isConversionActive() public view returns (bool) {
        uint256 currentTime = block.timestamp;
        if (currentTime >= conversionStartTime && currentTime <= conversionEndTime) {
            return true;
        }
        return false;
    }

    modifier checkForActiveConversionPeriod() {
        uint256 currentTime = block.timestamp;
        require(currentTime >= conversionStartTime, "Conversion did not start yet");
        require(currentTime <= conversionEndTime, "Conversion Period Ended");
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin can");
        _;
    }

    modifier nonZeroAddress(address _address) {
        require(_address != address(0), "Address cannot be Zero");
        _;
    }

    /**
     * @notice Transfer URT and redeem UCORE
     * @dev Note: If there is not enough UCORE, we do not perform the conversion.
     * @param urtAmount The amount of URT
     */
    function convert(uint256 urtAmount) external isInitialized checkForActiveConversionPeriod nonReentrant {
        require(
            address(ucoreVesting) != address(0) && address(ucoreVesting) != DEAD_ADDRESS,
            "UCORE-Vesting Address is not set"
        );
        require(urtAmount > 0, "URT amount must be non-zero");
        totalUrtConverted = totalUrtConverted.add(urtAmount);

        uint256 redeemAmount = urtAmount.mul(conversionRatio).mul(ucoreDecimalsMultiplier).div(1e18).div(
            urtDecimalsMultiplier
        );

        emit TokenConverted(msg.sender, address(urt), urtAmount, address(ucore), redeemAmount);
        urt.safeTransferFrom(msg.sender, DEAD_ADDRESS, urtAmount);
        ucoreVesting.deposit(msg.sender, redeemAmount);
    }

    /*** Admin Functions ***/
    function _become(URTConverterProxy urtConverterProxy) public {
        require(msg.sender == urtConverterProxy.admin(), "only proxy admin can change brains");
        urtConverterProxy._acceptImplementation();
    }
}

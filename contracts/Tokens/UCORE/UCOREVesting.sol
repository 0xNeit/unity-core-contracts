pragma solidity ^0.5.16;

import "../../Utils/IBEP20.sol";
import "../../Utils/SafeBEP20.sol";
import "./UCOREVestingStorage.sol";
import "./UCOREVestingProxy.sol";

/**
 * @title UnityCore's UCOREVesting Contract
 * @author UnityCore
 */
contract UCOREVesting is UCOREVestingStorage {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    /// @notice total vesting period for 1 year in seconds
    uint256 public constant TOTAL_VESTING_TIME = 365 * 24 * 60 * 60;

    /// @notice decimal precision for UCORE
    uint256 public constant ucoreDecimalsMultiplier = 1e18;

    /// @notice Emitted when UCOREVested is claimed by recipient
    event VestedTokensClaimed(address recipient, uint256 amountClaimed);

    /// @notice Emitted when urtConversionAddress is set
    event URTConversionSet(address urtConversionAddress);

    /// @notice Emitted when UCORE is deposited for vesting
    event UCOREVested(address indexed recipient, uint256 startTime, uint256 amount, uint256 withdrawnAmount);

    /// @notice Emitted when UCORE is withdrawn by recipient
    event UCOREWithdrawn(address recipient, uint256 amount);

    modifier nonZeroAddress(address _address) {
        require(_address != address(0), "Address cannot be Zero");
        _;
    }

    constructor() public {}

    /**
     * @notice initialize UCOREVestingStorage
     * @param _ucoreAddress The UCOREToken address
     */
    function initialize(address _ucoreAddress) public {
        require(msg.sender == admin, "only admin may initialize the UCOREVesting");
        require(initialized == false, "UCOREVesting is already initialized");
        require(_ucoreAddress != address(0), "_ucoreAddress cannot be Zero");
        ucore = IBEP20(_ucoreAddress);

        _notEntered = true;
        initialized = true;
    }

    modifier isInitialized() {
        require(initialized == true, "UCOREVesting is not initialized");
        _;
    }

    /**
     * @notice sets URTConverter Address
     * @dev Note: If URTConverter is not set, then Vesting is not allowed
     * @param _urtConversionAddress The URTConverterProxy Address
     */
    function setURTConverter(address _urtConversionAddress) public {
        require(msg.sender == admin, "only admin may initialize the Vault");
        require(_urtConversionAddress != address(0), "urtConversionAddress cannot be Zero");
        urtConversionAddress = _urtConversionAddress;
        emit URTConversionSet(_urtConversionAddress);
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin can");
        _;
    }

    modifier onlyUrtConverter() {
        require(msg.sender == urtConversionAddress, "only URTConversion Address can call the function");
        _;
    }

    modifier vestingExistCheck(address recipient) {
        require(vestings[recipient].length > 0, "recipient doesnot have any vestingRecord");
        _;
    }

    /**
     * @notice Deposit UCORE for Vesting
     * @param recipient The vesting recipient
     * @param depositAmount UCORE amount for deposit
     */
    function deposit(
        address recipient,
        uint depositAmount
    ) external isInitialized onlyUrtConverter nonZeroAddress(recipient) {
        require(depositAmount > 0, "Deposit amount must be non-zero");

        VestingRecord[] storage vestingsOfRecipient = vestings[recipient];

        VestingRecord memory vesting = VestingRecord({
            recipient: recipient,
            startTime: getCurrentTime(),
            amount: depositAmount,
            withdrawnAmount: 0
        });

        vestingsOfRecipient.push(vesting);

        emit UCOREVested(recipient, vesting.startTime, vesting.amount, vesting.withdrawnAmount);
    }

    /**
     * @notice Withdraw Vested UCORE of recipient
     */
    function withdraw() external isInitialized vestingExistCheck(msg.sender) {
        address recipient = msg.sender;
        VestingRecord[] storage vestingsOfRecipient = vestings[recipient];
        uint256 vestingCount = vestingsOfRecipient.length;
        uint256 totalWithdrawableAmount = 0;

        for (uint i = 0; i < vestingCount; ++i) {
            VestingRecord storage vesting = vestingsOfRecipient[i];
            (, uint256 toWithdraw) = calculateWithdrawableAmount(
                vesting.amount,
                vesting.startTime,
                vesting.withdrawnAmount
            );
            if (toWithdraw > 0) {
                totalWithdrawableAmount = totalWithdrawableAmount.add(toWithdraw);
                vesting.withdrawnAmount = vesting.withdrawnAmount.add(toWithdraw);
            }
        }

        if (totalWithdrawableAmount > 0) {
            uint256 ucoreBalance = ucore.balanceOf(address(this));
            require(ucoreBalance >= totalWithdrawableAmount, "Insufficient UCORE for withdrawal");
            emit UCOREWithdrawn(recipient, totalWithdrawableAmount);
            ucore.safeTransfer(recipient, totalWithdrawableAmount);
        }
    }

    /**
     * @notice get Withdrawable UCORE Amount
     * @param recipient The vesting recipient
     * @dev returns A tuple with totalWithdrawableAmount , totalVestedAmount and totalWithdrawnAmount
     */
    function getWithdrawableAmount(
        address recipient
    )
        public
        view
        isInitialized
        nonZeroAddress(recipient)
        vestingExistCheck(recipient)
        returns (uint256 totalWithdrawableAmount, uint256 totalVestedAmount, uint256 totalWithdrawnAmount)
    {
        VestingRecord[] storage vestingsOfRecipient = vestings[recipient];
        uint256 vestingCount = vestingsOfRecipient.length;

        for (uint i = 0; i < vestingCount; i++) {
            VestingRecord storage vesting = vestingsOfRecipient[i];
            (uint256 vestedAmount, uint256 toWithdraw) = calculateWithdrawableAmount(
                vesting.amount,
                vesting.startTime,
                vesting.withdrawnAmount
            );
            totalVestedAmount = totalVestedAmount.add(vestedAmount);
            totalWithdrawableAmount = totalWithdrawableAmount.add(toWithdraw);
            totalWithdrawnAmount = totalWithdrawnAmount.add(vesting.withdrawnAmount);
        }

        return (totalWithdrawableAmount, totalVestedAmount, totalWithdrawnAmount);
    }

    /**
     * @notice get Withdrawable UCORE Amount
     * @param amount Amount deposited for vesting
     * @param vestingStartTime time in epochSeconds at the time of vestingDeposit
     * @param withdrawnAmount UCOREAmount withdrawn from VestedAmount
     * @dev returns A tuple with vestedAmount and withdrawableAmount
     */
    function calculateWithdrawableAmount(
        uint256 amount,
        uint256 vestingStartTime,
        uint256 withdrawnAmount
    ) internal view returns (uint256, uint256) {
        uint256 vestedAmount = calculateVestedAmount(amount, vestingStartTime, getCurrentTime());
        uint toWithdraw = vestedAmount.sub(withdrawnAmount);
        return (vestedAmount, toWithdraw);
    }

    /**
     * @notice calculate total vested amount
     * @param vestingAmount Amount deposited for vesting
     * @param vestingStartTime time in epochSeconds at the time of vestingDeposit
     * @param currentTime currentTime in epochSeconds
     * @return Total UCORE amount vested
     */
    function calculateVestedAmount(
        uint256 vestingAmount,
        uint256 vestingStartTime,
        uint256 currentTime
    ) internal view returns (uint256) {
        if (currentTime < vestingStartTime) {
            return 0;
        } else if (currentTime > vestingStartTime.add(TOTAL_VESTING_TIME)) {
            return vestingAmount;
        } else {
            return (vestingAmount.mul(currentTime.sub(vestingStartTime))).div(TOTAL_VESTING_TIME);
        }
    }

    /**
     * @notice current block timestamp
     * @return blocktimestamp
     */
    function getCurrentTime() public view returns (uint256) {
        return block.timestamp;
    }

    /*** Admin Functions ***/
    function _become(UCOREVestingProxy ucoreVestingProxy) public {
        require(msg.sender == ucoreVestingProxy.admin(), "only proxy admin can change brains");
        ucoreVestingProxy._acceptImplementation();
    }
}

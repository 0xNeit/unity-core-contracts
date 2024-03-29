pragma solidity 0.5.16;

import "../Utils/SafeBEP20.sol";
import "../Utils/IBEP20.sol";
import "./UAIVaultStorage.sol";
import "./UAIVaultErrorReporter.sol";
import "../Governance/AccessControlledV5.sol";

interface IUAIVaultProxy {
    function _acceptImplementation() external returns (uint);

    function admin() external returns (address);
}

contract UAIVault is UAIVaultStorage, AccessControlledV5 {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    /// @notice Event emitted when UAI deposit
    event Deposit(address indexed user, uint256 amount);

    /// @notice Event emitted when UAI withrawal
    event Withdraw(address indexed user, uint256 amount);

    /// @notice Event emitted when vault is paused
    event VaultPaused(address indexed admin);

    /// @notice Event emitted when vault is resumed after pause
    event VaultResumed(address indexed admin);

    constructor() public {
        admin = msg.sender;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin can");
        _;
    }

    /*** Reentrancy Guard ***/

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
     * @dev Prevents functions to execute when vault is paused.
     */
    modifier isActive() {
        require(!vaultPaused, "Vault is paused");
        _;
    }

    /**
     * @notice Pause vault
     */
    function pause() external {
        _checkAccessAllowed("pause()");
        require(!vaultPaused, "Vault is already paused");
        vaultPaused = true;
        emit VaultPaused(msg.sender);
    }

    /**
     * @notice Resume vault
     */
    function resume() external {
        _checkAccessAllowed("resume()");
        require(vaultPaused, "Vault is not paused");
        vaultPaused = false;
        emit VaultResumed(msg.sender);
    }

    /**
     * @notice Deposit UAI to UAIVault for UCORE allocation
     * @param _amount The amount to deposit to vault
     */
    function deposit(uint256 _amount) external nonReentrant isActive {
        UserInfo storage user = userInfo[msg.sender];

        updateVault();

        // Transfer pending tokens to user
        updateAndPayOutPending(msg.sender);

        // Transfer in the amounts from user
        if (_amount > 0) {
            uai.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }

        user.rewardDebt = user.amount.mul(accUCOREPerShare).div(1e18);
        emit Deposit(msg.sender, _amount);
    }

    /**
     * @notice Withdraw UAI from UAIVault
     * @param _amount The amount to withdraw from vault
     */
    function withdraw(uint256 _amount) external nonReentrant isActive {
        _withdraw(msg.sender, _amount);
    }

    /**
     * @notice Claim UCORE from UAIVault
     */
    function claim() external nonReentrant isActive {
        _withdraw(msg.sender, 0);
    }

    /**
     * @notice Claim UCORE from UAIVault
     * @param account The account for which to claim UCORE
     */
    function claim(address account) external nonReentrant isActive {
        _withdraw(account, 0);
    }

    /**
     * @notice Low level withdraw function
     * @param account The account to withdraw from vault
     * @param _amount The amount to withdraw from vault
     */
    function _withdraw(address account, uint256 _amount) internal {
        UserInfo storage user = userInfo[account];
        require(user.amount >= _amount, "withdraw: not good");

        updateVault();
        updateAndPayOutPending(account); // Update balances of account this is not withdrawal but claiming UCORE farmed

        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            uai.safeTransfer(address(account), _amount);
        }
        user.rewardDebt = user.amount.mul(accUCOREPerShare).div(1e18);

        emit Withdraw(account, _amount);
    }

    /**
     * @notice View function to see pending UCORE on frontend
     * @param _user The user to see pending UCORE
     * @return Amount of UCORE the user can claim
     */
    function pendingUCORE(address _user) public view returns (uint256) {
        UserInfo storage user = userInfo[_user];

        return user.amount.mul(accUCOREPerShare).div(1e18).sub(user.rewardDebt);
    }

    /**
     * @notice Update and pay out pending UCORE to user
     * @param account The user to pay out
     */
    function updateAndPayOutPending(address account) internal {
        uint256 pending = pendingUCORE(account);

        if (pending > 0) {
            safeUCORETransfer(account, pending);
        }
    }

    /**
     * @notice Safe UCORE transfer function, just in case if rounding error causes pool to not have enough UCORE
     * @param _to The address that UCORE to be transfered
     * @param _amount The amount that UCORE to be transfered
     */
    function safeUCORETransfer(address _to, uint256 _amount) internal {
        uint256 ucoreBal = ucore.balanceOf(address(this));

        if (_amount > ucoreBal) {
            ucore.transfer(_to, ucoreBal);
            ucoreBalance = ucore.balanceOf(address(this));
        } else {
            ucore.transfer(_to, _amount);
            ucoreBalance = ucore.balanceOf(address(this));
        }
    }

    /**
     * @notice Function that updates pending rewards
     */
    function updatePendingRewards() public isActive {
        uint256 newRewards = ucore.balanceOf(address(this)).sub(ucoreBalance);

        if (newRewards > 0) {
            ucoreBalance = ucore.balanceOf(address(this)); // If there is no change the balance didn't change
            pendingRewards = pendingRewards.add(newRewards);
        }
    }

    /**
     * @notice Update reward variables to be up-to-date
     */
    function updateVault() internal {
        updatePendingRewards();

        uint256 uaiBalance = uai.balanceOf(address(this));
        if (uaiBalance == 0) {
            // avoids division by 0 errors
            return;
        }

        accUCOREPerShare = accUCOREPerShare.add(pendingRewards.mul(1e18).div(uaiBalance));
        pendingRewards = 0;
    }

    /*** Admin Functions ***/

    function _become(IUAIVaultProxy uaiVaultProxy) external {
        require(msg.sender == uaiVaultProxy.admin(), "only proxy admin can change brains");
        require(uaiVaultProxy._acceptImplementation() == 0, "change not authorized");
    }

    function setUcoreInfo(address _ucore, address _uai) external onlyAdmin {
        require(_ucore != address(0) && _uai != address(0), "addresses must not be zero");
        require(address(ucore) == address(0) && address(uai) == address(0), "addresses already set");
        ucore = IBEP20(_ucore);
        uai = IBEP20(_uai);

        _notEntered = true;
    }

    /**
     * @notice Sets the address of the access control of this contract
     * @dev Admin function to set the access control address
     * @param newAccessControlAddress New address for the access control
     */
    function setAccessControl(address newAccessControlAddress) external onlyAdmin {
        _setAccessControlManager(newAccessControlAddress);
    }
}

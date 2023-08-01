pragma solidity ^0.5.16;

import "../UCOREVault/UCOREVault.sol";
import "../Utils/IBEP20.sol";

contract UCOREStakingLens {
    /**
     * @notice Get the UCORE stake balance of an account
     * @param account The address of the account to check
     * @param ucoreAddress The address of the UCOREToken
     * @param ucoreVaultProxyAddress The address of the UCOREVaultProxy
     * @return stakedAmount The balance that user staked
     * @return pendingWithdrawalAmount pending withdrawal amount of user.
     */
    function getStakedData(
        address account,
        address ucoreAddress,
        address ucoreVaultProxyAddress
    ) external view returns (uint256 stakedAmount, uint256 pendingWithdrawalAmount) {
        UCOREVault ucoreVaultInstance = UCOREVault(ucoreVaultProxyAddress);
        uint256 poolLength = ucoreVaultInstance.poolLength(ucoreAddress);

        for (uint256 pid = 0; pid < poolLength; ++pid) {
            (IBEP20 token, , , , ) = ucoreVaultInstance.poolInfos(ucoreAddress, pid);
            if (address(token) == address(ucoreAddress)) {
                // solhint-disable-next-line no-unused-vars
                (uint256 userAmount, uint256 userRewardDebt, uint256 userPendingWithdrawals) = ucoreVaultInstance
                    .getUserInfo(ucoreAddress, pid, account);
                stakedAmount = userAmount;
                pendingWithdrawalAmount = userPendingWithdrawals;
                break;
            }
        }

        return (stakedAmount, pendingWithdrawalAmount);
    }
}

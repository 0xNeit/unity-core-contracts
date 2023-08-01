pragma solidity ^0.5.16;

import "../../contracts/URTVault/URTVault.sol";

contract URTVaultHarness is URTVault {
    uint public blockNumber;

    constructor() public URTVault() {}

    function overrideInterestRatePerBlock(uint256 _interestRatePerBlock) public {
        interestRatePerBlock = _interestRatePerBlock;
    }

    function balanceOfUser() public view returns (uint256, address) {
        uint256 urtBalanceOfUser = urt.balanceOf(msg.sender);
        return (urtBalanceOfUser, msg.sender);
    }

    function harnessFastForward(uint256 blocks) public returns (uint256) {
        blockNumber += blocks;
        return blockNumber;
    }

    function setBlockNumber(uint256 number) public {
        blockNumber = number;
    }

    function getBlockNumber() public view returns (uint256) {
        return blockNumber;
    }
}

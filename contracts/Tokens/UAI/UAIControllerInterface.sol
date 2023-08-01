pragma solidity ^0.5.16;

import "../VirtualTokens/VToken.sol";

contract UAIControllerInterface {
    function getUAIAddress() public view returns (address);

    function getMintableUAI(address minter) public view returns (uint, uint);

    function mintUAI(address minter, uint mintUAIAmount) external returns (uint);

    function repayUAI(address repayer, uint repayUAIAmount) external returns (uint);

    function liquidateUAI(
        address borrower,
        uint repayAmount,
        VTokenInterface vTokenCollateral
    ) external returns (uint, uint);

    function _initializeUcoreUAIState(uint blockNumber) external returns (uint);

    function updateUcoreUAIMintIndex() external returns (uint);

    function calcDistributeUAIMinterUcore(address uaiMinter) external returns (uint, uint, uint, uint);

    function getUAIRepayAmount(address account) public view returns (uint);
}

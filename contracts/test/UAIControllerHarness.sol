pragma solidity ^0.5.16;

import "../Tokens/UAI/UAIController.sol";

contract UAIControllerHarness is UAIController {
    address internal uaiAddress;
    uint public blockNumber;
    uint public blocksPerYear;

    constructor() public UAIController() {
        admin = msg.sender;
    }

    function setUcoreUAIState(uint224 index, uint32 blockNumber_) public {
        ucoreUAIState.index = index;
        ucoreUAIState.block = blockNumber_;
    }

    function setUAIAddress(address uaiAddress_) public {
        uaiAddress = uaiAddress_;
    }

    function getUAIAddress() public view returns (address) {
        return uaiAddress;
    }

    function harnessRepayUAIFresh(address payer, address account, uint repayAmount) public returns (uint) {
        (uint err, ) = repayUAIFresh(payer, account, repayAmount);
        return err;
    }

    function harnessLiquidateUAIFresh(
        address liquidator,
        address borrower,
        uint repayAmount,
        VToken vTokenCollateral
    ) public returns (uint) {
        (uint err, ) = liquidateUAIFresh(liquidator, borrower, repayAmount, vTokenCollateral);
        return err;
    }

    function harnessFastForward(uint blocks) public returns (uint) {
        blockNumber += blocks;
        return blockNumber;
    }

    function harnessSetBlockNumber(uint newBlockNumber) public {
        blockNumber = newBlockNumber;
    }

    function setBlockNumber(uint number) public {
        blockNumber = number;
    }

    function setBlocksPerYear(uint number) public {
        blocksPerYear = number;
    }

    function getBlockNumber() public view returns (uint) {
        return blockNumber;
    }

    function getBlocksPerYear() public view returns (uint) {
        return blocksPerYear;
    }
}

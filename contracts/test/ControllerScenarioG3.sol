pragma solidity ^0.5.16;

import "../Controller/ControllerG3.sol";

contract ControllerScenarioG3 is ControllerG3 {
    uint public blockNumber;

    constructor() public ControllerG3() {}

    function fastForward(uint blocks) public returns (uint) {
        blockNumber += blocks;
        return blockNumber;
    }

    function setBlockNumber(uint number) public {
        blockNumber = number;
    }

    function membershipLength(VToken vToken) public view returns (uint) {
        return accountAssets[address(vToken)].length;
    }

    function unlist(VToken vToken) public {
        markets[address(vToken)].isListed = false;
    }

    function setUcoreSpeed(address vToken, uint ucoreSpeed) public {
        ucoreSpeeds[vToken] = ucoreSpeed;
    }
}

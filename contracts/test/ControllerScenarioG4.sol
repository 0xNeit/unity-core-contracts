pragma solidity ^0.5.16;

import "../Controller/ControllerG4.sol";

contract ControllerScenarioG4 is ControllerG4 {
    uint public blockNumber;

    constructor() public ControllerG4() {}

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

pragma solidity ^0.5.16;

import "../../contracts/Controller/ControllerG5.sol";

contract ControllerScenarioG5 is ControllerG5 {
    uint public blockNumber;

    constructor() public ControllerG5() {}

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

    function setVenusSpeed(address vToken, uint venusSpeed) public {
        venusSpeeds[vToken] = venusSpeed;
    }
}

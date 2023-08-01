pragma solidity ^0.5.16;

import "../Tokens/UAI/UAIController.sol";
import "./ControllerScenario.sol";

contract UAIControllerScenario is UAIController {
    uint internal blockNumber;
    address public ucoreAddress;
    address public uaiAddress;

    constructor() public UAIController() {}

    function setUAIAddress(address uaiAddress_) public {
        uaiAddress = uaiAddress_;
    }

    function getUAIAddress() public view returns (address) {
        return uaiAddress;
    }

    function setBlockNumber(uint number) public {
        blockNumber = number;
    }

    function getBlockNumber() public view returns (uint) {
        return blockNumber;
    }
}

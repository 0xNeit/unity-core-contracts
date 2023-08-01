pragma solidity ^0.5.16;

interface IController {
    function refreshVenusSpeeds() external;
}

contract RefreshSpeedsProxy {
    constructor(address controller) public {
        IController(controller).refreshVenusSpeeds();
    }
}

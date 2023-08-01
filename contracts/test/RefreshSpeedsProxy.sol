pragma solidity ^0.5.16;

interface IController {
    function refreshUcoreSpeeds() external;
}

contract RefreshSpeedsProxy {
    constructor(address controller) public {
        IController(controller).refreshUcoreSpeeds();
    }
}

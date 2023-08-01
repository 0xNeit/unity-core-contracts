pragma solidity ^0.5.16;

import "../../contracts/Tokens/URT/URTConverter.sol";

contract URTConverterHarness is URTConverter {
    constructor() public URTConverter() {
        admin = msg.sender;
    }

    function balanceOfUser() public view returns (uint256, address) {
        uint256 urtBalanceOfUser = urt.balanceOf(msg.sender);
        return (urtBalanceOfUser, msg.sender);
    }

    function setConversionRatio(uint256 _conversionRatio) public onlyAdmin {
        conversionRatio = _conversionRatio;
    }

    function setConversionTimeline(uint256 _conversionStartTime, uint256 _conversionPeriod) public onlyAdmin {
        conversionStartTime = _conversionStartTime;
        conversionPeriod = _conversionPeriod;
        conversionEndTime = conversionStartTime.add(conversionPeriod);
    }

    function getXVSRedeemedAmount(uint256 urtAmount) public view returns (uint256) {
        return urtAmount.mul(conversionRatio).mul(xvsDecimalsMultiplier).div(1e18).div(urtDecimalsMultiplier);
    }
}

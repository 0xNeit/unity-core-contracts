pragma solidity ^0.5.16;
pragma experimental ABIEncoderV2;

import "../Governance/GovernorAlpha.sol";

contract GovernorAlphaHarness is GovernorAlpha {
    constructor(address timelock_, address ucore_, address guardian_) public GovernorAlpha(timelock_, ucore_, guardian_) {}

    function votingPeriod() public pure returns (uint) {
        return 240;
    }
}

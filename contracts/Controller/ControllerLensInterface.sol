pragma solidity ^0.5.16;
pragma experimental ABIEncoderV2;

import "../Tokens/VirtualTokens/VToken.sol";

interface ControllerLensInterface {
    function liquidateCalculateSeizeTokens(
        address controller,
        address vTokenBorrowed,
        address vTokenCollateral,
        uint actualRepayAmount
    ) external view returns (uint, uint);

    function liquidateUAICalculateSeizeTokens(
        address controller,
        address vTokenCollateral,
        uint actualRepayAmount
    ) external view returns (uint, uint);

    function getHypotheticalAccountLiquidity(
        address controller,
        address account,
        VToken vTokenModify,
        uint redeemTokens,
        uint borrowAmount
    ) external view returns (uint, uint, uint);
}

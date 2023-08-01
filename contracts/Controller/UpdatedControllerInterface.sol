pragma solidity ^0.5.16;

import "../Tokens/VTokens/VToken.sol";
import "../Oracle/PriceOracle.sol";

contract UpdatedControllerInterfaceG1 {
    /// @notice Indicator that this is a Controller contract (for inspection)
    bool public constant isController = true;

    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata vTokens) external returns (uint[] memory);

    function exitMarket(address vToken) external returns (uint);

    /*** Policy Hooks ***/

    function mintAllowed(address vToken, address minter, uint mintAmount) external returns (uint);

    function redeemAllowed(address vToken, address redeemer, uint redeemTokens) external returns (uint);

    function borrowAllowed(address vToken, address borrower, uint borrowAmount) external returns (uint);

    function repayBorrowAllowed(
        address vToken,
        address payer,
        address borrower,
        uint repayAmount
    ) external returns (uint);

    function liquidateBorrowAllowed(
        address vTokenBorrowed,
        address vTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount
    ) external returns (uint);

    function seizeAllowed(
        address vTokenCollateral,
        address vTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external returns (uint);

    function transferAllowed(address vToken, address src, address dst, uint transferTokens) external returns (uint);

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(
        address vTokenBorrowed,
        address vTokenCollateral,
        uint repayAmount
    ) external view returns (uint, uint);

    function setMintedUAIOf(address owner, uint amount) external returns (uint);
}

contract UpdatedControllerInterfaceG2 is UpdatedControllerInterfaceG1 {
    function liquidateUAICalculateSeizeTokens(
        address vTokenCollateral,
        uint repayAmount
    ) external view returns (uint, uint);
}

contract UpdatedControllerInterface is UpdatedControllerInterfaceG2 {
    function markets(address) external view returns (bool, uint);

    function oracle() external view returns (PriceOracle);

    function getAccountLiquidity(address) external view returns (uint, uint, uint);

    function getAssetsIn(address) external view returns (VToken[] memory);

    function claimUcore(address) external;

    function ucoreAccrued(address) external view returns (uint);

    function ucoreSpeeds(address) external view returns (uint);

    function getAllMarkets() external view returns (VToken[] memory);

    function ucoreSupplierIndex(address, address) external view returns (uint);

    function ucoreInitialIndex() external view returns (uint224);

    function ucoreBorrowerIndex(address, address) external view returns (uint);

    function ucoreBorrowState(address) external view returns (uint224, uint32);

    function ucoreSupplyState(address) external view returns (uint224, uint32);
}

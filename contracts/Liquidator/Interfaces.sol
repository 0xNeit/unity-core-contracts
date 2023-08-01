pragma solidity 0.8.13;

import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

interface IVToken is IERC20Upgradeable {}

interface IVERC20 is IVToken {
    function underlying() external view returns (address);

    function liquidateBorrow(
        address borrower,
        uint256 repayAmount,
        IVToken vTokenCollateral
    ) external returns (uint256);
}

interface IVCORE is IVToken {
    function liquidateBorrow(address borrower, IVToken vTokenCollateral) external payable;
}

interface IUAIController {
    function liquidateUAI(
        address borrower,
        uint256 repayAmount,
        IVToken vTokenCollateral
    ) external returns (uint256, uint256);

    function getUAIAddress() external view returns (address);
}

interface IController {
    function liquidationIncentiveMantissa() external view returns (uint256);

    function uaiController() external view returns (IUAIController);
}

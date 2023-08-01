// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IPancakeSwapV2Router.sol";
import "./interfaces/IVtoken.sol";
import "./RouterHelper.sol";
import "./interfaces/IVCORE.sol";
import "./interfaces/IVtoken.sol";
import "./interfaces/InterfaceController.sol";

/**
 * @title Venus's Pancake Swap Integration Contract
 * @notice This contracts allows users to swap a token for another one and supply/repay with the latter.
 * @dev For all functions that do not swap native CORE, user must approve this contract with the amount, prior the calling the swap function.
 * @author 0xlucian
 */

contract SwapRouter is Ownable2Step, RouterHelper, IPancakeSwapV2Router {
    using SafeERC20 for IERC20;

    address public immutable controllerAddress;

    uint256 private constant _NOT_ENTERED = 1;

    uint256 private constant _ENTERED = 2;

    address public vCOREAddress;

    /**
     * @dev Guard variable for re-entrancy checks
     */
    uint256 internal _status;

    // ***************
    // ** MODIFIERS **
    // ***************
    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) {
            revert SwapDeadlineExpire(deadline, block.timestamp);
        }
        _;
    }

    modifier ensurePath(address[] calldata path) {
        if (path.length < 2) {
            revert InvalidPath();
        }
        _;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        if (_status == _ENTERED) {
            revert ReentrantCheck();
        }
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    /// @notice event emitted on sweep token success
    event SweepToken(address indexed token, address indexed to, uint256 sweepAmount);

    /// @notice event emitted on vCOREAddress update
    event VCOREAddressUpdated(address indexed oldAddress, address indexed newAddress);

    // *********************
    // **** CONSTRUCTOR ****
    // *********************

    /// @notice Constructor for the implementation contract. Sets immutable variables.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address WCORE_,
        address factory_,
        address _controllerAddress,
        address _vCOREAddress
    ) RouterHelper(WCORE_, factory_) {
        if (_controllerAddress == address(0) || _vCOREAddress == address(0)) {
            revert ZeroAddress();
        }
        controllerAddress = _controllerAddress;
        _status = _NOT_ENTERED;
        vCOREAddress = _vCOREAddress;
    }

    receive() external payable {
        assert(msg.sender == WCORE); // only accept CORE via fallback from the WCORE contract
    }

    // ****************************
    // **** EXTERNAL FUNCTIONS ****
    // ****************************

    /**
     * @notice Setter for the vCORE address.
     * @param _vCOREAddress Address of the CORE vToken to update.
     */
    function setVCOREAddress(address _vCOREAddress) external onlyOwner {
        if (_vCOREAddress == address(0)) {
            revert ZeroAddress();
        }

        _isVTokenListed(_vCOREAddress);

        address oldAddress = vCOREAddress;
        vCOREAddress = _vCOREAddress;

        emit VCOREAddressUpdated(oldAddress, vCOREAddress);
    }

    /**
     * @notice Swap token A for token B and supply to a Venus market
     * @param vTokenAddress The address of the vToken contract for supplying assets.
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     */
    function swapExactTokensForTokensAndSupply(
        address vTokenAddress,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureVTokenChecks(vTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactTokensForTokens(amountIn, amountOutMin, path, address(this), TypesOfTokens.NON_SUPPORTING_FEE);
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _supply(lastAsset, vTokenAddress, swapAmount);
    }

    /**
     * @notice Swap deflationary (a small amount of fee is deducted at the time of transfer of token) token A for token B and supply to a Venus market.
     * @param vTokenAddress The address of the vToken contract for supplying assets.
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     */
    function swapExactTokensForTokensAndSupplyAtSupportingFee(
        address vTokenAddress,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureVTokenChecks(vTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactTokensForTokens(amountIn, amountOutMin, path, address(this), TypesOfTokens.SUPPORTING_FEE);
        uint256 swapAmount = _checkForAmountOut(lastAsset, balanceBefore, amountOutMin, address(this));
        _supply(lastAsset, vTokenAddress, swapAmount);
    }

    /**
     * @notice Swap CORE for another token and supply to a Venus market
     * @dev The amount to be swapped is obtained from the msg.value, since we are swapping CORE
     * @param vTokenAddress The address of the vToken contract for supplying assets.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native CORE the first asset in path array should be the wCORE address
     */
    function swapExactCOREForTokensAndSupply(
        address vTokenAddress,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureVTokenChecks(vTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactCOREForTokens(amountOutMin, path, address(this), TypesOfTokens.NON_SUPPORTING_FEE);
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _supply(lastAsset, vTokenAddress, swapAmount);
    }

    /**
     * @notice Swap CORE for another deflationary token (a small amount of fee is deducted at the time of transfer of token) and supply to a Venus market
     * @dev The amount to be swapped is obtained from the msg.value, since we are swapping CORE
     * @param vTokenAddress The address of the vToken contract for supplying assets.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native CORE the first asset in path array should be the wCORE address
     */
    function swapExactCOREForTokensAndSupplyAtSupportingFee(
        address vTokenAddress,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureVTokenChecks(vTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactCOREForTokens(amountOutMin, path, address(this), TypesOfTokens.SUPPORTING_FEE);
        uint256 swapAmount = _checkForAmountOut(lastAsset, balanceBefore, amountOutMin, address(this));
        _supply(lastAsset, vTokenAddress, swapAmount);
    }

    /**
     * @notice Swap tokens for Exact tokens and supply to a Venus market
     * @param vTokenAddress The address of the vToken contract for supplying assets.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native CORE the first asset in path array should be the wCORE address
     */
    function swapTokensForExactTokensAndSupply(
        address vTokenAddress,
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureVTokenChecks(vTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapTokensForExactTokens(amountOut, amountInMax, path, address(this));
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _supply(lastAsset, vTokenAddress, swapAmount);
    }

    /**
     * @notice Swap CORE for Exact tokens and supply to a Venus market
     * @param vTokenAddress The address of the vToken contract for supplying assets.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native CORE the first asset in path array should be the wCORE address
     */
    function swapCOREForExactTokensAndSupply(
        address vTokenAddress,
        uint256 amountOut,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureVTokenChecks(vTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapCOREForExactTokens(amountOut, path, address(this));
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _supply(lastAsset, vTokenAddress, swapAmount);
    }

    /**
     * @notice Swap Exact tokens for CORE and supply to a Venus market
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native CORE the first asset in path array should be the wCORE address
     */
    function swapExactTokensForCOREAndSupply(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        _swapExactTokensForCORE(amountIn, amountOutMin, path, address(this), TypesOfTokens.NON_SUPPORTING_FEE);
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        _mintVCOREandTransfer(swapAmount);
    }

    /**
     * @notice Swap Exact deflationary tokens (a small amount of fee is deducted at the time of transfer of tokens) for CORE and supply to a Venus market
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native CORE the first asset in path array should be the wCORE address
     */
    function swapExactTokensForCOREAndSupplyAtSupportingFee(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        _swapExactTokensForCORE(amountIn, amountOutMin, path, address(this), TypesOfTokens.SUPPORTING_FEE);
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        if (swapAmount < amountOutMin) {
            revert SwapAmountLessThanAmountOutMin(swapAmount, amountOutMin);
        }
        _mintVCOREandTransfer(swapAmount);
    }

    /**
     * @notice Swap tokens for Exact CORE and supply to a Venus market
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native CORE the first asset in path array should be the wCORE address
     */
    function swapTokensForExactCOREAndSupply(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        _swapTokensForExactCORE(amountOut, amountInMax, path, address(this));
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        _mintVCOREandTransfer(swapAmount);
    }

    /**
     * @notice Swap token A for token B and repay a borrow from a Venus market
     * @param vTokenAddress The address of the vToken contract to repay.
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive (and repay)
     */
    function swapExactTokensForTokensAndRepay(
        address vTokenAddress,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureVTokenChecks(vTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactTokensForTokens(amountIn, amountOutMin, path, address(this), TypesOfTokens.NON_SUPPORTING_FEE);
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _repay(lastAsset, vTokenAddress, swapAmount);
    }

    /**
     * @notice Swap deflationary token (a small amount of fee is deducted at the time of transfer of token) token A for token B and repay a borrow from a Venus market
     * @param vTokenAddress The address of the vToken contract to repay.
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive (and repay)
     */
    function swapExactTokensForTokensAndRepayAtSupportingFee(
        address vTokenAddress,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureVTokenChecks(vTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactTokensForTokens(amountIn, amountOutMin, path, address(this), TypesOfTokens.SUPPORTING_FEE);
        uint256 swapAmount = _checkForAmountOut(lastAsset, balanceBefore, amountOutMin, address(this));
        _repay(lastAsset, vTokenAddress, swapAmount);
    }

    /**
     * @notice Swap CORE for another token and repay a borrow from a Venus market
     * @dev The amount to be swapped is obtained from the msg.value, since we are swapping CORE
     * @param vTokenAddress The address of the vToken contract to repay.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered so the swap path tokens are listed first and last asset is the token we receive
     */
    function swapExactCOREForTokensAndRepay(
        address vTokenAddress,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureVTokenChecks(vTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactCOREForTokens(amountOutMin, path, address(this), TypesOfTokens.NON_SUPPORTING_FEE);
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _repay(lastAsset, vTokenAddress, swapAmount);
    }

    /**
     * @notice Swap CORE for another deflationary token (a small amount of fee is deducted at the time of transfer of token) and repay a borrow from a Venus market
     * @dev The amount to be swapped is obtained from the msg.value, since we are swapping CORE
     * @param vTokenAddress The address of the vToken contract to repay.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered so the swap path tokens are listed first and last asset is the token we receive
     */
    function swapExactCOREForTokensAndRepayAtSupportingFee(
        address vTokenAddress,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureVTokenChecks(vTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactCOREForTokens(amountOutMin, path, address(this), TypesOfTokens.SUPPORTING_FEE);
        uint256 swapAmount = _checkForAmountOut(lastAsset, balanceBefore, amountOutMin, address(this));
        _repay(lastAsset, vTokenAddress, swapAmount);
    }

    /**
     * @notice Swap tokens for Exact tokens and repay to a Venus market
     * @param vTokenAddress The address of the vToken contract for supplying assets.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native CORE the first asset in path array should be the wCORE address
     */
    function swapTokensForExactTokensAndRepay(
        address vTokenAddress,
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureVTokenChecks(vTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapTokensForExactTokens(amountOut, amountInMax, path, address(this));
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _repay(lastAsset, vTokenAddress, swapAmount);
    }

    /**
     * @notice Swap tokens for full tokens debt and repay to a Venus market
     * @param vTokenAddress The address of the vToken contract for supplying assets.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native CORE the first asset in path array should be the wCORE address
     */
    function swapTokensForFullTokenDebtAndRepay(
        address vTokenAddress,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureVTokenChecks(vTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        uint256 amountOut = IVToken(vTokenAddress).borrowBalanceCurrent(msg.sender);
        _swapTokensForExactTokens(amountOut, amountInMax, path, address(this));
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _repay(lastAsset, vTokenAddress, swapAmount);
    }

    /**
     * @notice Swap CORE for Exact tokens and repay to a Venus market
     * @param vTokenAddress The address of the vToken contract for supplying assets.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native CORE the first asset in path array should be the wCORE address
     */
    function swapCOREForExactTokensAndRepay(
        address vTokenAddress,
        uint256 amountOut,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureVTokenChecks(vTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapCOREForExactTokens(amountOut, path, address(this));
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _repay(lastAsset, vTokenAddress, swapAmount);
    }

    /**
     * @notice Swap CORE for Exact tokens and repay to a Venus market
     * @param vTokenAddress The address of the vToken contract for supplying assets.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native CORE the first asset in path array should be the wCORE address
     */
    function swapCOREForFullTokenDebtAndRepay(
        address vTokenAddress,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureVTokenChecks(vTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        uint256 amountOut = IVToken(vTokenAddress).borrowBalanceCurrent(msg.sender);
        _swapCOREForExactTokens(amountOut, path, address(this));
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _repay(lastAsset, vTokenAddress, swapAmount);
    }

    /**
     * @notice Swap Exact tokens for CORE and repay to a Venus market
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native CORE the first asset in path array should be the wCORE address
     */
    function swapExactTokensForCOREAndRepay(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        _swapExactTokensForCORE(amountIn, amountOutMin, path, address(this), TypesOfTokens.NON_SUPPORTING_FEE);
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        IVCORE(vCOREAddress).repayBorrowBehalf{ value: swapAmount }(msg.sender);
    }

    /**
     * @notice Swap Exact deflationary tokens (a small amount of fee is deducted at the time of transfer of tokens) for CORE and repay to a Venus market
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native CORE the first asset in path array should be the wCORE address
     */
    function swapExactTokensForCOREAndRepayAtSupportingFee(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        _swapExactTokensForCORE(amountIn, amountOutMin, path, address(this), TypesOfTokens.SUPPORTING_FEE);
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        if (swapAmount < amountOutMin) {
            revert SwapAmountLessThanAmountOutMin(swapAmount, amountOutMin);
        }
        IVCORE(vCOREAddress).repayBorrowBehalf{ value: swapAmount }(msg.sender);
    }

    /**
     * @notice Swap tokens for Exact CORE and repay to a Venus market
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native CORE the first asset in path array should be the wCORE address
     */
    function swapTokensForExactCOREAndRepay(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        _swapTokensForExactCORE(amountOut, amountInMax, path, address(this));
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        IVCORE(vCOREAddress).repayBorrowBehalf{ value: swapAmount }(msg.sender);
    }

    /**
     * @notice Swap tokens for Exact CORE and repay to a Venus market
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native CORE the first asset in path array should be the wCORE address
     */
    function swapTokensForFullCOREDebtAndRepay(
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        uint256 amountOut = IVToken(vCOREAddress).borrowBalanceCurrent(msg.sender);
        _swapTokensForExactCORE(amountOut, amountInMax, path, address(this));
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        IVCORE(vCOREAddress).repayBorrowBehalf{ value: swapAmount }(msg.sender);
    }

    /**
     * @notice Swaps an exact amount of input tokens for as many output tokens as possible,
     *         along the route determined by the path. The first element of path is the input token,
     *         the last is the output token, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountIn The address of the vToken contract to repay.
     * @param amountOutMin The minimum amount of output tokens that must be received for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override nonReentrant ensure(deadline) ensurePath(path) returns (uint256[] memory amounts) {
        amounts = _swapExactTokensForTokens(amountIn, amountOutMin, path, to, TypesOfTokens.NON_SUPPORTING_FEE);
    }

    /**
     * @notice Swaps an exact amount of input tokens for as many output tokens as possible,
     *         along the route determined by the path. The first element of path is the input token,
     *         the last is the output token, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     *         This method to swap deflationary tokens which would require supporting fee.
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountIn The address of the vToken contract to repay.
     * @param amountOutMin The minimum amount of output tokens that must be received for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function swapExactTokensForTokensAtSupportingFee(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override nonReentrant ensure(deadline) ensurePath(path) returns (uint256 swapAmount) {
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(to);
        _swapExactTokensForTokens(amountIn, amountOutMin, path, to, TypesOfTokens.SUPPORTING_FEE);
        swapAmount = _checkForAmountOut(lastAsset, balanceBefore, amountOutMin, to);
    }

    /**
     * @notice Swaps an exact amount of CORE for as many output tokens as possible,
     *         along the route determined by the path. The first element of path must be WCORE,
     *         the last is the output token, and any intermediate elements represent
     *         intermediate pairs to trade through (if, for example, a direct pair does not exist).
     * @dev amountIn is passed through the msg.value of the transaction
     * @param amountOutMin The minimum amount of output tokens that must be received for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function swapExactCOREForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        payable
        virtual
        override
        nonReentrant
        ensure(deadline)
        ensurePath(path)
        returns (uint256[] memory amounts)
    {
        amounts = _swapExactCOREForTokens(amountOutMin, path, to, TypesOfTokens.NON_SUPPORTING_FEE);
    }

    /**
     * @notice Swaps an exact amount of ETH for as many output tokens as possible,
     *         along the route determined by the path. The first element of path must be WCORE,
     *         the last is the output token, and any intermediate elements represent
     *         intermediate pairs to trade through (if, for example, a direct pair does not exist).
     *         This method to swap deflationary tokens which would require supporting fee.
     * @dev amountIn is passed through the msg.value of the transaction
     * @param amountOutMin The minimum amount of output tokens that must be received for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function swapExactCOREForTokensAtSupportingFee(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable virtual override nonReentrant ensure(deadline) ensurePath(path) returns (uint256 swapAmount) {
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(to);
        _swapExactCOREForTokens(amountOutMin, path, to, TypesOfTokens.SUPPORTING_FEE);
        swapAmount = _checkForAmountOut(lastAsset, balanceBefore, amountOutMin, to);
    }

    /**
     * @notice Swaps an exact amount of input tokens for as many output ETH as possible,
     *         along the route determined by the path. The first element of path is the input token,
     *         the last is the output ETH, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountIn The address of the vToken contract to repay.
     * @param amountOutMin The minimum amount of output tokens that must be received for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function swapExactTokensForCORE(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) returns (uint256[] memory amounts) {
        amounts = _swapExactTokensForCORE(amountIn, amountOutMin, path, to, TypesOfTokens.NON_SUPPORTING_FEE);
    }

    /**
     * @notice Swaps an exact amount of input tokens for as many output ETH as possible,
     *         along the route determined by the path. The first element of path is the input token,
     *         the last is the output ETH, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     *         This method to swap deflationary tokens which would require supporting fee.
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountIn The address of the vToken contract to repay.
     * @param amountOutMin The minimum amount of output tokens that must be received for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function swapExactTokensForCOREAtSupportingFee(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) returns (uint256 swapAmount) {
        uint256 balanceBefore = to.balance;
        _swapExactTokensForCORE(amountIn, amountOutMin, path, to, TypesOfTokens.SUPPORTING_FEE);
        uint256 balanceAfter = to.balance;
        swapAmount = balanceAfter - balanceBefore;
        if (swapAmount < amountOutMin) {
            revert SwapAmountLessThanAmountOutMin(swapAmount, amountOutMin);
        }
    }

    /**
     * @notice Swaps an as many amount of input tokens for as exact amount of tokens as output,
     *         along the route determined by the path. The first element of path is the input token,
     *         the last is the output token, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     **/
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override nonReentrant ensure(deadline) ensurePath(path) returns (uint256[] memory amounts) {
        amounts = _swapTokensForExactTokens(amountOut, amountInMax, path, to);
    }

    /**
     * @notice Swaps an as ETH as input tokens for as exact amount of tokens as output,
     *         along the route determined by the path. The first element of path is the input WCORE,
     *         the last is the output as token, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     **/
    function swapCOREForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        payable
        virtual
        override
        nonReentrant
        ensure(deadline)
        ensurePath(path)
        returns (uint256[] memory amounts)
    {
        amounts = _swapCOREForExactTokens(amountOut, path, to);
    }

    /**
     * @notice Swaps an as many amount of input tokens for as exact amount of ETH as output,
     *         along the route determined by the path. The first element of path is the input token,
     *         the last is the output as ETH, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     **/
    function swapTokensForExactCORE(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override nonReentrant ensure(deadline) ensurePath(path) returns (uint256[] memory amounts) {
        amounts = _swapTokensForExactCORE(amountOut, amountInMax, path, to);
    }

    /**
     * @notice A public function to sweep accidental BEP-20 transfers to this contract. Tokens are sent to the address `to`, provided in input
     * @param token The address of the ERC-20 token to sweep
     * @param to Recipient of the output tokens.
     * @param sweepAmount The ampunt of the tokens to sweep
     * @custom:access Only Governance
     */
    function sweepToken(IERC20 token, address to, uint256 sweepAmount) external onlyOwner nonReentrant {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        uint256 balance = token.balanceOf(address(this));
        if (sweepAmount > balance) {
            revert InsufficientBalance(sweepAmount, balance);
        }
        token.safeTransfer(to, sweepAmount);

        emit SweepToken(address(token), to, sweepAmount);
    }

    /**
     * @notice Supply token to a Venus market
     * @param path The addresses of the underlying token
     * @param vTokenAddress The address of the vToken contract for supplying assets.
     * @param swapAmount The amount of tokens supply to Venus Market.
     */
    function _supply(address path, address vTokenAddress, uint256 swapAmount) internal {
        TransferHelper.safeApprove(path, vTokenAddress, 0);
        TransferHelper.safeApprove(path, vTokenAddress, swapAmount);
        uint256 response = IVToken(vTokenAddress).mintBehalf(msg.sender, swapAmount);
        if (response != 0) {
            revert SupplyError(msg.sender, vTokenAddress, response);
        }
    }

    /**
     * @notice Repay a borrow from Venus market
     * @param path The addresses of the underlying token
     * @param vTokenAddress The address of the vToken contract for supplying assets.
     * @param swapAmount The amount of tokens repay to Venus Market.
     */
    function _repay(address path, address vTokenAddress, uint256 swapAmount) internal {
        TransferHelper.safeApprove(path, vTokenAddress, 0);
        TransferHelper.safeApprove(path, vTokenAddress, swapAmount);
        uint256 response = IVToken(vTokenAddress).repayBorrowBehalf(msg.sender, swapAmount);
        if (response != 0) {
            revert RepayError(msg.sender, vTokenAddress, response);
        }
    }

    /**
     * @notice Check if the balance of to minus the balanceBefore is greater or equal to the amountOutMin.
     * @param asset The address of the underlying token
     * @param balanceBefore Balance before the swap.
     * @param amountOutMin Min amount out threshold.
     * @param to Recipient of the output tokens.
     */
    function _checkForAmountOut(
        address asset,
        uint256 balanceBefore,
        uint256 amountOutMin,
        address to
    ) internal view returns (uint256 swapAmount) {
        uint256 balanceAfter = IERC20(asset).balanceOf(to);
        swapAmount = balanceAfter - balanceBefore;
        if (swapAmount < amountOutMin) {
            revert SwapAmountLessThanAmountOutMin(swapAmount, amountOutMin);
        }
    }

    /**
     * @notice Returns the difference between the balance of this and the balanceBefore
     * @param asset The address of the underlying token
     * @param balanceBefore Balance before the swap.
     */
    function _getSwapAmount(address asset, uint256 balanceBefore) internal view returns (uint256 swapAmount) {
        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        swapAmount = balanceAfter - balanceBefore;
    }

    /**
     * @notice Check isVTokenListed and last address in the path should be vToken underlying.
     * @param vTokenAddress Address of the vToken.
     * @param underlying Address of the underlying asset.
     */
    function _ensureVTokenChecks(address vTokenAddress, address underlying) internal {
        _isVTokenListed(vTokenAddress);
        if (IVToken(vTokenAddress).underlying() != underlying) {
            revert VTokenUnderlyingInvalid(underlying);
        }
    }

    /**
     * @notice Check is vToken listed in the pool.
     * @param vToken Address of the vToken.
     */
    function _isVTokenListed(address vToken) internal view {
        bool isListed = InterfaceController(controllerAddress).markets(vToken);
        if (!isListed) {
            revert VTokenNotListed(vToken);
        }
    }

    /**
     * @notice Mint vCORE tokens to the market then transfer them to user
     * @param swapAmount Swapped CORE amount
     */
    function _mintVCOREandTransfer(uint256 swapAmount) internal {
        uint256 vCOREBalanceBefore = IVCORE(vCOREAddress).balanceOf(address(this));
        IVCORE(vCOREAddress).mint{ value: swapAmount }();
        uint256 vCOREBalanceAfter = IVCORE(vCOREAddress).balanceOf(address(this));
        IERC20(vCOREAddress).safeTransfer(msg.sender, (vCOREBalanceAfter - vCOREBalanceBefore));
    }
}

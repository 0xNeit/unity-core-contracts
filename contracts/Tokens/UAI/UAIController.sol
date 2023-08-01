pragma solidity ^0.5.16;

import "../../Oracle/PriceOracle.sol";
import "../../Utils/ErrorReporter.sol";
import "../../Utils/Exponential.sol";
import "../../Controller/ControllerStorage.sol";
import { Controller } from "../../Controller/Controller.sol";
import "../../Governance/IAccessControlManager.sol";
import "../VirtualTokens/VToken.sol";
import "./UAIControllerStorage.sol";
import "./UAIUnitroller.sol";
import "./UAI.sol";


/**
 * @title UAI Controller
 * @author Venus
 * @notice This is the implementation contract for the UAIUnitroller proxy
 */
contract UAIController is UAIControllerStorageG2, UAIControllerErrorReporter, Exponential {
    /// @notice Initial index used in interest computations
    uint public constant INITIAL_UAI_MINT_INDEX = 1e18;

    /// @notice Emitted when Controller is changed
    event NewController(Controller oldController, Controller newController);

    /// @notice Event emitted when UAI is minted
    event MintUAI(address minter, uint mintUAIAmount);

    /// @notice Event emitted when UAI is repaid
    event RepayUAI(address payer, address borrower, uint repayUAIAmount);

    /// @notice Event emitted when a borrow is liquidated
    event LiquidateUAI(
        address liquidator,
        address borrower,
        uint repayAmount,
        address vTokenCollateral,
        uint seizeTokens
    );

    /// @notice Emitted when treasury guardian is changed
    event NewTreasuryGuardian(address oldTreasuryGuardian, address newTreasuryGuardian);

    /// @notice Emitted when treasury address is changed
    event NewTreasuryAddress(address oldTreasuryAddress, address newTreasuryAddress);

    /// @notice Emitted when treasury percent is changed
    event NewTreasuryPercent(uint oldTreasuryPercent, uint newTreasuryPercent);

    /// @notice Event emitted when UAIs are minted and fee are transferred
    event MintFee(address minter, uint feeAmount);

    /// @notice Emiitted when UAI base rate is changed
    event NewUAIBaseRate(uint256 oldBaseRateMantissa, uint256 newBaseRateMantissa);

    /// @notice Emiitted when UAI float rate is changed
    event NewUAIFloatRate(uint oldFloatRateMantissa, uint newFlatRateMantissa);

    /// @notice Emiitted when UAI receiver address is changed
    event NewUAIReceiver(address oldReceiver, address newReceiver);

    /// @notice Emiitted when UAI mint cap is changed
    event NewUAIMintCap(uint oldMintCap, uint newMintCap);

    /// @notice Emitted when access control address is changed by admin
    event NewAccessControl(address oldAccessControlAddress, address newAccessControlAddress);

    /*** Main Actions ***/
    struct MintLocalVars {
        uint oErr;
        MathError mathErr;
        uint mintAmount;
        uint accountMintUAINew;
        uint accountMintableUAI;
    }

    function initialize() external onlyAdmin {
        require(uaiMintIndex == 0, "already initialized");

        uaiMintIndex = INITIAL_UAI_MINT_INDEX;
        accrualBlockNumber = getBlockNumber();
        mintCap = uint256(-1);

        // The counter starts true to prevent changing it from zero to non-zero (i.e. smaller cost/refund)
        _notEntered = true;
    }

    function _become(UAIUnitroller unitroller) external {
        require(msg.sender == unitroller.admin(), "only unitroller admin can change brains");
        require(unitroller._acceptImplementation() == 0, "change not authorized");
    }

    /**
     * @notice The mintUAI function mints and transfers UAI from the protocol to the user, and adds a borrow balance.
     * The amount minted must be less than the user's Account Liquidity and the mint uai limit.
     * @param mintUAIAmount The amount of the UAI to be minted.
     * @return 0 on success, otherwise an error code
     */
    // solhint-disable-next-line code-complexity
    function mintUAI(uint mintUAIAmount) external nonReentrant returns (uint) {
        if (address(controller) != address(0)) {
            require(mintUAIAmount > 0, "mintUAIAmount cannot be zero");
            require(!Controller(address(controller)).protocolPaused(), "protocol is paused");

            accrueUAIInterest();

            MintLocalVars memory vars;

            address minter = msg.sender;
            uint uaiTotalSupply = EIP20Interface(getUAIAddress()).totalSupply();
            uint uaiNewTotalSupply;

            (vars.mathErr, uaiNewTotalSupply) = addUInt(uaiTotalSupply, mintUAIAmount);
            require(uaiNewTotalSupply <= mintCap, "mint cap reached");

            if (vars.mathErr != MathError.NO_ERROR) {
                return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
            }

            (vars.oErr, vars.accountMintableUAI) = getMintableUAI(minter);
            if (vars.oErr != uint(Error.NO_ERROR)) {
                return uint(Error.REJECTION);
            }

            // check that user have sufficient mintableUAI balance
            if (mintUAIAmount > vars.accountMintableUAI) {
                return fail(Error.REJECTION, FailureInfo.UAI_MINT_REJECTION);
            }

            // Calculate the minted balance based on interest index
            uint totalMintedUAI = Controller(address(controller)).mintedUAIs(minter);

            if (totalMintedUAI > 0) {
                uint256 repayAmount = getUAIRepayAmount(minter);
                uint remainedAmount;

                (vars.mathErr, remainedAmount) = subUInt(repayAmount, totalMintedUAI);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                (vars.mathErr, pastUAIInterest[minter]) = addUInt(pastUAIInterest[minter], remainedAmount);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                totalMintedUAI = repayAmount;
            }

            (vars.mathErr, vars.accountMintUAINew) = addUInt(totalMintedUAI, mintUAIAmount);
            require(vars.mathErr == MathError.NO_ERROR, "UAI_MINT_AMOUNT_CALCULATION_FAILED");
            uint error = controller.setMintedUAIOf(minter, vars.accountMintUAINew);
            if (error != 0) {
                return error;
            }

            uint feeAmount;
            uint remainedAmount;
            vars.mintAmount = mintUAIAmount;
            if (treasuryPercent != 0) {
                (vars.mathErr, feeAmount) = mulUInt(vars.mintAmount, treasuryPercent);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                (vars.mathErr, feeAmount) = divUInt(feeAmount, 1e18);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                (vars.mathErr, remainedAmount) = subUInt(vars.mintAmount, feeAmount);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                UAI(getUAIAddress()).mint(treasuryAddress, feeAmount);

                emit MintFee(minter, feeAmount);
            } else {
                remainedAmount = vars.mintAmount;
            }

            UAI(getUAIAddress()).mint(minter, remainedAmount);
            uaiMinterInterestIndex[minter] = uaiMintIndex;

            emit MintUAI(minter, remainedAmount);

            return uint(Error.NO_ERROR);
        }
    }

    /**
     * @notice The repay function transfers UAI into the protocol and burn, reducing the user's borrow balance.
     * Before repaying an asset, users must first approve the UAI to access their UAI balance.
     * @param repayUAIAmount The amount of the UAI to be repaid.
     * @return 0 on success, otherwise an error code
     */
    function repayUAI(uint repayUAIAmount) external nonReentrant returns (uint, uint) {
        if (address(controller) != address(0)) {
            accrueUAIInterest();

            require(repayUAIAmount > 0, "repayUAIAmount cannt be zero");

            require(!Controller(address(controller)).protocolPaused(), "protocol is paused");

            return repayUAIFresh(msg.sender, msg.sender, repayUAIAmount);
        }
    }

    /**
     * @notice Repay UAI Internal
     * @notice Borrowed UAIs are repaid by another user (possibly the borrower).
     * @param payer the account paying off the UAI
     * @param borrower the account with the debt being payed off
     * @param repayAmount the amount of UAI being returned
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function repayUAIFresh(address payer, address borrower, uint repayAmount) internal returns (uint, uint) {
        MathError mErr;

        (uint burn, uint partOfCurrentInterest, uint partOfPastInterest) = getUAICalculateRepayAmount(
            borrower,
            repayAmount
        );

        UAI(getUAIAddress()).burn(payer, burn);
        bool success = UAI(getUAIAddress()).transferFrom(payer, receiver, partOfCurrentInterest);
        require(success == true, "failed to transfer UAI fee");

        uint uaiBalanceBorrower = Controller(address(controller)).mintedUAIs(borrower);
        uint accountUAINew;

        (mErr, accountUAINew) = subUInt(uaiBalanceBorrower, burn);
        require(mErr == MathError.NO_ERROR, "UAI_BURN_AMOUNT_CALCULATION_FAILED");

        (mErr, accountUAINew) = subUInt(accountUAINew, partOfPastInterest);
        require(mErr == MathError.NO_ERROR, "UAI_BURN_AMOUNT_CALCULATION_FAILED");

        (mErr, pastUAIInterest[borrower]) = subUInt(pastUAIInterest[borrower], partOfPastInterest);
        require(mErr == MathError.NO_ERROR, "UAI_BURN_AMOUNT_CALCULATION_FAILED");

        uint error = controller.setMintedUAIOf(borrower, accountUAINew);
        if (error != 0) {
            return (error, 0);
        }
        emit RepayUAI(payer, borrower, burn);

        return (uint(Error.NO_ERROR), burn);
    }

    /**
     * @notice The sender liquidates the uai minters collateral. The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of uai to be liquidated
     * @param vTokenCollateral The market in which to seize collateral from the borrower
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function liquidateUAI(
        address borrower,
        uint repayAmount,
        VTokenInterface vTokenCollateral
    ) external nonReentrant returns (uint, uint) {
        require(!Controller(address(controller)).protocolPaused(), "protocol is paused");

        uint error = vTokenCollateral.accrueInterest();
        if (error != uint(Error.NO_ERROR)) {
            // accrueInterest emits logs on errors, but we still want to log the fact that an attempted liquidation failed
            return (fail(Error(error), FailureInfo.UAI_LIQUIDATE_ACCRUE_COLLATERAL_INTEREST_FAILED), 0);
        }

        // liquidateUAIFresh emits borrow-specific logs on errors, so we don't need to
        return liquidateUAIFresh(msg.sender, borrower, repayAmount, vTokenCollateral);
    }

    /**
     * @notice The liquidator liquidates the borrowers collateral by repay borrowers UAI.
     *  The collateral seized is transferred to the liquidator.
     * @param liquidator The address repaying the UAI and seizing collateral
     * @param borrower The borrower of this UAI to be liquidated
     * @param vTokenCollateral The market in which to seize collateral from the borrower
     * @param repayAmount The amount of the UAI to repay
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment UAI.
     */
    function liquidateUAIFresh(
        address liquidator,
        address borrower,
        uint repayAmount,
        VTokenInterface vTokenCollateral
    ) internal returns (uint, uint) {
        if (address(controller) != address(0)) {
            accrueUAIInterest();

            /* Fail if liquidate not allowed */
            uint allowed = controller.liquidateBorrowAllowed(
                address(this),
                address(vTokenCollateral),
                liquidator,
                borrower,
                repayAmount
            );
            if (allowed != 0) {
                return (failOpaque(Error.REJECTION, FailureInfo.UAI_LIQUIDATE_CONTROLLER_REJECTION, allowed), 0);
            }

            /* Verify vTokenCollateral market's block number equals current block number */
            //if (vTokenCollateral.accrualBlockNumber() != accrualBlockNumber) {
            if (vTokenCollateral.accrualBlockNumber() != getBlockNumber()) {
                return (fail(Error.REJECTION, FailureInfo.UAI_LIQUIDATE_COLLATERAL_FRESHNESS_CHECK), 0);
            }

            /* Fail if borrower = liquidator */
            if (borrower == liquidator) {
                return (fail(Error.REJECTION, FailureInfo.UAI_LIQUIDATE_LIQUIDATOR_IS_BORROWER), 0);
            }

            /* Fail if repayAmount = 0 */
            if (repayAmount == 0) {
                return (fail(Error.REJECTION, FailureInfo.UAI_LIQUIDATE_CLOSE_AMOUNT_IS_ZERO), 0);
            }

            /* Fail if repayAmount = -1 */
            if (repayAmount == uint(-1)) {
                return (fail(Error.REJECTION, FailureInfo.UAI_LIQUIDATE_CLOSE_AMOUNT_IS_UINT_MAX), 0);
            }

            /* Fail if repayUAI fails */
            (uint repayBorrowError, uint actualRepayAmount) = repayUAIFresh(liquidator, borrower, repayAmount);
            if (repayBorrowError != uint(Error.NO_ERROR)) {
                return (fail(Error(repayBorrowError), FailureInfo.UAI_LIQUIDATE_REPAY_BORROW_FRESH_FAILED), 0);
            }

            /////////////////////////
            // EFFECTS & INTERACTIONS
            // (No safe failures beyond this point)

            /* We calculate the number of collateral tokens that will be seized */
            (uint amountSeizeError, uint seizeTokens) = controller.liquidateUAICalculateSeizeTokens(
                address(vTokenCollateral),
                actualRepayAmount
            );
            require(
                amountSeizeError == uint(Error.NO_ERROR),
                "UAI_LIQUIDATE_CONTROLLER_CALCULATE_AMOUNT_SEIZE_FAILED"
            );

            /* Revert if borrower collateral token balance < seizeTokens */
            require(vTokenCollateral.balanceOf(borrower) >= seizeTokens, "UAI_LIQUIDATE_SEIZE_TOO_MUCH");

            uint seizeError;
            seizeError = vTokenCollateral.seize(liquidator, borrower, seizeTokens);

            /* Revert if seize tokens fails (since we cannot be sure of side effects) */
            require(seizeError == uint(Error.NO_ERROR), "token seizure failed");

            /* We emit a LiquidateBorrow event */
            emit LiquidateUAI(liquidator, borrower, actualRepayAmount, address(vTokenCollateral), seizeTokens);

            /* We call the defense hook */
            controller.liquidateBorrowVerify(
                address(this),
                address(vTokenCollateral),
                liquidator,
                borrower,
                actualRepayAmount,
                seizeTokens
            );

            return (uint(Error.NO_ERROR), actualRepayAmount);
        }
    }

    /*** Admin Functions ***/

    /**
     * @notice Sets a new controller
     * @dev Admin function to set a new controller
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setController(Controller controller_) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_CONTROLLER_OWNER_CHECK);
        }

        Controller oldController = controller;
        controller = controller_;
        emit NewController(oldController, controller_);

        return uint(Error.NO_ERROR);
    }

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account total supply balance.
     *  Note that `vTokenBalance` is the number of vTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountAmountLocalVars {
        uint oErr;
        MathError mErr;
        uint sumSupply;
        uint marketSupply;
        uint sumBorrowPlusEffects;
        uint vTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    // solhint-disable-next-line code-complexity
    function getMintableUAI(address minter) public view returns (uint, uint) {
        PriceOracle oracle = Controller(address(controller)).oracle();
        VToken[] memory enteredMarkets = Controller(address(controller)).getAssetsIn(minter);

        AccountAmountLocalVars memory vars; // Holds all our calculation results

        uint accountMintableUAI;
        uint i;

        /**
         * We use this formula to calculate mintable UAI amount.
         * totalSupplyAmount * UAIMintRate - (totalBorrowAmount + mintedUAIOf)
         */
        for (i = 0; i < enteredMarkets.length; i++) {
            (vars.oErr, vars.vTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = enteredMarkets[i]
                .getAccountSnapshot(minter);
            if (vars.oErr != 0) {
                // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (uint(Error.SNAPSHOT_ERROR), 0);
            }
            vars.exchangeRate = Exp({ mantissa: vars.exchangeRateMantissa });

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(enteredMarkets[i]);
            if (vars.oraclePriceMantissa == 0) {
                return (uint(Error.PRICE_ERROR), 0);
            }
            vars.oraclePrice = Exp({ mantissa: vars.oraclePriceMantissa });

            (vars.mErr, vars.tokensToDenom) = mulExp(vars.exchangeRate, vars.oraclePrice);
            if (vars.mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }

            // marketSupply = tokensToDenom * vTokenBalance
            (vars.mErr, vars.marketSupply) = mulScalarTruncate(vars.tokensToDenom, vars.vTokenBalance);
            if (vars.mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }

            (, uint collateralFactorMantissa, ) = Controller(address(controller)).markets(address(enteredMarkets[i]));
            (vars.mErr, vars.marketSupply) = mulUInt(vars.marketSupply, collateralFactorMantissa);
            if (vars.mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }

            (vars.mErr, vars.marketSupply) = divUInt(vars.marketSupply, 1e18);
            if (vars.mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }

            (vars.mErr, vars.sumSupply) = addUInt(vars.sumSupply, vars.marketSupply);
            if (vars.mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            (vars.mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(
                vars.oraclePrice,
                vars.borrowBalance,
                vars.sumBorrowPlusEffects
            );
            if (vars.mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }
        }

        uint totalMintedUAI = Controller(address(controller)).mintedUAIs(minter);
        uint256 repayAmount = 0;

        if (totalMintedUAI > 0) {
            repayAmount = getUAIRepayAmount(minter);
        }

        (vars.mErr, vars.sumBorrowPlusEffects) = addUInt(vars.sumBorrowPlusEffects, repayAmount);
        if (vars.mErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (vars.mErr, accountMintableUAI) = mulUInt(vars.sumSupply, Controller(address(controller)).uaiMintRate());
        require(vars.mErr == MathError.NO_ERROR, "UAI_MINT_AMOUNT_CALCULATION_FAILED");

        (vars.mErr, accountMintableUAI) = divUInt(accountMintableUAI, 10000);
        require(vars.mErr == MathError.NO_ERROR, "UAI_MINT_AMOUNT_CALCULATION_FAILED");

        (vars.mErr, accountMintableUAI) = subUInt(accountMintableUAI, vars.sumBorrowPlusEffects);
        if (vars.mErr != MathError.NO_ERROR) {
            return (uint(Error.REJECTION), 0);
        }

        return (uint(Error.NO_ERROR), accountMintableUAI);
    }

    function _setTreasuryData(
        address newTreasuryGuardian,
        address newTreasuryAddress,
        uint newTreasuryPercent
    ) external returns (uint) {
        // Check caller is admin
        if (!(msg.sender == admin || msg.sender == treasuryGuardian)) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_TREASURY_OWNER_CHECK);
        }

        require(newTreasuryPercent < 1e18, "treasury percent cap overflow");

        address oldTreasuryGuardian = treasuryGuardian;
        address oldTreasuryAddress = treasuryAddress;
        uint oldTreasuryPercent = treasuryPercent;

        treasuryGuardian = newTreasuryGuardian;
        treasuryAddress = newTreasuryAddress;
        treasuryPercent = newTreasuryPercent;

        emit NewTreasuryGuardian(oldTreasuryGuardian, newTreasuryGuardian);
        emit NewTreasuryAddress(oldTreasuryAddress, newTreasuryAddress);
        emit NewTreasuryPercent(oldTreasuryPercent, newTreasuryPercent);

        return uint(Error.NO_ERROR);
    }

    function getUAIRepayRate() public view returns (uint) {
        PriceOracle oracle = Controller(address(controller)).oracle();
        MathError mErr;

        if (baseRateMantissa > 0) {
            if (floatRateMantissa > 0) {
                uint oraclePrice = oracle.getUnderlyingPrice(VToken(getUAIAddress()));
                if (1e18 > oraclePrice) {
                    uint delta;
                    uint rate;

                    (mErr, delta) = subUInt(1e18, oraclePrice);
                    require(mErr == MathError.NO_ERROR, "UAI_REPAY_RATE_CALCULATION_FAILED");

                    (mErr, delta) = mulUInt(delta, floatRateMantissa);
                    require(mErr == MathError.NO_ERROR, "UAI_REPAY_RATE_CALCULATION_FAILED");

                    (mErr, delta) = divUInt(delta, 1e18);
                    require(mErr == MathError.NO_ERROR, "UAI_REPAY_RATE_CALCULATION_FAILED");

                    (mErr, rate) = addUInt(delta, baseRateMantissa);
                    require(mErr == MathError.NO_ERROR, "UAI_REPAY_RATE_CALCULATION_FAILED");

                    return rate;
                } else {
                    return baseRateMantissa;
                }
            } else {
                return baseRateMantissa;
            }
        } else {
            return 0;
        }
    }

    function getUAIRepayRatePerBlock() public view returns (uint) {
        uint yearlyRate = getUAIRepayRate();

        MathError mErr;
        uint rate;

        (mErr, rate) = divUInt(yearlyRate, getBlocksPerYear());
        require(mErr == MathError.NO_ERROR, "UAI_REPAY_RATE_CALCULATION_FAILED");

        return rate;
    }

    function getUAIMinterInterestIndex(address minter) public view returns (uint) {
        uint storedIndex = uaiMinterInterestIndex[minter];
        // If the user minted UAI before the stability fee was introduced, accrue
        // starting from stability fee launch
        if (storedIndex == 0) {
            return INITIAL_UAI_MINT_INDEX;
        }
        return storedIndex;
    }

    /**
     * @notice Get the current total UAI a user needs to repay
     * @param account The address of the UAI borrower
     * @return (uint) The total amount of UAI the user needs to repay
     */
    function getUAIRepayAmount(address account) public view returns (uint) {
        MathError mErr;
        uint delta;

        uint amount = Controller(address(controller)).mintedUAIs(account);
        uint interest = pastUAIInterest[account];
        uint totalMintedUAI;
        uint newInterest;

        (mErr, totalMintedUAI) = subUInt(amount, interest);
        require(mErr == MathError.NO_ERROR, "UAI_TOTAL_REPAY_AMOUNT_CALCULATION_FAILED");

        (mErr, delta) = subUInt(uaiMintIndex, getUAIMinterInterestIndex(account));
        require(mErr == MathError.NO_ERROR, "UAI_TOTAL_REPAY_AMOUNT_CALCULATION_FAILED");

        (mErr, newInterest) = mulUInt(delta, totalMintedUAI);
        require(mErr == MathError.NO_ERROR, "UAI_TOTAL_REPAY_AMOUNT_CALCULATION_FAILED");

        (mErr, newInterest) = divUInt(newInterest, 1e18);
        require(mErr == MathError.NO_ERROR, "UAI_TOTAL_REPAY_AMOUNT_CALCULATION_FAILED");

        (mErr, amount) = addUInt(amount, newInterest);
        require(mErr == MathError.NO_ERROR, "UAI_TOTAL_REPAY_AMOUNT_CALCULATION_FAILED");

        return amount;
    }

    /**
     * @notice Calculate how much UAI the user needs to repay
     * @param borrower The address of the UAI borrower
     * @param repayAmount The amount of UAI being returned
     * @return (uint, uint, uint) Amount of UAI to be burned, amount of UAI the user needs to pay in current interest and amount of UAI the user needs to pay in past interest
     */
    function getUAICalculateRepayAmount(address borrower, uint256 repayAmount) public view returns (uint, uint, uint) {
        MathError mErr;
        uint256 totalRepayAmount = getUAIRepayAmount(borrower);
        uint currentInterest;

        (mErr, currentInterest) = subUInt(totalRepayAmount, Controller(address(controller)).mintedUAIs(borrower));
        require(mErr == MathError.NO_ERROR, "UAI_BURN_AMOUNT_CALCULATION_FAILED");

        (mErr, currentInterest) = addUInt(pastUAIInterest[borrower], currentInterest);
        require(mErr == MathError.NO_ERROR, "UAI_BURN_AMOUNT_CALCULATION_FAILED");

        uint burn;
        uint partOfCurrentInterest = currentInterest;
        uint partOfPastInterest = pastUAIInterest[borrower];

        if (repayAmount >= totalRepayAmount) {
            (mErr, burn) = subUInt(totalRepayAmount, currentInterest);
            require(mErr == MathError.NO_ERROR, "UAI_BURN_AMOUNT_CALCULATION_FAILED");
        } else {
            uint delta;

            (mErr, delta) = mulUInt(repayAmount, 1e18);
            require(mErr == MathError.NO_ERROR, "UAI_PART_CALCULATION_FAILED");

            (mErr, delta) = divUInt(delta, totalRepayAmount);
            require(mErr == MathError.NO_ERROR, "UAI_PART_CALCULATION_FAILED");

            uint totalMintedAmount;
            (mErr, totalMintedAmount) = subUInt(totalRepayAmount, currentInterest);
            require(mErr == MathError.NO_ERROR, "UAI_MINTED_AMOUNT_CALCULATION_FAILED");

            (mErr, burn) = mulUInt(totalMintedAmount, delta);
            require(mErr == MathError.NO_ERROR, "UAI_BURN_AMOUNT_CALCULATION_FAILED");

            (mErr, burn) = divUInt(burn, 1e18);
            require(mErr == MathError.NO_ERROR, "UAI_BURN_AMOUNT_CALCULATION_FAILED");

            (mErr, partOfCurrentInterest) = mulUInt(currentInterest, delta);
            require(mErr == MathError.NO_ERROR, "UAI_CURRENT_INTEREST_AMOUNT_CALCULATION_FAILED");

            (mErr, partOfCurrentInterest) = divUInt(partOfCurrentInterest, 1e18);
            require(mErr == MathError.NO_ERROR, "UAI_CURRENT_INTEREST_AMOUNT_CALCULATION_FAILED");

            (mErr, partOfPastInterest) = mulUInt(pastUAIInterest[borrower], delta);
            require(mErr == MathError.NO_ERROR, "UAI_PAST_INTEREST_CALCULATION_FAILED");

            (mErr, partOfPastInterest) = divUInt(partOfPastInterest, 1e18);
            require(mErr == MathError.NO_ERROR, "UAI_PAST_INTEREST_CALCULATION_FAILED");
        }

        return (burn, partOfCurrentInterest, partOfPastInterest);
    }

    function accrueUAIInterest() public {
        MathError mErr;
        uint delta;

        (mErr, delta) = mulUInt(getUAIRepayRatePerBlock(), getBlockNumber() - accrualBlockNumber);
        require(mErr == MathError.NO_ERROR, "UAI_INTEREST_ACCURE_FAILED");

        (mErr, delta) = addUInt(delta, uaiMintIndex);
        require(mErr == MathError.NO_ERROR, "UAI_INTEREST_ACCURE_FAILED");

        uaiMintIndex = delta;
        accrualBlockNumber = getBlockNumber();
    }

    /**
     * @notice Sets the address of the access control of this contract
     * @dev Admin function to set the access control address
     * @param newAccessControlAddress New address for the access control
     */
    function setAccessControl(address newAccessControlAddress) external onlyAdmin {
        _ensureNonzeroAddress(newAccessControlAddress);

        address oldAccessControlAddress = accessControl;
        accessControl = newAccessControlAddress;
        emit NewAccessControl(oldAccessControlAddress, accessControl);
    }

    /**
     * @notice Set UAI borrow base rate
     * @param newBaseRateMantissa the base rate multiplied by 10**18
     */
    function setBaseRate(uint newBaseRateMantissa) external {
        _ensureAllowed("setBaseRate(uint256)");

        uint old = baseRateMantissa;
        baseRateMantissa = newBaseRateMantissa;
        emit NewUAIBaseRate(old, baseRateMantissa);
    }

    /**
     * @notice Set UAI borrow float rate
     * @param newFloatRateMantissa the UAI float rate multiplied by 10**18
     */
    function setFloatRate(uint newFloatRateMantissa) external {
        _ensureAllowed("setFloatRate(uint256)");

        uint old = floatRateMantissa;
        floatRateMantissa = newFloatRateMantissa;
        emit NewUAIFloatRate(old, floatRateMantissa);
    }

    /**
     * @notice Set UAI stability fee receiver address
     * @param newReceiver the address of the UAI fee receiver
     */
    function setReceiver(address newReceiver) external onlyAdmin {
        require(newReceiver != address(0), "invalid receiver address");

        address old = receiver;
        receiver = newReceiver;
        emit NewUAIReceiver(old, newReceiver);
    }

    /**
     * @notice Set UAI mint cap
     * @param _mintCap the amount of UAI that can be minted
     */
    function setMintCap(uint _mintCap) external {
        _ensureAllowed("setMintCap(uint256)");

        uint old = mintCap;
        mintCap = _mintCap;
        emit NewUAIMintCap(old, _mintCap);
    }

    function getBlockNumber() public view returns (uint) {
        return block.number;
    }

    function getBlocksPerYear() public pure returns (uint) {
        return 10512000; //(24 * 60 * 60 * 365) / 3;
    }

    /**
     * @notice Return the address of the UAI token
     * @return The address of UAI
     */
    function getUAIAddress() public pure returns (address) {
        return 0x4BD17003473389A42DAF6a0a729f6Fdb328BbBd7;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin can");
        _;
    }

    /*** Reentrancy Guard ***/

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        require(_notEntered, "re-entered");
        _notEntered = false;
        _;
        _notEntered = true; // get a gas-refund post-Istanbul
    }

    function _ensureAllowed(string memory functionSig) private view {
        require(IAccessControlManager(accessControl).isAllowedToCall(msg.sender, functionSig), "access denied");
    }

    /// @notice Reverts if the passed address is zero
    function _ensureNonzeroAddress(address someone) private pure {
        require(someone != address(0), "can't be zero address");
    }
}

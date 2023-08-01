pragma solidity ^0.5.16;

import "../Oracle/PriceOracle.sol";
import "../Tokens/VTokens/VToken.sol";
import "../Utils/ErrorReporter.sol";
import "../Utils/Exponential.sol";
import "../Tokens/UCORE/UCORE.sol";
import "../Tokens/UAI/UAI.sol";
import "./ControllerInterface.sol";
import "./ControllerStorage.sol";
import "./Unitroller.sol";

/**
 * @title UnityCore's Controller Contract
 * @author UnityCore
 */
contract ControllerG1 is ControllerV1Storage, ControllerInterfaceG1, ControllerErrorReporter, Exponential {
    /// @notice Emitted when an admin supports a market
    event MarketListed(VToken vToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(VToken vToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(VToken vToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(uint oldCloseFactorMantissa, uint newCloseFactorMantissa);

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(VToken vToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);

    /// @notice Emitted when maxAssets is changed by admin
    event NewMaxAssets(uint oldMaxAssets, uint newMaxAssets);

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused globally
    event ActionPaused(string action, bool pauseState);

    /// @notice Emitted when an action is paused on a market
    event ActionPaused(VToken vToken, string action, bool pauseState);

    /// @notice Emitted when market ucore status is changed
    event MarketUcore(VToken vToken, bool isUcore);

    /// @notice Emitted when Ucore rate is changed
    event NewUcoreRate(uint oldUcoreRate, uint newUcoreRate);

    /// @notice Emitted when a new Ucore speed is calculated for a market
    event UcoreSpeedUpdated(VToken indexed vToken, uint newSpeed);

    /// @notice Emitted when UCORE is distributed to a supplier
    event DistributedSupplierUcore(
        VToken indexed vToken,
        address indexed supplier,
        uint ucoreDelta,
        uint ucoreSupplyIndex
    );

    /// @notice Emitted when UCORE is distributed to a borrower
    event DistributedBorrowerUcore(
        VToken indexed vToken,
        address indexed borrower,
        uint ucoreDelta,
        uint ucoreBorrowIndex
    );

    /// @notice Emitted when UCORE is distributed to a UAI minter
    event DistributedUAIMinterUcore(address indexed uaiMinter, uint ucoreDelta, uint ucoreUAIMintIndex);

    /// @notice Emitted when UAIController is changed
    event NewUAIController(UAIControllerInterface oldUAIController, UAIControllerInterface newUAIController);

    /// @notice Emitted when UAI mint rate is changed by admin
    event NewUAIMintRate(uint oldUAIMintRate, uint newUAIMintRate);

    /// @notice Emitted when protocol state is changed by admin
    event ActionProtocolPaused(bool state);

    /// @notice The threshold above which the flywheel transfers UCORE, in wei
    uint public constant ucoreClaimThreshold = 0.001e18;

    /// @notice The initial Ucore index for a market
    uint224 public constant ucoreInitialIndex = 1e36;

    // closeFactorMantissa must be strictly greater than this value
    uint internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa must not exceed this value
    uint internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // No collateralFactorMantissa may exceed this value
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    // liquidationIncentiveMantissa must be no less than this value
    uint internal constant liquidationIncentiveMinMantissa = 1.0e18; // 1.0

    // liquidationIncentiveMantissa must be no greater than this value
    uint internal constant liquidationIncentiveMaxMantissa = 1.5e18; // 1.5

    constructor() public {
        admin = msg.sender;
    }

    modifier onlyProtocolAllowed() {
        require(!protocolPaused, "protocol is paused");
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin can");
        _;
    }

    modifier onlyListedMarket(VToken vToken) {
        require(markets[address(vToken)].isListed, "ucore market is not listed");
        _;
    }

    modifier validPauseState(bool state) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can");
        require(msg.sender == admin || state == true, "only admin can unpause");
        _;
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account) external view returns (VToken[] memory) {
        return accountAssets[account];
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param vToken The vToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(address account, VToken vToken) external view returns (bool) {
        return markets[address(vToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param vTokens The list of addresses of the vToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(address[] calldata vTokens) external returns (uint[] memory) {
        uint len = vTokens.length;

        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            results[i] = uint(addToMarketInternal(VToken(vTokens[i]), msg.sender));
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param vToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(VToken vToken, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(vToken)];

        if (!marketToJoin.isListed) {
            // market is not listed, cannot join
            return Error.MARKET_NOT_LISTED;
        }

        if (marketToJoin.accountMembership[borrower]) {
            // already joined
            return Error.NO_ERROR;
        }

        if (accountAssets[borrower].length >= maxAssets) {
            // no space, cannot join
            return Error.TOO_MANY_ASSETS;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(vToken);

        emit MarketEntered(vToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param vTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(address vTokenAddress) external returns (uint) {
        VToken vToken = VToken(vTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the vToken */
        (uint oErr, uint tokensHeld, uint amountOwed, ) = vToken.getAccountSnapshot(msg.sender);
        require(oErr == 0, "getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint allowed = redeemAllowedInternal(vTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[address(vToken)];

        /* Return true if the sender is not already ‘in’ the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        /* Set vToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete vToken from the account’s list of assets */
        // In order to delete vToken, copy last item in list to location of item to be removed, reduce length by 1
        VToken[] storage userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint i;
        for (; i < len; i++) {
            if (userAssetList[i] == vToken) {
                userAssetList[i] = userAssetList[len - 1];
                userAssetList.length--;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(i < len);

        emit MarketExited(vToken, msg.sender);

        return uint(Error.NO_ERROR);
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param vToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(address vToken, address minter, uint mintAmount) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintGuardianPaused[vToken], "mint is paused");

        // Shh - currently unused
        mintAmount;

        if (!markets[vToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        updateUcoreSupplyIndex(vToken);
        distributeSupplierUcore(vToken, minter, false);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param vToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(address vToken, address minter, uint actualMintAmount, uint mintTokens) external {
        // Shh - currently unused
        vToken;
        minter;
        actualMintAmount;
        mintTokens;
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param vToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of vTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(
        address vToken,
        address redeemer,
        uint redeemTokens
    ) external onlyProtocolAllowed returns (uint) {
        uint allowed = redeemAllowedInternal(vToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateUcoreSupplyIndex(vToken);
        distributeSupplierUcore(vToken, redeemer, false);

        return uint(Error.NO_ERROR);
    }

    function redeemAllowedInternal(address vToken, address redeemer, uint redeemTokens) internal view returns (uint) {
        if (!markets[vToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[vToken].accountMembership[redeemer]) {
            return uint(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(
            redeemer,
            VToken(vToken),
            redeemTokens,
            0
        );
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall != 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param vToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(address vToken, address redeemer, uint redeemAmount, uint redeemTokens) external {
        // Shh - currently unused
        vToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        require(redeemTokens != 0 || redeemAmount == 0, "redeemTokens zero");
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param vToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(
        address vToken,
        address borrower,
        uint borrowAmount
    ) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!borrowGuardianPaused[vToken], "borrow is paused");

        if (!markets[vToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!markets[vToken].accountMembership[borrower]) {
            // only vTokens may call borrowAllowed if borrower not in market
            require(msg.sender == vToken, "sender must be vToken");

            // attempt to add borrower to the market
            Error err = addToMarketInternal(VToken(vToken), borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }
        }

        if (oracle.getUnderlyingPrice(VToken(vToken)) == 0) {
            return uint(Error.PRICE_ERROR);
        }

        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(
            borrower,
            VToken(vToken),
            0,
            borrowAmount
        );
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall != 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({ mantissa: VToken(vToken).borrowIndex() });
        updateUcoreBorrowIndex(vToken, borrowIndex);
        distributeBorrowerUcore(vToken, borrower, borrowIndex, false);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit logs.
     * @param vToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    function borrowVerify(address vToken, address borrower, uint borrowAmount) external {
        // Shh - currently unused
        vToken;
        borrower;
        borrowAmount;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param vToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which would repay the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(
        address vToken,
        address payer,
        address borrower,
        uint repayAmount
    ) external onlyProtocolAllowed returns (uint) {
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!markets[vToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({ mantissa: VToken(vToken).borrowIndex() });
        updateUcoreBorrowIndex(vToken, borrowIndex);
        distributeBorrowerUcore(vToken, borrower, borrowIndex, false);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates repayBorrow and reverts on rejection. May emit logs.
     * @param vToken Asset being repaid
     * @param payer The address repaying the borrow
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function repayBorrowVerify(
        address vToken,
        address payer,
        address borrower,
        uint actualRepayAmount,
        uint borrowerIndex
    ) external {
        // Shh - currently unused
        vToken;
        payer;
        borrower;
        actualRepayAmount;
        borrowerIndex;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param vTokenBorrowed Asset which was borrowed by the borrower
     * @param vTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(
        address vTokenBorrowed,
        address vTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount
    ) external onlyProtocolAllowed returns (uint) {
        // Shh - currently unused
        liquidator;

        if (!markets[vTokenBorrowed].isListed || !markets[vTokenCollateral].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* The borrower must have shortfall in order to be liquidatable */
        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, VToken(0), 0, 0);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall == 0) {
            return uint(Error.INSUFFICIENT_SHORTFALL);
        }

        /* The liquidator may not repay more than what is allowed by the closeFactor */
        uint borrowBalance = VToken(vTokenBorrowed).borrowBalanceStored(borrower);
        (MathError mathErr, uint maxClose) = mulScalarTruncate(Exp({ mantissa: closeFactorMantissa }), borrowBalance);
        if (mathErr != MathError.NO_ERROR) {
            return uint(Error.MATH_ERROR);
        }
        if (repayAmount > maxClose) {
            return uint(Error.TOO_MUCH_REPAY);
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
     * @param vTokenBorrowed Asset which was borrowed by the borrower
     * @param vTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function liquidateBorrowVerify(
        address vTokenBorrowed,
        address vTokenCollateral,
        address liquidator,
        address borrower,
        uint actualRepayAmount,
        uint seizeTokens
    ) external {
        // Shh - currently unused
        vTokenBorrowed;
        vTokenCollateral;
        liquidator;
        borrower;
        actualRepayAmount;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param vTokenCollateral Asset which was used as collateral and will be seized
     * @param vTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address vTokenCollateral,
        address vTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPaused, "seize is paused");

        // Shh - currently unused
        seizeTokens;

        if (!markets[vTokenCollateral].isListed || !markets[vTokenBorrowed].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (VToken(vTokenCollateral).controller() != VToken(vTokenBorrowed).controller()) {
            return uint(Error.CONTROLLER_MISMATCH);
        }

        // Keep the flywheel moving
        updateUcoreSupplyIndex(vTokenCollateral);
        distributeSupplierUcore(vTokenCollateral, borrower, false);
        distributeSupplierUcore(vTokenCollateral, liquidator, false);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit logs.
     * @param vTokenCollateral Asset which was used as collateral and will be seized
     * @param vTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeVerify(
        address vTokenCollateral,
        address vTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external {
        // Shh - currently unused
        vTokenCollateral;
        vTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param vToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of vTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(
        address vToken,
        address src,
        address dst,
        uint transferTokens
    ) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer is paused");

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint allowed = redeemAllowedInternal(vToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateUcoreSupplyIndex(vToken);
        distributeSupplierUcore(vToken, src, false);
        distributeSupplierUcore(vToken, dst, false);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit logs.
     * @param vToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of vTokens to transfer
     */
    function transferVerify(address vToken, address src, address dst, uint transferTokens) external {
        // Shh - currently unused
        vToken;
        src;
        dst;
        transferTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `vTokenBalance` is the number of vTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint vTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, VToken(0), 0, 0);

        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param vTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address vTokenModify,
        uint redeemTokens,
        uint borrowAmount
    ) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(
            account,
            VToken(vTokenModify),
            redeemTokens,
            borrowAmount
        );
        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param vTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral vToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    // solhint-disable-next-line code-complexity
    function getHypotheticalAccountLiquidityInternal(
        address account,
        VToken vTokenModify,
        uint redeemTokens,
        uint borrowAmount
    ) internal view returns (Error, uint, uint) {
        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint oErr;
        MathError mErr;

        // For each asset the account is in
        VToken[] memory assets = accountAssets[account];
        for (uint i = 0; i < assets.length; i++) {
            VToken asset = assets[i];

            // Read the balances and exchange rate from the vToken
            (oErr, vars.vTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(
                account
            );
            if (oErr != 0) {
                // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }
            vars.collateralFactor = Exp({ mantissa: markets[address(asset)].collateralFactorMantissa });
            vars.exchangeRate = Exp({ mantissa: vars.exchangeRateMantissa });

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({ mantissa: vars.oraclePriceMantissa });

            // Pre-compute a conversion factor from tokens -> core (normalized price value)
            (mErr, vars.tokensToDenom) = mulExp3(vars.collateralFactor, vars.exchangeRate, vars.oraclePrice);
            if (mErr != MathError.NO_ERROR) {
                return (Error.MATH_ERROR, 0, 0);
            }

            // sumCollateral += tokensToDenom * vTokenBalance
            (mErr, vars.sumCollateral) = mulScalarTruncateAddUInt(
                vars.tokensToDenom,
                vars.vTokenBalance,
                vars.sumCollateral
            );
            if (mErr != MathError.NO_ERROR) {
                return (Error.MATH_ERROR, 0, 0);
            }

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(
                vars.oraclePrice,
                vars.borrowBalance,
                vars.sumBorrowPlusEffects
            );
            if (mErr != MathError.NO_ERROR) {
                return (Error.MATH_ERROR, 0, 0);
            }

            // Calculate effects of interacting with vTokenModify
            if (asset == vTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(
                    vars.tokensToDenom,
                    redeemTokens,
                    vars.sumBorrowPlusEffects
                );
                if (mErr != MathError.NO_ERROR) {
                    return (Error.MATH_ERROR, 0, 0);
                }

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(
                    vars.oraclePrice,
                    borrowAmount,
                    vars.sumBorrowPlusEffects
                );
                if (mErr != MathError.NO_ERROR) {
                    return (Error.MATH_ERROR, 0, 0);
                }
            }
        }

        /// @dev UAI Integration^
        (mErr, vars.sumBorrowPlusEffects) = addUInt(vars.sumBorrowPlusEffects, mintedUAIs[account]);
        if (mErr != MathError.NO_ERROR) {
            return (Error.MATH_ERROR, 0, 0);
        }
        /// @dev UAI Integration$

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (Error.NO_ERROR, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (Error.NO_ERROR, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in vToken.liquidateBorrowFresh)
     * @param vTokenBorrowed The address of the borrowed vToken
     * @param vTokenCollateral The address of the collateral vToken
     * @param actualRepayAmount The amount of vTokenBorrowed underlying to convert into vTokenCollateral tokens
     * @return (errorCode, number of vTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(
        address vTokenBorrowed,
        address vTokenCollateral,
        uint actualRepayAmount
    ) external view returns (uint, uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(VToken(vTokenBorrowed));
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(VToken(vTokenCollateral));
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa = VToken(vTokenCollateral).exchangeRateStored(); // Note: reverts on error
        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;
        MathError mathErr;

        (mathErr, numerator) = mulExp(liquidationIncentiveMantissa, priceBorrowedMantissa);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mathErr, denominator) = mulExp(priceCollateralMantissa, exchangeRateMantissa);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mathErr, ratio) = divExp(numerator, denominator);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mathErr, seizeTokens) = mulScalarTruncate(ratio, actualRepayAmount);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    /*** Admin Functions ***/

    /**
     * @notice Sets a new price oracle for the controller
     * @dev Admin function to set a new price oracle
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setPriceOracle(PriceOracle newOracle) public returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK);
        }

        // Track the old oracle for the controller
        PriceOracle oldOracle = oracle;

        // Set controller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Sets the closeFactor used when liquidating borrows
     * @dev Admin function to set closeFactor
     * @param newCloseFactorMantissa New close factor, scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setCloseFactor(uint newCloseFactorMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_CLOSE_FACTOR_OWNER_CHECK);
        }

        Exp memory newCloseFactorExp = Exp({ mantissa: newCloseFactorMantissa });
        Exp memory lowLimit = Exp({ mantissa: closeFactorMinMantissa });
        if (lessThanOrEqualExp(newCloseFactorExp, lowLimit)) {
            return fail(Error.INVALID_CLOSE_FACTOR, FailureInfo.SET_CLOSE_FACTOR_VALIDATION);
        }

        Exp memory highLimit = Exp({ mantissa: closeFactorMaxMantissa });
        if (lessThanExp(highLimit, newCloseFactorExp)) {
            return fail(Error.INVALID_CLOSE_FACTOR, FailureInfo.SET_CLOSE_FACTOR_VALIDATION);
        }

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, newCloseFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Sets the collateralFactor for a market
     * @dev Admin function to set per-market collateralFactor
     * @param vToken The market to set the factor on
     * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setCollateralFactor(VToken vToken, uint newCollateralFactorMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }

        // Verify market is listed
        Market storage market = markets[address(vToken)];
        if (!market.isListed) {
            return fail(Error.MARKET_NOT_LISTED, FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS);
        }

        Exp memory newCollateralFactorExp = Exp({ mantissa: newCollateralFactorMantissa });

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({ mantissa: collateralFactorMaxMantissa });
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        // If collateral factor != 0, fail if price == 0
        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(vToken) == 0) {
            return fail(Error.PRICE_ERROR, FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE);
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(vToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Sets maxAssets which controls how many markets can be entered
     * @dev Admin function to set maxAssets
     * @param newMaxAssets New max assets
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setMaxAssets(uint newMaxAssets) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_MAX_ASSETS_OWNER_CHECK);
        }

        uint oldMaxAssets = maxAssets;
        maxAssets = newMaxAssets;
        emit NewMaxAssets(oldMaxAssets, newMaxAssets);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Sets liquidationIncentive
     * @dev Admin function to set liquidationIncentive
     * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK);
        }

        // Check de-scaled min <= newLiquidationIncentive <= max
        Exp memory newLiquidationIncentive = Exp({ mantissa: newLiquidationIncentiveMantissa });
        Exp memory minLiquidationIncentive = Exp({ mantissa: liquidationIncentiveMinMantissa });
        if (lessThanExp(newLiquidationIncentive, minLiquidationIncentive)) {
            return fail(Error.INVALID_LIQUIDATION_INCENTIVE, FailureInfo.SET_LIQUIDATION_INCENTIVE_VALIDATION);
        }

        Exp memory maxLiquidationIncentive = Exp({ mantissa: liquidationIncentiveMaxMantissa });
        if (lessThanExp(maxLiquidationIncentive, newLiquidationIncentive)) {
            return fail(Error.INVALID_LIQUIDATION_INCENTIVE, FailureInfo.SET_LIQUIDATION_INCENTIVE_VALIDATION);
        }

        // Save current value for use in log
        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Add the market to the markets mapping and set it as listed
     * @dev Admin function to set isListed and add support for the market
     * @param vToken The address of the market (token) to list
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _supportMarket(VToken vToken) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SUPPORT_MARKET_OWNER_CHECK);
        }

        if (markets[address(vToken)].isListed) {
            return fail(Error.MARKET_ALREADY_LISTED, FailureInfo.SUPPORT_MARKET_EXISTS);
        }

        vToken.isVToken(); // Sanity check to make sure its really a VToken

        markets[address(vToken)] = Market({ isListed: true, isUcore: false, collateralFactorMantissa: 0 });

        _addMarketInternal(vToken);

        emit MarketListed(vToken);

        return uint(Error.NO_ERROR);
    }

    function _addMarketInternal(VToken vToken) internal {
        for (uint i = 0; i < allMarkets.length; i++) {
            require(allMarkets[i] != vToken, "market already added");
        }
        allMarkets.push(vToken);
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(address newPauseGuardian) public returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK);
        }

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;

        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
        emit NewPauseGuardian(oldPauseGuardian, newPauseGuardian);

        return uint(Error.NO_ERROR);
    }

    function _setMintPaused(
        VToken vToken,
        bool state
    ) public onlyListedMarket(vToken) validPauseState(state) returns (bool) {
        mintGuardianPaused[address(vToken)] = state;
        emit ActionPaused(vToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(
        VToken vToken,
        bool state
    ) public onlyListedMarket(vToken) validPauseState(state) returns (bool) {
        borrowGuardianPaused[address(vToken)] = state;
        emit ActionPaused(vToken, "Borrow", state);
        return state;
    }

    function _setTransferPaused(bool state) public validPauseState(state) returns (bool) {
        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public validPauseState(state) returns (bool) {
        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    function _setMintUAIPaused(bool state) public validPauseState(state) returns (bool) {
        mintUAIGuardianPaused = state;
        emit ActionPaused("MintUAI", state);
        return state;
    }

    function _setRepayUAIPaused(bool state) public validPauseState(state) returns (bool) {
        repayUAIGuardianPaused = state;
        emit ActionPaused("RepayUAI", state);
        return state;
    }

    /**
     * @notice Set whole protocol pause/unpause state
     */
    function _setProtocolPaused(bool state) public onlyAdmin returns (bool) {
        protocolPaused = state;
        emit ActionProtocolPaused(state);
        return state;
    }

    /**
     * @notice Sets a new UAI controller
     * @dev Admin function to set a new UAI controller
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setUAIController(UAIControllerInterface uaiController_) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_UAICONTROLLER_OWNER_CHECK);
        }

        UAIControllerInterface oldRate = uaiController;
        uaiController = uaiController_;
        emit NewUAIController(oldRate, uaiController_);
    }

    function _setUAIMintRate(uint newUAIMintRate) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_UAI_MINT_RATE_CHECK);
        }

        uint oldUAIMintRate = uaiMintRate;
        uaiMintRate = newUAIMintRate;
        emit NewUAIMintRate(oldUAIMintRate, newUAIMintRate);

        return uint(Error.NO_ERROR);
    }

    function _become(Unitroller unitroller) public {
        require(msg.sender == unitroller.admin(), "only unitroller admin can");
        require(unitroller._acceptImplementation() == 0, "not authorized");
    }

    /*** Ucore Distribution ***/

    /**
     * @notice Recalculate and update Ucore speeds for all Ucore markets
     */
    function refreshUcoreSpeeds() public {
        require(msg.sender == tx.origin, "only externally owned accounts can");
        refreshUcoreSpeedsInternal();
    }

    function refreshUcoreSpeedsInternal() internal {
        uint i;
        VToken vToken;

        for (i = 0; i < allMarkets.length; i++) {
            vToken = allMarkets[i];
            Exp memory borrowIndex = Exp({ mantissa: vToken.borrowIndex() });
            updateUcoreSupplyIndex(address(vToken));
            updateUcoreBorrowIndex(address(vToken), borrowIndex);
        }

        Exp memory totalUtility = Exp({ mantissa: 0 });
        Exp[] memory utilities = new Exp[](allMarkets.length);
        for (i = 0; i < allMarkets.length; i++) {
            vToken = allMarkets[i];
            if (markets[address(vToken)].isUcore) {
                Exp memory assetPrice = Exp({ mantissa: oracle.getUnderlyingPrice(vToken) });
                Exp memory utility = mul_(assetPrice, vToken.totalBorrows());
                utilities[i] = utility;
                totalUtility = add_(totalUtility, utility);
            }
        }

        for (i = 0; i < allMarkets.length; i++) {
            vToken = allMarkets[i];
            uint newSpeed = totalUtility.mantissa > 0 ? mul_(ucoreRate, div_(utilities[i], totalUtility)) : 0;
            ucoreSpeeds[address(vToken)] = newSpeed;
            emit UcoreSpeedUpdated(vToken, newSpeed);
        }
    }

    /**
     * @notice Accrue UCORE to the market by updating the supply index
     * @param vToken The market whose supply index to update
     */
    function updateUcoreSupplyIndex(address vToken) internal {
        UcoreMarketState storage supplyState = ucoreSupplyState[vToken];
        uint supplySpeed = ucoreSpeeds[vToken];
        uint blockNumber = getBlockNumber();
        uint deltaBlocks = sub_(blockNumber, uint(supplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint supplyTokens = VToken(vToken).totalSupply();
            uint ucoreAccrued = mul_(deltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens > 0 ? fraction(ucoreAccrued, supplyTokens) : Double({ mantissa: 0 });
            Double memory index = add_(Double({ mantissa: supplyState.index }), ratio);
            ucoreSupplyState[vToken] = UcoreMarketState({
                index: safe224(index.mantissa, "new index overflows"),
                block: safe32(blockNumber, "block number overflows")
            });
        } else if (deltaBlocks > 0) {
            supplyState.block = safe32(blockNumber, "block number overflows");
        }
    }

    /**
     * @notice Accrue UCORE to the market by updating the borrow index
     * @param vToken The market whose borrow index to update
     */
    function updateUcoreBorrowIndex(address vToken, Exp memory marketBorrowIndex) internal {
        UcoreMarketState storage borrowState = ucoreBorrowState[vToken];
        uint borrowSpeed = ucoreSpeeds[vToken];
        uint blockNumber = getBlockNumber();
        uint deltaBlocks = sub_(blockNumber, uint(borrowState.block));
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint borrowAmount = div_(VToken(vToken).totalBorrows(), marketBorrowIndex);
            uint ucoreAccrued = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0 ? fraction(ucoreAccrued, borrowAmount) : Double({ mantissa: 0 });
            Double memory index = add_(Double({ mantissa: borrowState.index }), ratio);
            ucoreBorrowState[vToken] = UcoreMarketState({
                index: safe224(index.mantissa, "new index overflows"),
                block: safe32(blockNumber, "block number overflows")
            });
        } else if (deltaBlocks > 0) {
            borrowState.block = safe32(blockNumber, "block number overflows");
        }
    }

    /**
     * @notice Accrue UCORE to by updating the UAI minter index
     */
    function updateUcoreUAIMintIndex() internal {
        if (address(uaiController) != address(0)) {
            uaiController.updateUcoreUAIMintIndex();
        }
    }

    /**
     * @notice Calculate UCORE accrued by a supplier and possibly transfer it to them
     * @param vToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute UCORE to
     */
    function distributeSupplierUcore(address vToken, address supplier, bool distributeAll) internal {
        UcoreMarketState storage supplyState = ucoreSupplyState[vToken];
        Double memory supplyIndex = Double({ mantissa: supplyState.index });
        Double memory supplierIndex = Double({ mantissa: ucoreSupplierIndex[vToken][supplier] });
        ucoreSupplierIndex[vToken][supplier] = supplyIndex.mantissa;

        if (supplierIndex.mantissa == 0 && supplyIndex.mantissa > 0) {
            supplierIndex.mantissa = ucoreInitialIndex;
        }

        Double memory deltaIndex = sub_(supplyIndex, supplierIndex);
        uint supplierTokens = VToken(vToken).balanceOf(supplier);
        uint supplierDelta = mul_(supplierTokens, deltaIndex);
        uint supplierAccrued = add_(ucoreAccrued[supplier], supplierDelta);
        ucoreAccrued[supplier] = transferUCORE(supplier, supplierAccrued, distributeAll ? 0 : ucoreClaimThreshold);
        emit DistributedSupplierUcore(VToken(vToken), supplier, supplierDelta, supplyIndex.mantissa);
    }

    /**
     * @notice Calculate UCORE accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param vToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute UCORE to
     */
    function distributeBorrowerUcore(
        address vToken,
        address borrower,
        Exp memory marketBorrowIndex,
        bool distributeAll
    ) internal {
        UcoreMarketState storage borrowState = ucoreBorrowState[vToken];
        Double memory borrowIndex = Double({ mantissa: borrowState.index });
        Double memory borrowerIndex = Double({ mantissa: ucoreBorrowerIndex[vToken][borrower] });
        ucoreBorrowerIndex[vToken][borrower] = borrowIndex.mantissa;

        if (borrowerIndex.mantissa > 0) {
            Double memory deltaIndex = sub_(borrowIndex, borrowerIndex);
            uint borrowerAmount = div_(VToken(vToken).borrowBalanceStored(borrower), marketBorrowIndex);
            uint borrowerDelta = mul_(borrowerAmount, deltaIndex);
            uint borrowerAccrued = add_(ucoreAccrued[borrower], borrowerDelta);
            ucoreAccrued[borrower] = transferUCORE(borrower, borrowerAccrued, distributeAll ? 0 : ucoreClaimThreshold);
            emit DistributedBorrowerUcore(VToken(vToken), borrower, borrowerDelta, borrowIndex.mantissa);
        }
    }

    /**
     * @notice Calculate UCORE accrued by a UAI minter and possibly transfer it to them
     * @dev UAI minters will not begin to accrue until after the first interaction with the protocol.
     * @param uaiMinter The address of the UAI minter to distribute UCORE to
     */
    function distributeUAIMinterUcore(address uaiMinter, bool distributeAll) internal {
        if (address(uaiController) != address(0)) {
            uint uaiMinterAccrued;
            uint uaiMinterDelta;
            uint uaiMintIndexMantissa;
            uint err;
            (err, uaiMinterAccrued, uaiMinterDelta, uaiMintIndexMantissa) = uaiController.calcDistributeUAIMinterUcore(
                uaiMinter
            );
            if (err == uint(Error.NO_ERROR)) {
                ucoreAccrued[uaiMinter] = transferUCORE(
                    uaiMinter,
                    uaiMinterAccrued,
                    distributeAll ? 0 : ucoreClaimThreshold
                );
                emit DistributedUAIMinterUcore(uaiMinter, uaiMinterDelta, uaiMintIndexMantissa);
            }
        }
    }

    /**
     * @notice Transfer UCORE to the user, if they are above the threshold
     * @dev Note: If there is not enough UCORE, we do not perform the transfer all.
     * @param user The address of the user to transfer UCORE to
     * @param userAccrued The amount of UCORE to (possibly) transfer
     * @return The amount of UCORE which was NOT transferred to the user
     */
    function transferUCORE(address user, uint userAccrued, uint threshold) internal returns (uint) {
        if (userAccrued >= threshold && userAccrued > 0) {
            UCORE ucore = UCORE(getUCOREAddress());
            uint ucoreRemaining = ucore.balanceOf(address(this));
            if (userAccrued <= ucoreRemaining) {
                ucore.transfer(user, userAccrued);
                return 0;
            }
        }
        return userAccrued;
    }

    /**
     * @notice Claim all the ucore accrued by holder in all markets and UAI
     * @param holder The address to claim UCORE for
     */
    function claimUcore(address holder) public {
        return claimUcore(holder, allMarkets);
    }

    /**
     * @notice Claim all the ucore accrued by holder in the specified markets
     * @param holder The address to claim UCORE for
     * @param vTokens The list of markets to claim UCORE in
     */
    function claimUcore(address holder, VToken[] memory vTokens) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claimUcore(holders, vTokens, true, true);
    }

    /**
     * @notice Claim all ucore accrued by the holders
     * @param holders The addresses to claim UCORE for
     * @param vTokens The list of markets to claim UCORE in
     * @param borrowers Whether or not to claim UCORE earned by borrowing
     * @param suppliers Whether or not to claim UCORE earned by supplying
     */
    function claimUcore(address[] memory holders, VToken[] memory vTokens, bool borrowers, bool suppliers) public {
        uint j;
        updateUcoreUAIMintIndex();
        for (j = 0; j < holders.length; j++) {
            distributeUAIMinterUcore(holders[j], true);
        }
        for (uint i = 0; i < vTokens.length; i++) {
            VToken vToken = vTokens[i];
            require(markets[address(vToken)].isListed, "not listed market");
            if (borrowers) {
                Exp memory borrowIndex = Exp({ mantissa: vToken.borrowIndex() });
                updateUcoreBorrowIndex(address(vToken), borrowIndex);
                for (j = 0; j < holders.length; j++) {
                    distributeBorrowerUcore(address(vToken), holders[j], borrowIndex, true);
                }
            }
            if (suppliers) {
                updateUcoreSupplyIndex(address(vToken));
                for (j = 0; j < holders.length; j++) {
                    distributeSupplierUcore(address(vToken), holders[j], true);
                }
            }
        }
    }

    /*** Ucore Distribution Admin ***/

    /**
     * @notice Set the amount of UCORE distributed per block
     * @param ucoreRate_ The amount of UCORE wei per block to distribute
     */
    function _setUcoreRate(uint ucoreRate_) public onlyAdmin {
        uint oldRate = ucoreRate;
        ucoreRate = ucoreRate_;
        emit NewUcoreRate(oldRate, ucoreRate_);

        refreshUcoreSpeedsInternal();
    }

    /**
     * @notice Add markets to ucoreMarkets, allowing them to earn UCORE in the flywheel
     * @param vTokens The addresses of the markets to add
     */
    function _addUcoreMarkets(address[] calldata vTokens) external onlyAdmin {
        for (uint i = 0; i < vTokens.length; i++) {
            _addUcoreMarketInternal(vTokens[i]);
        }

        refreshUcoreSpeedsInternal();
    }

    function _addUcoreMarketInternal(address vToken) internal {
        Market storage market = markets[vToken];
        require(market.isListed, "ucore market is not listed");
        require(!market.isUcore, "ucore market already added");

        market.isUcore = true;
        emit MarketUcore(VToken(vToken), true);

        if (ucoreSupplyState[vToken].index == 0 && ucoreSupplyState[vToken].block == 0) {
            ucoreSupplyState[vToken] = UcoreMarketState({
                index: ucoreInitialIndex,
                block: safe32(getBlockNumber(), "block number overflows")
            });
        }

        if (ucoreBorrowState[vToken].index == 0 && ucoreBorrowState[vToken].block == 0) {
            ucoreBorrowState[vToken] = UcoreMarketState({
                index: ucoreInitialIndex,
                block: safe32(getBlockNumber(), "block number overflows")
            });
        }
    }

    function _initializeUcoreUAIState(uint blockNumber) public {
        require(msg.sender == admin, "only admin can");
        if (address(uaiController) != address(0)) {
            uaiController._initializeUcoreUAIState(blockNumber);
        }
    }

    /**
     * @notice Remove a market from ucoreMarkets, preventing it from earning UCORE in the flywheel
     * @param vToken The address of the market to drop
     */
    function _dropUcoreMarket(address vToken) public onlyAdmin {
        Market storage market = markets[vToken];
        require(market.isUcore == true, "not ucore market");

        market.isUcore = false;
        emit MarketUcore(VToken(vToken), false);

        refreshUcoreSpeedsInternal();
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() public view returns (VToken[] memory) {
        return allMarkets;
    }

    function getBlockNumber() public view returns (uint) {
        return block.number;
    }

    /**
     * @notice Return the address of the UCORE token
     * @return The address of UCORE
     */
    function getUCOREAddress() public view returns (address) {
        return 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;
    }

    /*** UAI functions ***/

    /**
     * @notice Set the minted UAI amount of the `owner`
     * @param owner The address of the account to set
     * @param amount The amount of UAI to set to the account
     * @return The number of minted UAI by `owner`
     */
    function setMintedUAIOf(address owner, uint amount) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintUAIGuardianPaused && !repayUAIGuardianPaused, "UAI is paused");
        // Check caller is uaiController
        if (msg.sender != address(uaiController)) {
            return fail(Error.REJECTION, FailureInfo.SET_MINTED_UAI_REJECTION);
        }
        mintedUAIs[owner] = amount;

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Mint UAI
     */
    function mintUAI(uint mintUAIAmount) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintUAIGuardianPaused, "mintUAI is paused");

        // Keep the flywheel moving
        updateUcoreUAIMintIndex();
        distributeUAIMinterUcore(msg.sender, false);
        return uaiController.mintUAI(msg.sender, mintUAIAmount);
    }

    /**
     * @notice Repay UAI
     */
    function repayUAI(uint repayUAIAmount) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!repayUAIGuardianPaused, "repayUAI is paused");

        // Keep the flywheel moving
        updateUcoreUAIMintIndex();
        distributeUAIMinterUcore(msg.sender, false);
        return uaiController.repayUAI(msg.sender, repayUAIAmount);
    }

    /**
     * @notice Get the minted UAI amount of the `owner`
     * @param owner The address of the account to query
     * @return The number of minted UAI by `owner`
     */
    function mintedUAIOf(address owner) external view returns (uint) {
        return mintedUAIs[owner];
    }

    /**
     * @notice Get Mintable UAI amount
     */
    function getMintableUAI(address minter) external view returns (uint, uint) {
        return uaiController.getMintableUAI(minter);
    }
}

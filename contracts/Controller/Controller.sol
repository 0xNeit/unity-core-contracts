pragma solidity ^0.5.16;

import "../Oracle/PriceOracle.sol";
import "../Tokens/VTokens/VToken.sol";
import "../Utils/ErrorReporter.sol";
import "../Tokens/UCORE/UCORE.sol";
import "../Tokens/UAI/UAI.sol";
import "../Governance/IAccessControlManager.sol";
import "./ControllerLensInterface.sol";
import "./ControllerInterface.sol";
import "./ControllerStorage.sol";
import "./Unitroller.sol";

/**
 * @title UnityCore's Controller Contract
 * @author UnityCore
 */
contract Controller is ControllerV11Storage, ControllerInterfaceG2, ControllerErrorReporter, ExponentialNoError {
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

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);

    /// @notice Emitted when UAI Vault info is changed
    event NewUAIVaultInfo(address vault_, uint releaseStartBlock_, uint releaseInterval_);

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused on a market
    event ActionPausedMarket(VToken indexed vToken, Action indexed action, bool pauseState);

    /// @notice Emitted when Ucore UAI Vault rate is changed
    event NewUcoreUAIVaultRate(uint oldUcoreUAIVaultRate, uint newUcoreUAIVaultRate);

    /// @notice Emitted when a new borrow-side UCORE speed is calculated for a market
    event UcoreBorrowSpeedUpdated(VToken indexed vToken, uint newSpeed);

    /// @notice Emitted when a new supply-side UCORE speed is calculated for a market
    event UcoreSupplySpeedUpdated(VToken indexed vToken, uint newSpeed);

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

    /// @notice Emitted when UCORE is distributed to UAI Vault
    event DistributedUAIVaultUcore(uint amount);

    /// @notice Emitted when UAIController is changed
    event NewUAIController(UAIControllerInterface oldUAIController, UAIControllerInterface newUAIController);

    /// @notice Emitted when UAI mint rate is changed by admin
    event NewUAIMintRate(uint oldUAIMintRate, uint newUAIMintRate);

    /// @notice Emitted when protocol state is changed by admin
    event ActionProtocolPaused(bool state);

    /// @notice Emitted when borrow cap for a vToken is changed
    event NewBorrowCap(VToken indexed vToken, uint newBorrowCap);

    /// @notice Emitted when treasury guardian is changed
    event NewTreasuryGuardian(address oldTreasuryGuardian, address newTreasuryGuardian);

    /// @notice Emitted when treasury address is changed
    event NewTreasuryAddress(address oldTreasuryAddress, address newTreasuryAddress);

    /// @notice Emitted when treasury percent is changed
    event NewTreasuryPercent(uint oldTreasuryPercent, uint newTreasuryPercent);

    // @notice Emitted when liquidator adress is changed
    event NewLiquidatorContract(address oldLiquidatorContract, address newLiquidatorContract);

    /// @notice Emitted when Ucore is granted by admin
    event UcoreGranted(address recipient, uint amount);

    /// @notice Emitted whe ControllerLens address is changed
    event NewControllerLens(address oldControllerLens, address newControllerLens);

    /// @notice Emitted when supply cap for a vToken is changed
    event NewSupplyCap(VToken indexed vToken, uint newSupplyCap);

    /// @notice Emitted when access control address is changed by admin
    event NewAccessControl(address oldAccessControlAddress, address newAccessControlAddress);

    /// @notice Emitted when the borrowing delegate rights are updated for an account
    event DelegateUpdated(address borrower, address delegate, bool allowDelegatedBorrows);

    /// @notice The initial Ucore index for a market
    uint224 public constant ucoreInitialIndex = 1e36;

    // closeFactorMantissa must be strictly greater than this value
    uint internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa must not exceed this value
    uint internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // No collateralFactorMantissa may exceed this value
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    constructor() public {
        admin = msg.sender;
    }

    /// @notice Reverts if the protocol is paused
    function checkProtocolPauseState() private view {
        require(!protocolPaused, "protocol is paused");
    }

    /// @notice Reverts if a certain action is paused on a market
    function checkActionPauseState(address market, Action action) private view {
        require(!actionPaused(market, action), "action is paused");
    }

    /// @notice Reverts if the caller is not admin
    function ensureAdmin() private view {
        require(msg.sender == admin, "only admin can");
    }

    /// @notice Checks the passed address is nonzero
    function ensureNonzeroAddress(address someone) private pure {
        require(someone != address(0), "can't be zero address");
    }

    /// @notice Reverts if the market is not listed
    function ensureListed(Market storage market) private view {
        require(market.isListed, "market not listed");
    }

    /// @notice Reverts if the caller is neither admin nor the passed address
    function ensureAdminOr(address privilegedAddress) private view {
        require(msg.sender == admin || msg.sender == privilegedAddress, "access denied");
    }

    function ensureAllowed(string memory functionSig) private view {
        require(IAccessControlManager(accessControl).isAllowedToCall(msg.sender, functionSig), "access denied");
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
        for (uint i; i < len; ++i) {
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
        checkActionPauseState(address(vToken), Action.ENTER_MARKET);

        Market storage marketToJoin = markets[address(vToken)];
        ensureListed(marketToJoin);

        if (marketToJoin.accountMembership[borrower]) {
            // already joined
            return Error.NO_ERROR;
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
        checkActionPauseState(vTokenAddress, Action.EXIT_MARKET);

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
        for (; i < len; ++i) {
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

    /**
     * @notice Grants or revokes the borrowing delegate rights to / from an account.
     *  If allowed, the delegate will be able to borrow funds on behalf of the sender.
     *  Upon a delegated borrow, the delegate will receive the funds, and the borrower
     *  will see the debt on their account.
     * @param delegate The address to update the rights for
     * @param allowBorrows Whether to grant (true) or revoke (false) the rights
     */
    function updateDelegate(address delegate, bool allowBorrows) external {
        _updateDelegate(msg.sender, delegate, allowBorrows);
    }

    function _updateDelegate(address borrower, address delegate, bool allowBorrows) internal {
        approvedDelegates[borrower][delegate] = allowBorrows;
        emit DelegateUpdated(borrower, delegate, allowBorrows);
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param vToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(address vToken, address minter, uint mintAmount) external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        checkProtocolPauseState();
        checkActionPauseState(vToken, Action.MINT);
        ensureListed(markets[vToken]);

        uint256 supplyCap = supplyCaps[vToken];
        require(supplyCap != 0, "market supply cap is 0");

        uint256 vTokenSupply = VToken(vToken).totalSupply();
        Exp memory exchangeRate = Exp({ mantissa: VToken(vToken).exchangeRateStored() });
        uint256 nextTotalSupply = mul_ScalarTruncateAddUInt(exchangeRate, vTokenSupply, mintAmount);
        require(nextTotalSupply <= supplyCap, "market supply cap reached");

        // Keep the flywheel moving
        updateUcoreSupplyIndex(vToken);
        distributeSupplierUcore(vToken, minter);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param vToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(address vToken, address minter, uint actualMintAmount, uint mintTokens) external {}

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param vToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of vTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(address vToken, address redeemer, uint redeemTokens) external returns (uint) {
        checkProtocolPauseState();
        checkActionPauseState(vToken, Action.REDEEM);

        uint allowed = redeemAllowedInternal(vToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateUcoreSupplyIndex(vToken);
        distributeSupplierUcore(vToken, redeemer);

        return uint(Error.NO_ERROR);
    }

    function redeemAllowedInternal(address vToken, address redeemer, uint redeemTokens) internal view returns (uint) {
        ensureListed(markets[vToken]);

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
    // solhint-disable-next-line no-unused-vars
    function redeemVerify(address vToken, address redeemer, uint redeemAmount, uint redeemTokens) external {
        require(redeemTokens != 0 || redeemAmount == 0, "redeemTokens zero");
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param vToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(address vToken, address borrower, uint borrowAmount) external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        checkProtocolPauseState();
        checkActionPauseState(vToken, Action.BORROW);

        ensureListed(markets[vToken]);

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

        uint borrowCap = borrowCaps[vToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint nextTotalBorrows = add_(VToken(vToken).totalBorrows(), borrowAmount);
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
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
        distributeBorrowerUcore(vToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit logs.
     * @param vToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    function borrowVerify(address vToken, address borrower, uint borrowAmount) external {}

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param vToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(
        address vToken,
        // solhint-disable-next-line no-unused-vars
        address payer,
        address borrower,
        // solhint-disable-next-line no-unused-vars
        uint repayAmount
    ) external returns (uint) {
        checkProtocolPauseState();
        checkActionPauseState(vToken, Action.REPAY);
        ensureListed(markets[vToken]);

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({ mantissa: VToken(vToken).borrowIndex() });
        updateUcoreBorrowIndex(vToken, borrowIndex);
        distributeBorrowerUcore(vToken, borrower, borrowIndex);

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
    ) external {}

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
    ) external returns (uint) {
        checkProtocolPauseState();

        // if we want to pause liquidating to vTokenCollateral, we should pause seizing
        checkActionPauseState(vTokenBorrowed, Action.LIQUIDATE);

        if (liquidatorContract != address(0) && liquidator != liquidatorContract) {
            return uint(Error.UNAUTHORIZED);
        }

        ensureListed(markets[vTokenCollateral]);
        if (address(vTokenBorrowed) != address(uaiController)) {
            ensureListed(markets[vTokenBorrowed]);
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
        uint borrowBalance;
        if (address(vTokenBorrowed) != address(uaiController)) {
            borrowBalance = VToken(vTokenBorrowed).borrowBalanceStored(borrower);
        } else {
            borrowBalance = uaiController.getUAIRepayAmount(borrower);
        }
        // maxClose = multipy of closeFactorMantissa and borrowBalance
        if (repayAmount > mul_ScalarTruncate(Exp({ mantissa: closeFactorMantissa }), borrowBalance)) {
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
     * @param seizeTokens The amount of collateral token that will be seized
     */
    function liquidateBorrowVerify(
        address vTokenBorrowed,
        address vTokenCollateral,
        address liquidator,
        address borrower,
        uint actualRepayAmount,
        uint seizeTokens
    ) external {}

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
        uint seizeTokens // solhint-disable-line no-unused-vars
    ) external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        checkProtocolPauseState();
        checkActionPauseState(vTokenCollateral, Action.SEIZE);

        // We've added UAIController as a borrowed token list check for seize
        ensureListed(markets[vTokenCollateral]);
        if (address(vTokenBorrowed) != address(uaiController)) {
            ensureListed(markets[vTokenBorrowed]);
        }

        if (VToken(vTokenCollateral).controller() != VToken(vTokenBorrowed).controller()) {
            return uint(Error.CONTROLLER_MISMATCH);
        }

        // Keep the flywheel moving
        updateUcoreSupplyIndex(vTokenCollateral);
        distributeSupplierUcore(vTokenCollateral, borrower);
        distributeSupplierUcore(vTokenCollateral, liquidator);

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
    ) external {}

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param vToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of vTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(address vToken, address src, address dst, uint transferTokens) external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        checkProtocolPauseState();
        checkActionPauseState(vToken, Action.TRANSFER);

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint allowed = redeemAllowedInternal(vToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateUcoreSupplyIndex(vToken);
        distributeSupplierUcore(vToken, src);
        distributeSupplierUcore(vToken, dst);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit logs.
     * @param vToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of vTokens to transfer
     */
    function transferVerify(address vToken, address src, address dst, uint transferTokens) external {}

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account) external view returns (uint, uint, uint) {
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
    ) external view returns (uint, uint, uint) {
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
    function getHypotheticalAccountLiquidityInternal(
        address account,
        VToken vTokenModify,
        uint redeemTokens,
        uint borrowAmount
    ) internal view returns (Error, uint, uint) {
        (uint err, uint liquidity, uint shortfall) = controllerLens.getHypotheticalAccountLiquidity(
            address(this),
            account,
            vTokenModify,
            redeemTokens,
            borrowAmount
        );
        return (Error(err), liquidity, shortfall);
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
        (uint err, uint seizeTokens) = controllerLens.liquidateCalculateSeizeTokens(
            address(this),
            vTokenBorrowed,
            vTokenCollateral,
            actualRepayAmount
        );
        return (err, seizeTokens);
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in vToken.liquidateBorrowFresh)
     * @param vTokenCollateral The address of the collateral vToken
     * @param actualRepayAmount The amount of vTokenBorrowed underlying to convert into vTokenCollateral tokens
     * @return (errorCode, number of vTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateUAICalculateSeizeTokens(
        address vTokenCollateral,
        uint actualRepayAmount
    ) external view returns (uint, uint) {
        (uint err, uint seizeTokens) = controllerLens.liquidateUAICalculateSeizeTokens(
            address(this),
            vTokenCollateral,
            actualRepayAmount
        );
        return (err, seizeTokens);
    }

    /*** Admin Functions ***/

    /**
     * @notice Sets a new price oracle for the controller
     * @dev Admin function to set a new price oracle
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setPriceOracle(PriceOracle newOracle) external returns (uint) {
        // Check caller is admin
        ensureAdmin();
        ensureNonzeroAddress(address(newOracle));

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
     * @return uint 0=success, otherwise will revert
     */
    function _setCloseFactor(uint newCloseFactorMantissa) external returns (uint) {
        // Check caller is admin
        ensureAdmin();

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, newCloseFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Sets the address of the access control of this contract
     * @dev Admin function to set the access control address
     * @param newAccessControlAddress New address for the access control
     * @return uint 0=success, otherwise will revert
     */
    function _setAccessControl(address newAccessControlAddress) external returns (uint) {
        // Check caller is admin
        ensureAdmin();
        ensureNonzeroAddress(newAccessControlAddress);

        address oldAccessControlAddress = accessControl;
        accessControl = newAccessControlAddress;
        emit NewAccessControl(oldAccessControlAddress, accessControl);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Sets the collateralFactor for a market
     * @dev Restricted function to set per-market collateralFactor
     * @param vToken The market to set the factor on
     * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setCollateralFactor(VToken vToken, uint newCollateralFactorMantissa) external returns (uint) {
        // Check caller is allowed by access control manager
        ensureAllowed("_setCollateralFactor(address,uint256)");
        ensureNonzeroAddress(address(vToken));

        // Verify market is listed
        Market storage market = markets[address(vToken)];
        ensureListed(market);

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
     * @notice Sets liquidationIncentive
     * @dev Admin function to set liquidationIncentive
     * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external returns (uint) {
        ensureAllowed("_setLiquidationIncentive(uint256)");

        require(newLiquidationIncentiveMantissa >= 1e18, "incentive must be over 1e18");

        // Save current value for use in log
        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

        return uint(Error.NO_ERROR);
    }

    function _setLiquidatorContract(address newLiquidatorContract_) external {
        // Check caller is admin
        ensureAdmin();
        address oldLiquidatorContract = liquidatorContract;
        liquidatorContract = newLiquidatorContract_;
        emit NewLiquidatorContract(oldLiquidatorContract, newLiquidatorContract_);
    }

    /**
     * @notice Add the market to the markets mapping and set it as listed
     * @dev Admin function to set isListed and add support for the market
     * @param vToken The address of the market (token) to list
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _supportMarket(VToken vToken) external returns (uint) {
        ensureAllowed("_supportMarket(address)");

        if (markets[address(vToken)].isListed) {
            return fail(Error.MARKET_ALREADY_LISTED, FailureInfo.SUPPORT_MARKET_EXISTS);
        }

        vToken.isVToken(); // Sanity check to make sure its really a VToken

        // Note that isUcore is not in active use anymore
        markets[address(vToken)] = Market({ isListed: true, isUcore: false, collateralFactorMantissa: 0 });

        _addMarketInternal(vToken);
        _initializeMarket(address(vToken));

        emit MarketListed(vToken);

        return uint(Error.NO_ERROR);
    }

    function _addMarketInternal(VToken vToken) internal {
        for (uint i; i < allMarkets.length; ++i) {
            require(allMarkets[i] != vToken, "market already added");
        }
        allMarkets.push(vToken);
    }

    function _initializeMarket(address vToken) internal {
        uint32 blockNumber = safe32(getBlockNumber(), "block number exceeds 32 bits");

        UcoreMarketState storage supplyState = ucoreSupplyState[vToken];
        UcoreMarketState storage borrowState = ucoreBorrowState[vToken];

        /*
         * Update market state indices
         */
        if (supplyState.index == 0) {
            // Initialize supply state index with default value
            supplyState.index = ucoreInitialIndex;
        }

        if (borrowState.index == 0) {
            // Initialize borrow state index with default value
            borrowState.index = ucoreInitialIndex;
        }

        /*
         * Update market state block numbers
         */
        supplyState.block = borrowState.block = blockNumber;
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(address newPauseGuardian) external returns (uint) {
        ensureAdmin();
        ensureNonzeroAddress(newPauseGuardian);

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;

        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
        emit NewPauseGuardian(oldPauseGuardian, newPauseGuardian);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Set the given borrow caps for the given vToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
     * @dev Access is controled by ACM. A borrow cap of 0 corresponds to unlimited borrowing.
     * @param vTokens The addresses of the markets (tokens) to change the borrow caps for
     * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
     */
    function _setMarketBorrowCaps(VToken[] calldata vTokens, uint[] calldata newBorrowCaps) external {
        ensureAllowed("_setMarketBorrowCaps(address[],uint256[])");

        uint numMarkets = vTokens.length;
        uint numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "invalid input");

        for (uint i; i < numMarkets; ++i) {
            borrowCaps[address(vTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(vTokens[i], newBorrowCaps[i]);
        }
    }

    /**
     * @notice Set the given supply caps for the given vToken markets. Supply that brings total Supply to or above supply cap will revert.
     * @dev Admin function to set the supply caps. A supply cap of 0 corresponds to Minting NotAllowed.
     * @param vTokens The addresses of the markets (tokens) to change the supply caps for
     * @param newSupplyCaps The new supply cap values in underlying to be set. A value of 0 corresponds to Minting NotAllowed.
     */
    function _setMarketSupplyCaps(VToken[] calldata vTokens, uint256[] calldata newSupplyCaps) external {
        ensureAllowed("_setMarketSupplyCaps(address[],uint256[])");

        uint numMarkets = vTokens.length;
        uint numSupplyCaps = newSupplyCaps.length;

        require(numMarkets != 0 && numMarkets == numSupplyCaps, "invalid input");

        for (uint i; i < numMarkets; ++i) {
            supplyCaps[address(vTokens[i])] = newSupplyCaps[i];
            emit NewSupplyCap(vTokens[i], newSupplyCaps[i]);
        }
    }

    /**
     * @notice Set whole protocol pause/unpause state
     */
    function _setProtocolPaused(bool state) external returns (bool) {
        ensureAllowed("_setProtocolPaused(bool)");

        protocolPaused = state;
        emit ActionProtocolPaused(state);
        return state;
    }

    /**
     * @notice Pause/unpause certain actions
     * @param markets Markets to pause/unpause the actions on
     * @param actions List of action ids to pause/unpause
     * @param paused The new paused state (true=paused, false=unpaused)
     */
    function _setActionsPaused(address[] calldata markets, Action[] calldata actions, bool paused) external {
        ensureAllowed("_setActionsPaused(address[],uint256[],bool)");

        uint256 numMarkets = markets.length;
        uint256 numActions = actions.length;
        for (uint marketIdx; marketIdx < numMarkets; ++marketIdx) {
            for (uint actionIdx; actionIdx < numActions; ++actionIdx) {
                setActionPausedInternal(markets[marketIdx], actions[actionIdx], paused);
            }
        }
    }

    /**
     * @dev Pause/unpause an action on a market
     * @param market Market to pause/unpause the action on
     * @param action Action id to pause/unpause
     * @param paused The new paused state (true=paused, false=unpaused)
     */
    function setActionPausedInternal(address market, Action action, bool paused) internal {
        ensureListed(markets[market]);
        _actionPaused[market][uint(action)] = paused;
        emit ActionPausedMarket(VToken(market), action, paused);
    }

    /**
     * @notice Sets a new UAI controller
     * @dev Admin function to set a new UAI controller
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setUAIController(UAIControllerInterface uaiController_) external returns (uint) {
        // Check caller is admin
        ensureAdmin();
        ensureNonzeroAddress(address(uaiController_));

        UAIControllerInterface oldUaiController = uaiController;
        uaiController = uaiController_;
        emit NewUAIController(oldUaiController, uaiController_);

        return uint(Error.NO_ERROR);
    }

    function _setUAIMintRate(uint newUAIMintRate) external returns (uint) {
        // Check caller is admin
        ensureAdmin();
        uint oldUAIMintRate = uaiMintRate;
        uaiMintRate = newUAIMintRate;
        emit NewUAIMintRate(oldUAIMintRate, newUAIMintRate);

        return uint(Error.NO_ERROR);
    }

    function _setTreasuryData(
        address newTreasuryGuardian,
        address newTreasuryAddress,
        uint newTreasuryPercent
    ) external returns (uint) {
        // Check caller is admin
        ensureAdminOr(treasuryGuardian);

        require(newTreasuryPercent < 1e18, "treasury percent cap overflow");
        ensureNonzeroAddress(newTreasuryGuardian);
        ensureNonzeroAddress(newTreasuryAddress);

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

    function _become(Unitroller unitroller) external {
        require(msg.sender == unitroller.admin(), "only unitroller admin can");
        require(unitroller._acceptImplementation() == 0, "not authorized");
    }

    /*** Ucore Distribution ***/

    function setUcoreSpeedInternal(VToken vToken, uint supplySpeed, uint borrowSpeed) internal {
        ensureListed(markets[address(vToken)]);

        if (ucoreSupplySpeeds[address(vToken)] != supplySpeed) {
            // Supply speed updated so let's update supply state to ensure that
            //  1. UCORE accrued properly for the old speed, and
            //  2. UCORE accrued at the new speed starts after this block.

            updateUcoreSupplyIndex(address(vToken));
            // Update speed and emit event
            ucoreSupplySpeeds[address(vToken)] = supplySpeed;
            emit UcoreSupplySpeedUpdated(vToken, supplySpeed);
        }

        if (ucoreBorrowSpeeds[address(vToken)] != borrowSpeed) {
            // Borrow speed updated so let's update borrow state to ensure that
            //  1. UCORE accrued properly for the old speed, and
            //  2. UCORE accrued at the new speed starts after this block.
            Exp memory borrowIndex = Exp({ mantissa: vToken.borrowIndex() });
            updateUcoreBorrowIndex(address(vToken), borrowIndex);

            // Update speed and emit event
            ucoreBorrowSpeeds[address(vToken)] = borrowSpeed;
            emit UcoreBorrowSpeedUpdated(vToken, borrowSpeed);
        }
    }

    /**
     * @dev Set ControllerLens contract address
     */
    function _setControllerLens(ControllerLensInterface controllerLens_) external returns (uint) {
        ensureAdmin();
        ensureNonzeroAddress(address(controllerLens_));
        address oldControllerLens = address(controllerLens);
        controllerLens = controllerLens_;
        emit NewControllerLens(oldControllerLens, address(controllerLens));

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Accrue UCORE to the market by updating the supply index
     * @param vToken The market whose supply index to update
     */
    function updateUcoreSupplyIndex(address vToken) internal {
        UcoreMarketState storage supplyState = ucoreSupplyState[vToken];
        uint supplySpeed = ucoreSupplySpeeds[vToken];
        uint32 blockNumber = safe32(getBlockNumber(), "block number exceeds 32 bits");
        uint deltaBlocks = sub_(uint(blockNumber), uint(supplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint supplyTokens = VToken(vToken).totalSupply();
            uint ucoreAccrued = mul_(deltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens > 0 ? fraction(ucoreAccrued, supplyTokens) : Double({ mantissa: 0 });
            supplyState.index = safe224(
                add_(Double({ mantissa: supplyState.index }), ratio).mantissa,
                "new index exceeds 224 bits"
            );
            supplyState.block = blockNumber;
        } else if (deltaBlocks > 0) {
            supplyState.block = blockNumber;
        }
    }

    /**
     * @notice Accrue UCORE to the market by updating the borrow index
     * @param vToken The market whose borrow index to update
     */
    function updateUcoreBorrowIndex(address vToken, Exp memory marketBorrowIndex) internal {
        UcoreMarketState storage borrowState = ucoreBorrowState[vToken];
        uint borrowSpeed = ucoreBorrowSpeeds[vToken];
        uint32 blockNumber = safe32(getBlockNumber(), "block number exceeds 32 bits");
        uint deltaBlocks = sub_(uint(blockNumber), uint(borrowState.block));
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint borrowAmount = div_(VToken(vToken).totalBorrows(), marketBorrowIndex);
            uint ucoreAccrued = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0 ? fraction(ucoreAccrued, borrowAmount) : Double({ mantissa: 0 });
            borrowState.index = safe224(
                add_(Double({ mantissa: borrowState.index }), ratio).mantissa,
                "new index exceeds 224 bits"
            );
            borrowState.block = blockNumber;
        } else if (deltaBlocks > 0) {
            borrowState.block = blockNumber;
        }
    }

    /**
     * @notice Calculate UCORE accrued by a supplier and possibly transfer it to them
     * @param vToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute UCORE to
     */
    function distributeSupplierUcore(address vToken, address supplier) internal {
        if (address(uaiVaultAddress) != address(0)) {
            releaseToVault();
        }

        uint supplyIndex = ucoreSupplyState[vToken].index;
        uint supplierIndex = ucoreSupplierIndex[vToken][supplier];

        // Update supplier's index to the current index since we are distributing accrued UCORE
        ucoreSupplierIndex[vToken][supplier] = supplyIndex;

        if (supplierIndex == 0 && supplyIndex >= ucoreInitialIndex) {
            // Covers the case where users supplied tokens before the market's supply state index was set.
            // Rewards the user with UCORE accrued from the start of when supplier rewards were first
            // set for the market.
            supplierIndex = ucoreInitialIndex;
        }

        // Calculate change in the cumulative sum of the UCORE per vToken accrued
        Double memory deltaIndex = Double({ mantissa: sub_(supplyIndex, supplierIndex) });

        // Multiply of supplierTokens and supplierDelta
        uint supplierDelta = mul_(VToken(vToken).balanceOf(supplier), deltaIndex);

        // Addition of supplierAccrued and supplierDelta
        ucoreAccrued[supplier] = add_(ucoreAccrued[supplier], supplierDelta);

        emit DistributedSupplierUcore(VToken(vToken), supplier, supplierDelta, supplyIndex);
    }

    /**
     * @notice Calculate UCORE accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param vToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute UCORE to
     */
    function distributeBorrowerUcore(address vToken, address borrower, Exp memory marketBorrowIndex) internal {
        if (address(uaiVaultAddress) != address(0)) {
            releaseToVault();
        }

        uint borrowIndex = ucoreBorrowState[vToken].index;
        uint borrowerIndex = ucoreBorrowerIndex[vToken][borrower];

        // Update borrowers's index to the current index since we are distributing accrued UCORE
        ucoreBorrowerIndex[vToken][borrower] = borrowIndex;

        if (borrowerIndex == 0 && borrowIndex >= ucoreInitialIndex) {
            // Covers the case where users borrowed tokens before the market's borrow state index was set.
            // Rewards the user with UCORE accrued from the start of when borrower rewards were first
            // set for the market.
            borrowerIndex = ucoreInitialIndex;
        }

        // Calculate change in the cumulative sum of the UCORE per borrowed unit accrued
        Double memory deltaIndex = Double({ mantissa: sub_(borrowIndex, borrowerIndex) });

        uint borrowerDelta = mul_(div_(VToken(vToken).borrowBalanceStored(borrower), marketBorrowIndex), deltaIndex);

        ucoreAccrued[borrower] = add_(ucoreAccrued[borrower], borrowerDelta);

        emit DistributedBorrowerUcore(VToken(vToken), borrower, borrowerDelta, borrowIndex);
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
        claimUcore(holders, vTokens, borrowers, suppliers, false);
    }

    /**
     * @notice Claim all ucore accrued by the holders
     * @param holders The addresses to claim UCORE for
     * @param vTokens The list of markets to claim UCORE in
     * @param borrowers Whether or not to claim UCORE earned by borrowing
     * @param suppliers Whether or not to claim UCORE earned by supplying
     * @param collateral Whether or not to use UCORE earned as collateral, only takes effect when the holder has a shortfall
     */
    function claimUcore(
        address[] memory holders,
        VToken[] memory vTokens,
        bool borrowers,
        bool suppliers,
        bool collateral
    ) public {
        uint j;
        uint256 holdersLength = holders.length;
        for (uint i; i < vTokens.length; ++i) {
            VToken vToken = vTokens[i];
            ensureListed(markets[address(vToken)]);
            if (borrowers) {
                Exp memory borrowIndex = Exp({ mantissa: vToken.borrowIndex() });
                updateUcoreBorrowIndex(address(vToken), borrowIndex);
                for (j = 0; j < holdersLength; ++j) {
                    distributeBorrowerUcore(address(vToken), holders[j], borrowIndex);
                }
            }
            if (suppliers) {
                updateUcoreSupplyIndex(address(vToken));
                for (j = 0; j < holdersLength; ++j) {
                    distributeSupplierUcore(address(vToken), holders[j]);
                }
            }
        }

        for (j = 0; j < holdersLength; ++j) {
            address holder = holders[j];
            // If there is a positive shortfall, the UCORE reward is accrued,
            // but won't be granted to this holder
            (, , uint shortfall) = getHypotheticalAccountLiquidityInternal(holder, VToken(0), 0, 0);
            ucoreAccrued[holder] = grantUCOREInternal(holder, ucoreAccrued[holder], shortfall, collateral);
        }
    }

    /**
     * @notice Claim all the ucore accrued by holder in all markets, a shorthand for `claimUcore` with collateral set to `true`
     * @param holder The address to claim UCORE for
     */
    function claimUcoreAsCollateral(address holder) external {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claimUcore(holders, allMarkets, true, true, true);
    }

    /**
     * @notice Transfer UCORE to the user with user's shortfall considered
     * @dev Note: If there is not enough UCORE, we do not perform the transfer all.
     * @param user The address of the user to transfer UCORE to
     * @param amount The amount of UCORE to (possibly) transfer
     * @param shortfall The shortfall of the user
     * @param collateral Whether or not we will use user's ucore reward as collateral to pay off the debt
     * @return The amount of UCORE which was NOT transferred to the user
     */
    function grantUCOREInternal(address user, uint amount, uint shortfall, bool collateral) internal returns (uint) {
        // If the user is blacklisted, they can't get UCORE rewards
        require(
            user != 0xEF044206Db68E40520BfA82D45419d498b4bc7Bf &&
                user != 0x7589dD3355DAE848FDbF75044A3495351655cB1A &&
                user != 0x33df7a7F6D44307E1e5F3B15975b47515e5524c0 &&
                user != 0x24e77E5b74B30b026E9996e4bc3329c881e24968,
            "Blacklisted"
        );

        UCORE ucore = UCORE(getUCOREAddress());

        if (amount == 0 || amount > ucore.balanceOf(address(this))) {
            return amount;
        }

        if (shortfall == 0) {
            ucore.transfer(user, amount);
            return 0;
        }
        // If user's bankrupt and doesn't use pending ucore as collateral, don't grant
        // anything, otherwise, we will transfer the pending ucore as collateral to
        // vUCORE token and mint vUCORE for the user.
        //
        // If mintBehalf failed, don't grant any ucore
        require(collateral, "bankrupt accounts can only collateralize their pending ucore rewards");

        ucore.approve(getUCOREVTokenAddress(), amount);
        require(
            VBep20Interface(getUCOREVTokenAddress()).mintBehalf(user, amount) == uint(Error.NO_ERROR),
            "mint behalf error during collateralize ucore"
        );

        // set ucoreAccrue[user] to 0
        return 0;
    }

    /*** Ucore Distribution Admin ***/

    /**
     * @notice Transfer UCORE to the recipient
     * @dev Note: If there is not enough UCORE, we do not perform the transfer all.
     * @param recipient The address of the recipient to transfer UCORE to
     * @param amount The amount of UCORE to (possibly) transfer
     */
    function _grantUCORE(address recipient, uint amount) external {
        ensureAdminOr(controllerImplementation);
        uint amountLeft = grantUCOREInternal(recipient, amount, 0, false);
        require(amountLeft == 0, "insufficient ucore for grant");
        emit UcoreGranted(recipient, amount);
    }

    /**
     * @notice Set the amount of UCORE distributed per block to UAI Vault
     * @param ucoreUAIVaultRate_ The amount of UCORE wei per block to distribute to UAI Vault
     */
    function _setUcoreUAIVaultRate(uint ucoreUAIVaultRate_) external {
        ensureAdmin();

        uint oldUcoreUAIVaultRate = ucoreUAIVaultRate;
        ucoreUAIVaultRate = ucoreUAIVaultRate_;
        emit NewUcoreUAIVaultRate(oldUcoreUAIVaultRate, ucoreUAIVaultRate_);
    }

    /**
     * @notice Set the UAI Vault infos
     * @param vault_ The address of the UAI Vault
     * @param releaseStartBlock_ The start block of release to UAI Vault
     * @param minReleaseAmount_ The minimum release amount to UAI Vault
     */
    function _setUAIVaultInfo(address vault_, uint256 releaseStartBlock_, uint256 minReleaseAmount_) external {
        ensureAdmin();
        ensureNonzeroAddress(vault_);

        uaiVaultAddress = vault_;
        releaseStartBlock = releaseStartBlock_;
        minReleaseAmount = minReleaseAmount_;
        emit NewUAIVaultInfo(vault_, releaseStartBlock_, minReleaseAmount_);
    }

    /**
     * @notice Set UCORE speed for a single market
     * @param vTokens The market whose UCORE speed to update
     * @param supplySpeeds New UCORE speed for supply
     * @param borrowSpeeds New UCORE speed for borrow
     */
    function _setUcoreSpeeds(
        VToken[] calldata vTokens,
        uint[] calldata supplySpeeds,
        uint[] calldata borrowSpeeds
    ) external {
        ensureAdminOr(controllerImplementation);

        uint numTokens = vTokens.length;
        require(
            numTokens == supplySpeeds.length && numTokens == borrowSpeeds.length,
            "Controller::_setUcoreSpeeds invalid input"
        );

        for (uint i; i < numTokens; ++i) {
            ensureNonzeroAddress(address(vTokens[i]));
            setUcoreSpeedInternal(vTokens[i], supplySpeeds[i], borrowSpeeds[i]);
        }
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() external view returns (VToken[] memory) {
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

    /**
     * @notice Return the address of the UCORE vToken
     * @return The address of UCORE vToken
     */
    function getUCOREVTokenAddress() public view returns (address) {
        return 0x151B1e2635A717bcDc836ECd6FbB62B674FE3E1D;
    }

    /**
     * @notice Checks if a certain action is paused on a market
     * @param action Action id
     * @param market vToken address
     */
    function actionPaused(address market, Action action) public view returns (bool) {
        return _actionPaused[market][uint(action)];
    }

    /*** UAI functions ***/

    /**
     * @notice Set the minted UAI amount of the `owner`
     * @param owner The address of the account to set
     * @param amount The amount of UAI to set to the account
     * @return The number of minted UAI by `owner`
     */
    function setMintedUAIOf(address owner, uint amount) external returns (uint) {
        checkProtocolPauseState();

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
     * @notice Transfer UCORE to UAI Vault
     */
    function releaseToVault() public {
        if (releaseStartBlock == 0 || getBlockNumber() < releaseStartBlock) {
            return;
        }

        UCORE ucore = UCORE(getUCOREAddress());

        uint256 ucoreBalance = ucore.balanceOf(address(this));
        if (ucoreBalance == 0) {
            return;
        }

        uint256 actualAmount;
        uint256 deltaBlocks = sub_(getBlockNumber(), releaseStartBlock);
        // releaseAmount = ucoreUAIVaultRate * deltaBlocks
        uint256 _releaseAmount = mul_(ucoreUAIVaultRate, deltaBlocks);

        if (ucoreBalance >= _releaseAmount) {
            actualAmount = _releaseAmount;
        } else {
            actualAmount = ucoreBalance;
        }

        if (actualAmount < minReleaseAmount) {
            return;
        }

        releaseStartBlock = getBlockNumber();

        ucore.transfer(uaiVaultAddress, actualAmount);
        emit DistributedUAIVaultUcore(actualAmount);

        IUAIVault(uaiVaultAddress).updatePendingRewards();
    }
}

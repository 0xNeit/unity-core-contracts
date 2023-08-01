pragma solidity ^0.5.16;

import "../Controller/Controller.sol";
import "../Oracle/PriceOracle.sol";

contract ControllerKovan is Controller {
    function getUCOREAddress() public view returns (address) {
        return 0x61460874a7196d6a22D1eE4922473664b3E95270;
    }
}

contract ControllerRopsten is Controller {
    function getUCOREAddress() public view returns (address) {
        return 0x1Fe16De955718CFAb7A44605458AB023838C2793;
    }
}

contract ControllerHarness is Controller {
    address internal ucoreAddress;
    address internal vUCOREAddress;
    uint public blockNumber;

    constructor() public Controller() {}

    function setUcoreSupplyState(address vToken, uint224 index, uint32 blockNumber_) public {
        ucoreSupplyState[vToken].index = index;
        ucoreSupplyState[vToken].block = blockNumber_;
    }

    function setUcoreBorrowState(address vToken, uint224 index, uint32 blockNumber_) public {
        ucoreBorrowState[vToken].index = index;
        ucoreBorrowState[vToken].block = blockNumber_;
    }

    function setUcoreAccrued(address user, uint userAccrued) public {
        ucoreAccrued[user] = userAccrued;
    }

    function setUCOREAddress(address ucoreAddress_) public {
        ucoreAddress = ucoreAddress_;
    }

    function getUCOREAddress() public view returns (address) {
        return ucoreAddress;
    }

    function setUCOREVTokenAddress(address vUCOREAddress_) public {
        vUCOREAddress = vUCOREAddress_;
    }

    function getUCOREVTokenAddress() public view returns (address) {
        return vUCOREAddress;
    }

    /**
     * @notice Set the amount of UCORE distributed per block
     * @param ucoreRate_ The amount of UCORE wei per block to distribute
     */
    function harnessSetUcoreRate(uint ucoreRate_) public {
        ucoreRate = ucoreRate_;
    }

    /**
     * @notice Recalculate and update UCORE speeds for all UCORE markets
     */
    function harnessRefreshUcoreSpeeds() public {
        VToken[] memory allMarkets_ = allMarkets;

        for (uint i = 0; i < allMarkets_.length; i++) {
            VToken vToken = allMarkets_[i];
            Exp memory borrowIndex = Exp({ mantissa: vToken.borrowIndex() });
            updateUcoreSupplyIndex(address(vToken));
            updateUcoreBorrowIndex(address(vToken), borrowIndex);
        }

        Exp memory totalUtility = Exp({ mantissa: 0 });
        Exp[] memory utilities = new Exp[](allMarkets_.length);
        for (uint i = 0; i < allMarkets_.length; i++) {
            VToken vToken = allMarkets_[i];
            if (ucoreSpeeds[address(vToken)] > 0) {
                Exp memory assetPrice = Exp({ mantissa: oracle.getUnderlyingPrice(vToken) });
                Exp memory utility = mul_(assetPrice, vToken.totalBorrows());
                utilities[i] = utility;
                totalUtility = add_(totalUtility, utility);
            }
        }

        for (uint i = 0; i < allMarkets_.length; i++) {
            VToken vToken = allMarkets[i];
            uint newSpeed = totalUtility.mantissa > 0 ? mul_(ucoreRate, div_(utilities[i], totalUtility)) : 0;
            setUcoreSpeedInternal(vToken, newSpeed, newSpeed);
        }
    }

    function setUcoreBorrowerIndex(address vToken, address borrower, uint index) public {
        ucoreBorrowerIndex[vToken][borrower] = index;
    }

    function setUcoreSupplierIndex(address vToken, address supplier, uint index) public {
        ucoreSupplierIndex[vToken][supplier] = index;
    }

    function harnessDistributeAllBorrowerUcore(
        address vToken,
        address borrower,
        uint marketBorrowIndexMantissa
    ) public {
        distributeBorrowerUcore(vToken, borrower, Exp({ mantissa: marketBorrowIndexMantissa }));
        ucoreAccrued[borrower] = grantUCOREInternal(borrower, ucoreAccrued[borrower], 0, false);
    }

    function harnessDistributeAllSupplierUcore(address vToken, address supplier) public {
        distributeSupplierUcore(vToken, supplier);
        ucoreAccrued[supplier] = grantUCOREInternal(supplier, ucoreAccrued[supplier], 0, false);
    }

    function harnessUpdateUcoreBorrowIndex(address vToken, uint marketBorrowIndexMantissa) public {
        updateUcoreBorrowIndex(vToken, Exp({ mantissa: marketBorrowIndexMantissa }));
    }

    function harnessUpdateUcoreSupplyIndex(address vToken) public {
        updateUcoreSupplyIndex(vToken);
    }

    function harnessDistributeBorrowerUcore(address vToken, address borrower, uint marketBorrowIndexMantissa) public {
        distributeBorrowerUcore(vToken, borrower, Exp({ mantissa: marketBorrowIndexMantissa }));
    }

    function harnessDistributeSupplierUcore(address vToken, address supplier) public {
        distributeSupplierUcore(vToken, supplier);
    }

    function harnessTransferUcore(address user, uint userAccrued, uint threshold) public returns (uint) {
        if (userAccrued > 0 && userAccrued >= threshold) {
            return grantUCOREInternal(user, userAccrued, 0, false);
        }
        return userAccrued;
    }

    function harnessAddUcoreMarkets(address[] memory vTokens) public {
        for (uint i = 0; i < vTokens.length; i++) {
            // temporarily set ucoreSpeed to 1 (will be fixed by `harnessRefreshUcoreSpeeds`)
            setUcoreSpeedInternal(VToken(vTokens[i]), 1, 1);
        }
    }

    function harnessSetMintedUAIs(address user, uint amount) public {
        mintedUAIs[user] = amount;
    }

    function harnessFastForward(uint blocks) public returns (uint) {
        blockNumber += blocks;
        return blockNumber;
    }

    function setBlockNumber(uint number) public {
        blockNumber = number;
    }

    function getBlockNumber() public view returns (uint) {
        return blockNumber;
    }

    function getUcoreMarkets() public view returns (address[] memory) {
        uint m = allMarkets.length;
        uint n = 0;
        for (uint i = 0; i < m; i++) {
            if (ucoreSpeeds[address(allMarkets[i])] > 0) {
                n++;
            }
        }

        address[] memory ucoreMarkets = new address[](n);
        uint k = 0;
        for (uint i = 0; i < m; i++) {
            if (ucoreSpeeds[address(allMarkets[i])] > 0) {
                ucoreMarkets[k++] = address(allMarkets[i]);
            }
        }
        return ucoreMarkets;
    }

    function harnessSetReleaseStartBlock(uint startBlock) external {
        releaseStartBlock = startBlock;
    }

    function harnessAddVtoken(address vToken) external {
        markets[vToken] = Market({ isListed: true, isUcore: false, collateralFactorMantissa: 0 });
    }
}

contract ControllerBorked {
    function _become(Unitroller unitroller) public {
        require(msg.sender == unitroller.admin(), "only unitroller admin can change brains");
        unitroller._acceptImplementation();
    }
}

contract BoolController is ControllerInterface {
    bool internal allowMint = true;
    bool internal allowRedeem = true;
    bool internal allowBorrow = true;
    bool internal allowRepayBorrow = true;
    bool internal allowLiquidateBorrow = true;
    bool internal allowSeize = true;
    bool internal allowTransfer = true;

    bool internal verifyMint = true;
    bool internal verifyRedeem = true;
    bool internal verifyBorrow = true;
    bool internal verifyRepayBorrow = true;
    bool internal verifyLiquidateBorrow = true;
    bool internal verifySeize = true;
    bool internal verifyTransfer = true;
    uint public liquidationIncentiveMantissa = 11e17;
    bool internal failCalculateSeizeTokens;
    uint internal calculatedSeizeTokens;

    bool public protocolPaused = false;

    mapping(address => uint) public mintedUAIs;
    bool internal uaiFailCalculateSeizeTokens;
    uint internal uaiCalculatedSeizeTokens;

    uint internal noError = 0;
    uint internal opaqueError = noError + 11; // an arbitrary, opaque error code

    address public treasuryGuardian;
    address public treasuryAddress;
    uint public treasuryPercent;
    address public liquidatorContract;

    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata _vTokens) external returns (uint[] memory) {
        _vTokens;
        uint[] memory ret;
        return ret;
    }

    function exitMarket(address _vToken) external returns (uint) {
        _vToken;
        return noError;
    }

    /*** Policy Hooks ***/

    function mintAllowed(address _vToken, address _minter, uint _mintAmount) external returns (uint) {
        _vToken;
        _minter;
        _mintAmount;
        return allowMint ? noError : opaqueError;
    }

    function mintVerify(address _vToken, address _minter, uint _mintAmount, uint _mintTokens) external {
        _vToken;
        _minter;
        _mintAmount;
        _mintTokens;
        require(verifyMint, "mintVerify rejected mint");
    }

    function redeemAllowed(address _vToken, address _redeemer, uint _redeemTokens) external returns (uint) {
        _vToken;
        _redeemer;
        _redeemTokens;
        return allowRedeem ? noError : opaqueError;
    }

    function redeemVerify(address _vToken, address _redeemer, uint _redeemAmount, uint _redeemTokens) external {
        _vToken;
        _redeemer;
        _redeemAmount;
        _redeemTokens;
        require(verifyRedeem, "redeemVerify rejected redeem");
    }

    function borrowAllowed(address _vToken, address _borrower, uint _borrowAmount) external returns (uint) {
        _vToken;
        _borrower;
        _borrowAmount;
        return allowBorrow ? noError : opaqueError;
    }

    function borrowVerify(address _vToken, address _borrower, uint _borrowAmount) external {
        _vToken;
        _borrower;
        _borrowAmount;
        require(verifyBorrow, "borrowVerify rejected borrow");
    }

    function repayBorrowAllowed(
        address _vToken,
        address _payer,
        address _borrower,
        uint _repayAmount
    ) external returns (uint) {
        _vToken;
        _payer;
        _borrower;
        _repayAmount;
        return allowRepayBorrow ? noError : opaqueError;
    }

    function repayBorrowVerify(
        address _vToken,
        address _payer,
        address _borrower,
        uint _repayAmount,
        uint _borrowerIndex
    ) external {
        _vToken;
        _payer;
        _borrower;
        _repayAmount;
        _borrowerIndex;
        require(verifyRepayBorrow, "repayBorrowVerify rejected repayBorrow");
    }

    function _setLiquidatorContract(address liquidatorContract_) external {
        liquidatorContract = liquidatorContract_;
    }

    function liquidateBorrowAllowed(
        address _vTokenBorrowed,
        address _vTokenCollateral,
        address _liquidator,
        address _borrower,
        uint _repayAmount
    ) external returns (uint) {
        _vTokenBorrowed;
        _vTokenCollateral;
        _borrower;
        _repayAmount;
        if (liquidatorContract != address(0) && liquidatorContract != _liquidator) {
            return opaqueError;
        }
        return allowLiquidateBorrow ? noError : opaqueError;
    }

    function liquidateBorrowVerify(
        address _vTokenBorrowed,
        address _vTokenCollateral,
        address _liquidator,
        address _borrower,
        uint _repayAmount,
        uint _seizeTokens
    ) external {
        _vTokenBorrowed;
        _vTokenCollateral;
        _liquidator;
        _borrower;
        _repayAmount;
        _seizeTokens;
        require(verifyLiquidateBorrow, "liquidateBorrowVerify rejected liquidateBorrow");
    }

    function seizeAllowed(
        address _vTokenCollateral,
        address _vTokenBorrowed,
        address _borrower,
        address _liquidator,
        uint _seizeTokens
    ) external returns (uint) {
        _vTokenCollateral;
        _vTokenBorrowed;
        _liquidator;
        _borrower;
        _seizeTokens;
        return allowSeize ? noError : opaqueError;
    }

    function seizeVerify(
        address _vTokenCollateral,
        address _vTokenBorrowed,
        address _liquidator,
        address _borrower,
        uint _seizeTokens
    ) external {
        _vTokenCollateral;
        _vTokenBorrowed;
        _liquidator;
        _borrower;
        _seizeTokens;
        require(verifySeize, "seizeVerify rejected seize");
    }

    function transferAllowed(
        address _vToken,
        address _src,
        address _dst,
        uint _transferTokens
    ) external returns (uint) {
        _vToken;
        _src;
        _dst;
        _transferTokens;
        return allowTransfer ? noError : opaqueError;
    }

    function transferVerify(address _vToken, address _src, address _dst, uint _transferTokens) external {
        _vToken;
        _src;
        _dst;
        _transferTokens;
        require(verifyTransfer, "transferVerify rejected transfer");
    }

    /*** Special Liquidation Calculation ***/

    function liquidateCalculateSeizeTokens(
        address _vTokenBorrowed,
        address _vTokenCollateral,
        uint _repayAmount
    ) external view returns (uint, uint) {
        _vTokenBorrowed;
        _vTokenCollateral;
        _repayAmount;
        return failCalculateSeizeTokens ? (opaqueError, 0) : (noError, calculatedSeizeTokens);
    }

    /*** Special Liquidation Calculation ***/

    function liquidateUAICalculateSeizeTokens(
        address _vTokenCollateral,
        uint _repayAmount
    ) external view returns (uint, uint) {
        _vTokenCollateral;
        _repayAmount;
        return uaiFailCalculateSeizeTokens ? (opaqueError, 0) : (noError, uaiCalculatedSeizeTokens);
    }

    /**** Mock Settors ****/

    /*** Policy Hooks ***/

    function setMintAllowed(bool allowMint_) public {
        allowMint = allowMint_;
    }

    function setMintVerify(bool verifyMint_) public {
        verifyMint = verifyMint_;
    }

    function setRedeemAllowed(bool allowRedeem_) public {
        allowRedeem = allowRedeem_;
    }

    function setRedeemVerify(bool verifyRedeem_) public {
        verifyRedeem = verifyRedeem_;
    }

    function setBorrowAllowed(bool allowBorrow_) public {
        allowBorrow = allowBorrow_;
    }

    function setBorrowVerify(bool verifyBorrow_) public {
        verifyBorrow = verifyBorrow_;
    }

    function setRepayBorrowAllowed(bool allowRepayBorrow_) public {
        allowRepayBorrow = allowRepayBorrow_;
    }

    function setRepayBorrowVerify(bool verifyRepayBorrow_) public {
        verifyRepayBorrow = verifyRepayBorrow_;
    }

    function setLiquidateBorrowAllowed(bool allowLiquidateBorrow_) public {
        allowLiquidateBorrow = allowLiquidateBorrow_;
    }

    function setLiquidateBorrowVerify(bool verifyLiquidateBorrow_) public {
        verifyLiquidateBorrow = verifyLiquidateBorrow_;
    }

    function setSeizeAllowed(bool allowSeize_) public {
        allowSeize = allowSeize_;
    }

    function setSeizeVerify(bool verifySeize_) public {
        verifySeize = verifySeize_;
    }

    function setTransferAllowed(bool allowTransfer_) public {
        allowTransfer = allowTransfer_;
    }

    function setTransferVerify(bool verifyTransfer_) public {
        verifyTransfer = verifyTransfer_;
    }

    /*** Liquidity/Liquidation Calculations ***/
    function setAnnouncedLiquidationIncentiveMantissa(uint mantissa_) external {
        liquidationIncentiveMantissa = mantissa_;
    }

    /*** Liquidity/Liquidation Calculations ***/

    function setCalculatedSeizeTokens(uint seizeTokens_) public {
        calculatedSeizeTokens = seizeTokens_;
    }

    function setFailCalculateSeizeTokens(bool shouldFail) public {
        failCalculateSeizeTokens = shouldFail;
    }

    function setUAICalculatedSeizeTokens(uint uaiSeizeTokens_) public {
        uaiCalculatedSeizeTokens = uaiSeizeTokens_;
    }

    function setUAIFailCalculateSeizeTokens(bool uaiShouldFail) public {
        uaiFailCalculateSeizeTokens = uaiShouldFail;
    }

    function harnessSetMintedUAIOf(address owner, uint amount) external returns (uint) {
        mintedUAIs[owner] = amount;
        return noError;
    }

    // function mintedUAIs(address owner) external pure returns (uint) {
    //     owner;
    //     return 1e18;
    // }

    function setMintedUAIOf(address owner, uint amount) external returns (uint) {
        owner;
        amount;
        return noError;
    }

    function uaiMintRate() external pure returns (uint) {
        return 1e18;
    }

    function setTreasuryData(address treasuryGuardian_, address treasuryAddress_, uint treasuryPercent_) external {
        treasuryGuardian = treasuryGuardian_;
        treasuryAddress = treasuryAddress_;
        treasuryPercent = treasuryPercent_;
    }

    function _setMarketSupplyCaps(VToken[] calldata vTokens, uint[] calldata newSupplyCaps) external {}

    /*** Functions from ControllerInterface not implemented by BoolController ***/

    function markets(address) external view returns (bool, uint) {
        revert();
    }

    function oracle() external view returns (PriceOracle) {
        revert();
    }

    function getAccountLiquidity(address) external view returns (uint, uint, uint) {
        revert();
    }

    function getAssetsIn(address) external view returns (VToken[] memory) {
        revert();
    }

    function claimUcore(address) external {
        revert();
    }

    function ucoreAccrued(address) external view returns (uint) {
        revert();
    }

    function ucoreSpeeds(address) external view returns (uint) {
        revert();
    }

    function getAllMarkets() external view returns (VToken[] memory) {
        revert();
    }

    function ucoreSupplierIndex(address, address) external view returns (uint) {
        revert();
    }

    function ucoreInitialIndex() external view returns (uint224) {
        revert();
    }

    function ucoreBorrowerIndex(address, address) external view returns (uint) {
        revert();
    }

    function ucoreBorrowState(address) external view returns (uint224, uint32) {
        revert();
    }

    function ucoreSupplyState(address) external view returns (uint224, uint32) {
        revert();
    }
}

contract EchoTypesController is UnitrollerAdminStorage {
    function stringy(string memory s) public pure returns (string memory) {
        return s;
    }

    function addresses(address a) public pure returns (address) {
        return a;
    }

    function booly(bool b) public pure returns (bool) {
        return b;
    }

    function listOInts(uint[] memory u) public pure returns (uint[] memory) {
        return u;
    }

    function reverty() public pure {
        require(false, "gotcha sucka");
    }

    function becomeBrains(address payable unitroller) public {
        Unitroller(unitroller)._acceptImplementation();
    }
}

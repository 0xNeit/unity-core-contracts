pragma solidity ^0.5.16;

import "../Tokens/VTokens/VToken.sol";
import "../Oracle/PriceOracle.sol";
import "../Tokens/UAI/UAIControllerInterface.sol";
import "./ControllerLensInterface.sol";

contract UnitrollerAdminStorage {
    /**
     * @notice Administrator for this contract
     */
    address public admin;

    /**
     * @notice Pending administrator for this contract
     */
    address public pendingAdmin;

    /**
     * @notice Active brains of Unitroller
     */
    address public controllerImplementation;

    /**
     * @notice Pending brains of Unitroller
     */
    address public pendingControllerImplementation;
}

contract ControllerV1Storage is UnitrollerAdminStorage {
    /**
     * @notice Oracle which gives the price of any given asset
     */
    PriceOracle public oracle;

    /**
     * @notice Multiplier used to calculate the maximum repayAmount when liquidating a borrow
     */
    uint public closeFactorMantissa;

    /**
     * @notice Multiplier representing the discount on collateral that a liquidator receives
     */
    uint public liquidationIncentiveMantissa;

    /**
     * @notice Max number of assets a single account can participate in (borrow or use as collateral)
     */
    uint public maxAssets;

    /**
     * @notice Per-account mapping of "assets you are in", capped by maxAssets
     */
    mapping(address => VToken[]) public accountAssets;

    struct Market {
        /// @notice Whether or not this market is listed
        bool isListed;
        /**
         * @notice Multiplier representing the most one can borrow against their collateral in this market.
         *  For instance, 0.9 to allow borrowing 90% of collateral value.
         *  Must be between 0 and 1, and stored as a mantissa.
         */
        uint collateralFactorMantissa;
        /// @notice Per-market mapping of "accounts in this asset"
        mapping(address => bool) accountMembership;
        /// @notice Whether or not this market receives UCORE
        bool isUcore;
    }

    /**
     * @notice Official mapping of vTokens -> Market metadata
     * @dev Used e.g. to determine if a market is supported
     */
    mapping(address => Market) public markets;

    /**
     * @notice The Pause Guardian can pause certain actions as a safety mechanism.
     */
    address public pauseGuardian;

    /// @notice Whether minting is paused (deprecated, superseded by actionPaused)
    bool private _mintGuardianPaused;
    /// @notice Whether borrowing is paused (deprecated, superseded by actionPaused)
    bool private _borrowGuardianPaused;
    /// @notice Whether borrowing is paused (deprecated, superseded by actionPaused)
    bool internal transferGuardianPaused;
    /// @notice Whether borrowing is paused (deprecated, superseded by actionPaused)
    bool internal seizeGuardianPaused;
    /// @notice Whether borrowing is paused (deprecated, superseded by actionPaused)
    mapping(address => bool) internal mintGuardianPaused;
    /// @notice Whether borrowing is paused (deprecated, superseded by actionPaused)
    mapping(address => bool) internal borrowGuardianPaused;

    struct UcoreMarketState {
        /// @notice The market's last updated ucoreBorrowIndex or ucoreSupplyIndex
        uint224 index;
        /// @notice The block number the index was last updated at
        uint32 block;
    }

    /// @notice A list of all markets
    VToken[] public allMarkets;

    /// @notice The rate at which the flywheel distributes UCORE, per block
    uint public ucoreRate;

    /// @notice The portion of ucoreRate that each market currently receives
    mapping(address => uint) public ucoreSpeeds;

    /// @notice The Ucore market supply state for each market
    mapping(address => UcoreMarketState) public ucoreSupplyState;

    /// @notice The Ucore market borrow state for each market
    mapping(address => UcoreMarketState) public ucoreBorrowState;

    /// @notice The Ucore supply index for each market for each supplier as of the last time they accrued UCORE
    mapping(address => mapping(address => uint)) public ucoreSupplierIndex;

    /// @notice The Ucore borrow index for each market for each borrower as of the last time they accrued UCORE
    mapping(address => mapping(address => uint)) public ucoreBorrowerIndex;

    /// @notice The UCORE accrued but not yet transferred to each user
    mapping(address => uint) public ucoreAccrued;

    /// @notice The Address of UAIController
    UAIControllerInterface public uaiController;

    /// @notice The minted UAI amount to each user
    mapping(address => uint) public mintedUAIs;

    /// @notice UAI Mint Rate as a percentage
    uint public uaiMintRate;

    /**
     * @notice The Pause Guardian can pause certain actions as a safety mechanism.
     */
    bool public mintUAIGuardianPaused;
    bool public repayUAIGuardianPaused;

    /**
     * @notice Pause/Unpause whole protocol actions
     */
    bool public protocolPaused;

    /// @notice The rate at which the flywheel distributes UCORE to UAI Minters, per block (deprecated)
    uint private ucoreUAIRate;
}

contract ControllerV2Storage is ControllerV1Storage {
    /// @notice The rate at which the flywheel distributes UCORE to UAI Vault, per block
    uint public ucoreUAIVaultRate;

    // address of UAI Vault
    address public uaiVaultAddress;

    // start block of release to UAI Vault
    uint256 public releaseStartBlock;

    // minimum release amount to UAI Vault
    uint256 public minReleaseAmount;
}

contract ControllerV3Storage is ControllerV2Storage {
    /// @notice The borrowCapGuardian can set borrowCaps to any number for any market. Lowering the borrow cap could disable borrowing on the given market.
    address public borrowCapGuardian;

    /// @notice Borrow caps enforced by borrowAllowed for each vToken address. Defaults to zero which corresponds to unlimited borrowing.
    mapping(address => uint) public borrowCaps;
}

contract ControllerV4Storage is ControllerV3Storage {
    /// @notice Treasury Guardian address
    address public treasuryGuardian;

    /// @notice Treasury address
    address public treasuryAddress;

    /// @notice Fee percent of accrued interest with decimal 18
    uint256 public treasuryPercent;
}

contract ControllerV5Storage is ControllerV4Storage {
    /// @notice The portion of UCORE that each contributor receives per block (deprecated)
    mapping(address => uint) private ucoreContributorSpeeds;

    /// @notice Last block at which a contributor's UCORE rewards have been allocated (deprecated)
    mapping(address => uint) private lastContributorBlock;
}

contract ControllerV6Storage is ControllerV5Storage {
    address public liquidatorContract;
}

contract ControllerV7Storage is ControllerV6Storage {
    ControllerLensInterface public controllerLens;
}

contract ControllerV8Storage is ControllerV7Storage {
    /// @notice Supply caps enforced by mintAllowed for each vToken address. Defaults to zero which corresponds to minting notAllowed
    mapping(address => uint256) public supplyCaps;
}

contract ControllerV9Storage is ControllerV8Storage {
    /// @notice AccessControlManager address
    address internal accessControl;

    enum Action {
        MINT,
        REDEEM,
        BORROW,
        REPAY,
        SEIZE,
        LIQUIDATE,
        TRANSFER,
        ENTER_MARKET,
        EXIT_MARKET
    }

    /// @notice True if a certain action is paused on a certain market
    mapping(address => mapping(uint => bool)) internal _actionPaused;
}

contract ControllerV10Storage is ControllerV9Storage {
    /// @notice The rate at which ucore is distributed to the corresponding borrow market (per block)
    mapping(address => uint) public ucoreBorrowSpeeds;

    /// @notice The rate at which ucore is distributed to the corresponding supply market (per block)
    mapping(address => uint) public ucoreSupplySpeeds;
}

contract ControllerV11Storage is ControllerV10Storage {
    /// @notice Whether the delegate is allowed to borrow on behalf of the borrower
    //mapping(address borrower => mapping (address delegate => bool approved)) public approvedDelegates;
    mapping(address => mapping(address => bool)) public approvedDelegates;
}

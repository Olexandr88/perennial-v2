// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.15;

import "@equilibria/root/control/unstructured/UInitializable.sol";
import "@equilibria/root/control/unstructured/UReentrancyGuard.sol";
import "../controller/UControllerProvider.sol";
import "./UPayoffProvider.sol";
import "./UParamProvider.sol";
import "./types/Account.sol";

// TODO: position needs less settle on the second period for both global and account
// TODO: lots of params can be passed in from global settle to account settle

/**
 * @title Product
 * @notice Manages logic and state for a single product market.
 * @dev Cloned by the Controller contract to launch new product markets.
 */
contract Product is IProduct, UInitializable, UParamProvider, UPayoffProvider, UReentrancyGuard {
    /// @dev Whether or not the product is closed
    BoolStorage private constant _closed =
        BoolStorage.wrap(keccak256("equilibria.perennial.Product.closed"));
    function closed() public view returns (bool) { return _closed.read(); }

    /// @dev The name of the product
    string public name;

    /// @dev The symbol of the product
    string public symbol;

    /// @dev The individual state for each account
    mapping(address => Account) private _accounts;

    /// @dev Mapping of the historical version data
    mapping(uint256 => Version) _versions;

    PrePosition private _pre;
    mapping(address => PrePosition) private _pres;

    uint256 private _latestVersion;
    mapping(address => uint256) private _latestVersions;

    /**
     * @notice Initializes the contract state
     * @param productInfo_ Product initialization params
     */
    function initialize(ProductInfo calldata productInfo_) external initializer(1) {
        __UControllerProvider__initialize(IController(msg.sender));
        __UPayoffProvider__initialize(productInfo_.oracle, productInfo_.payoffDefinition);
        __UReentrancyGuard__initialize();
        __UParamProvider__initialize(
            productInfo_.maintenance,
            productInfo_.fundingFee,
            productInfo_.makerFee,
            productInfo_.takerFee,
            productInfo_.positionFee,
            productInfo_.makerLimit,
            productInfo_.utilizationCurve
        );

        name = productInfo_.name;
        symbol = productInfo_.symbol;
    }

    /**
     * @notice Surfaces global settlement externally
     */
    function settle() external nonReentrant notPaused {
        _settle();
    }

    /**
     * @notice Core global settlement flywheel
     * @dev
     *  a) last settle oracle version
     *  b) latest pre position oracle version
     *  c) current oracle version
     *
     *  Settles from a->b then from b->c if either interval is non-zero to account for a change
     *  in position quantity at (b).
     *
     *  Syncs each to instantaneously after the oracle update.
     */
    function _settle() private returns (
        IOracleProvider.OracleVersion memory currentOracleVersion,
        Version memory operatingVersion
    ) {
        // Determine periods to settle
        currentOracleVersion = _sync();
        operatingVersion = _versions[_latestVersion];
        if (currentOracleVersion.version == _latestVersion) return (currentOracleVersion, operatingVersion); // zero periods if a == c

        // Sync incentivizer programs
        IController _controller = controller();
        _controller.incentivizer().sync(currentOracleVersion);

        // Load version data into memory
        IOracleProvider.OracleVersion memory latestOracleVersion = atVersion(_latestVersion);
        IOracleProvider.OracleVersion memory settleOracleVersion =
            _latestVersion + 1 == currentOracleVersion.version ?
                currentOracleVersion :
                atVersion(_latestVersion + 1);

        // Load parameters
        (, UFixed18 fundingFee, UFixed18 makerFee, UFixed18 takerFee, UFixed18 positionFee) = parameter();
        UFixed18 feeAccumulator;
        VersionLib.ProductParams memory params = VersionLib.ProductParams(utilizationCurve(), fundingFee, closed());

        // a->b (and settle)
        (operatingVersion, feeAccumulator) = operatingVersion.accumulateAndSettle(
            feeAccumulator,
            pre(),
            Period(latestOracleVersion, settleOracleVersion),
            makerFee,
            takerFee,
            positionFee,
            params
        );
        _versions[settleOracleVersion.version] = operatingVersion;

        // b->c
        if (settleOracleVersion.version != currentOracleVersion.version) { // skip is b == c
            (operatingVersion, feeAccumulator) = operatingVersion.accumulate(
                feeAccumulator,
                Period(settleOracleVersion, currentOracleVersion),
                params
            );
            _versions[currentOracleVersion.version] = operatingVersion;
        }

        // Settle collateral
        _controller.collateral().settleProduct(feeAccumulator);

        // Save state
        _latestVersion = currentOracleVersion.version;
        delete _pre;

        emit Settle(settleOracleVersion.version, currentOracleVersion.version);
    }

    /**
    * @notice Surfaces account settlement externally
     * @param account Account to settle
     */
    function settleAccount(address account) external nonReentrant notPaused {
        (
            IOracleProvider.OracleVersion memory currentOracleVersion,
            Version memory currentVersion
        ) = _settle();
        _settleAccount(account, currentOracleVersion, currentVersion);
    }

    /**
     * @notice Core account settlement flywheel
     * @notice Core account settlement flywheel
     * @param account Account to settle
     * @dev
     *  a) last settle oracle version
     *  b) latest pre position oracle version
     *  c) current oracle version
     *
     *  Settles from a->b then from b->c if either interval is non-zero to account for a change
     *  in position quantity at (b).
     *
     *  Syncs each to instantaneously after the oracle update.
     */
    function _settleAccount(
        address account,
        IOracleProvider.OracleVersion memory currentOracleVersion,
        Version memory currentVersion
    ) private {
        IController _controller = controller();

        // Get latest oracle version
        uint256 latestVersion_ = latestVersion(account);
        if (latestVersion_ == currentOracleVersion.version) return; // short circuit entirely if a == c

        // Get settle oracle version
        uint256 _settleVersion = latestVersion_ + 1;
        IOracleProvider.OracleVersion memory settleOracleVersion =
            _settleVersion == currentOracleVersion.version ?
                currentOracleVersion : // if b == c, don't re-call provider for oracle version
                atVersion(_settleVersion);
        Version memory settleVersion = _versions[_settleVersion];

        // initialize
        Fixed18 valueAccumulator;

        // sync incentivizer before accumulator
        _controller.incentivizer().syncAccount(account, settleOracleVersion);

        // account a->b
        (_accounts[account], valueAccumulator) =
            _accounts[account].accumulateAndSettle(valueAccumulator, _pres[account], _versions[latestVersion_], settleVersion);

        // short-circuit from a->c if b == c
        if (settleOracleVersion.version != currentOracleVersion.version) {
            // sync incentivizer before accumulator
            _controller.incentivizer().syncAccount(account, currentOracleVersion);

            // account b->c
            (valueAccumulator) = _accounts[account].accumulate(valueAccumulator, settleVersion, currentVersion);
        }

        // settle collateral
        _controller.collateral().settleAccount(account, valueAccumulator);

        // save state
        _latestVersions[account] = currentOracleVersion.version;
        delete _pres[account];

        emit AccountSettle(account, settleOracleVersion.version, currentOracleVersion.version);
    }

    /**
     * @notice Opens a taker position for `msg.sender`
     * @param amount Amount of the position to open
     */
    function openTake(UFixed18 amount)
    external
    nonReentrant
    notPaused
    notClosed
    settleForAccount(msg.sender)
    takerInvariant
    positionInvariant
    liquidationInvariant
    maintenanceInvariant
    {
        IOracleProvider.OracleVersion memory latestOracleVersion = atVersion(latestVersion());
        (, , , UFixed18 takerFee, ) = parameter();

        _pres[msg.sender].openTake(amount);
        _pre.openTake(amount);

        UFixed18 positionFee = amount.mul(latestOracleVersion.price.abs()).mul(takerFee);
        if (!positionFee.isZero()) controller().collateral().settleAccount(msg.sender, Fixed18Lib.from(-1, positionFee));

        emit TakeOpened(msg.sender, _latestVersion, amount);
    }

    /**
     * @notice Closes a taker position for `msg.sender`
     * @param amount Amount of the position to close
     */
    function closeTake(UFixed18 amount)
    external
    nonReentrant
    notPaused
    settleForAccount(msg.sender)
    closeInvariant
    liquidationInvariant
    {
        _closeTake(msg.sender, amount);
    }

    function _closeTake(address account, UFixed18 amount) private {
        IOracleProvider.OracleVersion memory latestOracleVersion = atVersion(latestVersion());
        (, , , UFixed18 takerFee, ) = parameter();

        _pres[account].closeTake(amount);
        _pre.closeTake(amount);

        UFixed18 positionFee = amount.mul(latestOracleVersion.price.abs()).mul(takerFee);
        if (!positionFee.isZero()) controller().collateral().settleAccount(account, Fixed18Lib.from(-1, positionFee));

        emit TakeClosed(account, _latestVersion, amount);
    }

    /**
     * @notice Opens a maker position for `msg.sender`
     * @param amount Amount of the position to open
     */
    function openMake(UFixed18 amount)
    external
    nonReentrant
    notPaused
    notClosed
    settleForAccount(msg.sender)
    nonZeroVersionInvariant
    makerInvariant
    positionInvariant
    liquidationInvariant
    maintenanceInvariant
    {
        IOracleProvider.OracleVersion memory latestOracleVersion = atVersion(latestVersion());
        (, , UFixed18 makerFee, , ) = parameter();

        _pres[msg.sender].openMake(amount);
        _pre.openMake(amount);

        UFixed18 positionFee = amount.mul(latestOracleVersion.price.abs()).mul(makerFee);
        if (!positionFee.isZero()) controller().collateral().settleAccount(msg.sender, Fixed18Lib.from(-1, positionFee));

        emit MakeOpened(msg.sender, _latestVersion, amount);
    }

    /**
     * @notice Closes a maker position for `msg.sender`
     * @param amount Amount of the position to close
     */
    function closeMake(UFixed18 amount)
    external
    nonReentrant
    notPaused
    settleForAccount(msg.sender)
    takerInvariant
    closeInvariant
    liquidationInvariant
    {
        _closeMake(msg.sender, amount);
    }

    function _closeMake(address account, UFixed18 amount) private {
        IOracleProvider.OracleVersion memory latestOracleVersion = atVersion(latestVersion());
        (, , UFixed18 makerFee, , ) = parameter();

        _pres[account].closeMake(amount);
        _pre.closeMake(amount);

        UFixed18 positionFee = amount.mul(latestOracleVersion.price.abs()).mul(makerFee);
        if (!positionFee.isZero()) controller().collateral().settleAccount(account, Fixed18Lib.from(-1, positionFee));

        emit MakeClosed(account, _latestVersion, amount);
    }

    /**
     * @notice Closes all open and pending positions, locking for liquidation
     * @dev Only callable by the Collateral contract as part of the liquidation flow
     * @param account Account to close out
     */
    function closeAll(address account) external onlyCollateral notClosed settleForAccount(account) {
        Account storage account_ = _accounts[account];
        Position memory position_ = account_.position.next(_pres[account]);

        // Close all positions
        _closeMake(account, position_.maker);
        _closeTake(account, position_.taker);

        // Mark liquidation to lock position
        account_.liquidation = true;
    }

    /**
     * @notice Returns the maintenance requirement for `account`
     * @param account Account to return for
     * @return The current maintenance requirement
     */
    function maintenance(address account) external view returns (UFixed18) {
        (UFixed18 _maintenance, , , , ) = parameter();
        return _accounts[account].maintenance(currentVersion(), _maintenance);
    }

    /**
     * @notice Returns the maintenance requirement for `account` after next settlement
     * @dev Assumes no price change and no funding, used to protect user from over-opening
     * @param account Account to return for
     * @return The next maintenance requirement
     */
    function maintenanceNext(address account) external view returns (UFixed18) {
        (UFixed18 _maintenance, , , , ) = parameter();
        return _accounts[account].maintenanceNext(_pres[account], currentVersion(), _maintenance);
    }

    /**
     * @notice Returns whether `account` is currently locked for an in-progress liquidation
     * @param account Account to return for
     * @return Whether the account is in liquidation
     */
    function isLiquidating(address account) external view returns (bool) {
        return _accounts[account].liquidation;
    }

    /**
     * @notice Returns `account`'s current position
     * @param account Account to return for
     * @return Current position of the account
     */
    function position(address account) external view returns (Position memory) {
        return _accounts[account].position;
    }

    /**
     * @notice Returns `account`'s current pending-settlement position
     * @param account Account to return for
     * @return Current pre-position of the account
     */
    function pre(address account) external view returns (PrePosition memory) {
        return _pres[account];
    }

    /**
     * @notice Returns the global latest settled oracle version
     * @return Latest settled oracle version of the product
     */
    function latestVersion() public view returns (uint256) {
        return _latestVersion;
    }

    /**
     * @notice Returns the global position at oracleVersion `oracleVersion`
     * @dev Only valid for the version at which a global settlement occurred
     * @param oracleVersion Oracle version to return for
     * @return Global position at oracle version
     */
    function positionAtVersion(uint256 oracleVersion) public view returns (Position memory) {
        return _versions[oracleVersion].position();
    }

    /**
     * @notice Returns the current global pending-settlement position
     * @return Global pending-settlement position
     */
    function pre() public view returns (PrePosition memory) {
        return _pre;
    }

    /**
     * @notice Returns the global accumulator value at oracleVersion `oracleVersion`
     * @dev Only valid for the version at which a global settlement occurred
     * @param oracleVersion Oracle version to return for
     * @return Global accumulator value at oracle version
     */
    function valueAtVersion(uint256 oracleVersion) external view returns (Accumulator memory) {
        return _versions[oracleVersion].value();
    }

    /**
     * @notice Returns the global accumulator share at oracleVersion `oracleVersion`
     * @dev Only valid for the version at which a global settlement occurred
     * @param oracleVersion Oracle version to return for
     * @return Global accumulator share at oracle version
     */
    function shareAtVersion(uint256 oracleVersion) external view returns (Accumulator memory) {
        return _versions[oracleVersion].share();
    }

    /**
     * @notice Returns `account`'s latest settled oracle version
     * @param account Account to return for
     * @return Latest settled oracle version of the account
     */
    function latestVersion(address account) public view returns (uint256) {
        return _latestVersions[account];
    }

    /**
     * @notice Updates product closed state
     * @dev only callable by product owner. Settles the product before flipping the flag
     * @param newClosed new closed value
     */
    function updateClosed(bool newClosed) external onlyProductOwner {
        (IOracleProvider.OracleVersion memory oracleVersion, ) = _settle();
        _closed.store(newClosed);
        emit ClosedUpdated(newClosed, oracleVersion.version);
    }

    /// @dev Limit total maker for guarded rollouts
    modifier makerInvariant {
        _;

        Position memory next = positionAtVersion(_latestVersion).next(_pre);

        if (next.maker.gt(makerLimit())) revert ProductMakerOverLimitError();
    }

    /// @dev Limit maker short exposure to the range 0.0-1.0x of their position. Does not apply when in closeOnly state
    modifier takerInvariant {
        _;

        if (closed()) return;

        Position memory next = positionAtVersion(_latestVersion).next(_pre);
        UFixed18 socializationFactor = next.socializationFactor();

        if (socializationFactor.lt(UFixed18Lib.ONE)) revert ProductInsufficientLiquidityError(socializationFactor);
    }

    /// @dev Ensure that the user has only taken a maker or taker position, but not both
    modifier positionInvariant {
        _;

        if (_accounts[msg.sender].isDoubleSided(_pres[msg.sender])) revert ProductDoubleSidedError();
    }

    /// @dev Ensure that the user hasn't closed more than is open
    modifier closeInvariant {
        _;

        if (_accounts[msg.sender].isOverClosed(_pres[msg.sender])) revert ProductOverClosedError();
    }

    /// @dev Ensure that the user will have sufficient margin for maintenance after next settlement
    modifier maintenanceInvariant {
        _;

        if (controller().collateral().liquidatableNext(msg.sender, IProduct(this)))
            revert ProductInsufficientCollateralError();
    }

    /// @dev Ensure that the user is not currently being liquidated
    modifier liquidationInvariant {
        if (_accounts[msg.sender].liquidation) revert ProductInLiquidationError();

        _;
    }

    /// @dev Helper to fully settle an account's state
    modifier settleForAccount(address account) {
        (IOracleProvider.OracleVersion memory currentOracleVersion, Version memory currentVersion) = _settle();
        _settleAccount(account, currentOracleVersion, currentVersion);

        _;
    }

    /// @dev Ensure we have bootstraped the oracle before creating positions
    modifier nonZeroVersionInvariant {
        if (_latestVersion == 0) revert ProductOracleBootstrappingError();

        _;
    }

    /// @dev Ensure the product is not closed
    modifier notClosed {
        if (closed()) revert ProductClosedError();

        _;
    }
}

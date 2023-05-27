//SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

import "./interfaces/IVault.sol";
import "@equilibria/root/control/unstructured/UInitializable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./VaultDefinition.sol";
import "./types/Delta.sol";

// TODO: only pull out what you can from collateral when really unbalanced
// TODO: make sure maker fees are supported

/**
 * @title Vault
 * @notice ERC4626 vault that manages a 50-50 position between long-short markets of the same payoff on Perennial.
 * @dev Vault deploys and rebalances collateral between the corresponding long and short markets, while attempting to
 *      maintain `targetLeverage` with its open positions at any given time. Deposits are only gated in so much as to cap
 *      the maximum amount of assets in the vault. The long and short markets are expected to have the same oracle and
 *      opposing payoff functions.
 *
 *      The vault has a "delayed mint" mechanism for shares on deposit. After depositing to the vault, a user must wait
 *      until the next settlement of the underlying products in order for shares to be reflected in the getters.
 *      The shares will be fully reflected in contract state when the next settlement occurs on the vault itself.
 *      Similarly, when redeeming shares, underlying assets are not claimable until a settlement occurs.
 *      Each state changing interaction triggers the `settle` flywheel in order to bring the vault to the
 *      desired state.
 *      In the event that there is not a settlement for a long period of time, keepers can call the `sync` method to
 *      force settlement and rebalancing. This is most useful to prevent vault liquidation due to PnL changes
 *      causing the vault to be in an unhealthy state (far away from target leverage)
 *
 *      This implementation is designed to be upgrade-compatible with instances of the previous single-payoff
 *      Vault, here: https://github.com/equilibria-xyz/perennial-mono/blob/d970debe95e41598228e8c4ae52fb816797820fb/packages/perennial-vaults/contracts/Vault.sol.
 */
contract Vault is IVault, VaultDefinition, UInitializable {
    /// @dev The name of the vault
    string public name;

    /// @dev Mapping of allowance across all users
    mapping(address => mapping(address => UFixed18)) public allowance;

    /// @dev Mapping of shares of the vault per user
    mapping(address => UFixed18) public balanceOf;

    /// @dev Total number of shares across all users
    UFixed18 public totalSupply;

    /// @dev Mapping of unclaimed underlying of the vault per user
    mapping(address => UFixed18) public unclaimed;

    /// @dev Total unclaimed underlying of the vault across all users
    UFixed18 public totalUnclaimed;

    uint256 public currentId;
    uint256 public latestId;

    Delta private _pending;

    /// @dev
    mapping(uint256 id => Delta) private _delta;

    mapping(address account => uint256 version) public latestVersions;

    /// @dev
    mapping(address account => Delta) private _deltas;

    /// @dev Per-version accounting state variables
    mapping(uint256 version => Version) private _versions;

    /**
     * @notice Constructor for VaultDefinition
     * @param factory_ The factory contract
     * @param targetLeverage_ The target leverage for the vault
     * @param maxCollateral_ The maximum amount of collateral that can be held in the vault
     * @param marketDefinitions_ The market definitions for the vault
     */
    constructor(
        IFactory factory_,
        UFixed18 targetLeverage_,
        UFixed18 maxCollateral_,
        MarketDefinition[] memory marketDefinitions_
    )
    VaultDefinition(factory_, targetLeverage_, maxCollateral_, marketDefinitions_)
    { }

    /**
     * @notice Initializes the contract state
     * @param name_ ERC20 asset name
     */
    function initialize(string memory name_) external initializer(1) {
        name = name_;

        // set or reset allowance compliant with both an initial deployment or an upgrade
        for (uint256 marketId; marketId < totalMarkets; marketId++) {
            asset.approve(address(markets(marketId).market), UFixed18Lib.ZERO);
            asset.approve(address(markets(marketId).market));
        }
    }

    /**
     * @notice Syncs `account`'s state up to current
     * @dev Also rebalances the collateral and position of the vault without a deposit or withdraw
     * @param account The account that should be synced
     */
    function settle(address account) public {
        Context memory context = _settle(account);
        _rebalance(context, UFixed18Lib.ZERO);
    }

    /**
     * @notice Deposits `assets` assets into the vault, returning shares to `account` after the deposit settles.
     * @param assets The amount of assets to deposit
     * @param account The account to deposit on behalf of
     */
    function deposit(UFixed18 assets, address account) external {
        Context memory context = _settle(account);
        if (assets.gt(_maxDeposit(context))) revert VaultDepositLimitExceededError();

        if (context.latest >= _deltas[account].version) {
            _pending.deposit = _pending.deposit.add(assets);
            _delta[currentId].deposit = _delta[currentId].deposit.add(assets);
            _deltas[account].version = context.current;
            _deltas[account].deposit = assets;
        } else revert VaultExistingOrderError();

        asset.pull(msg.sender, assets);

        _rebalance(context, UFixed18Lib.ZERO);

        emit Deposit(msg.sender, account, context.current, assets);
    }

    /**
     * @notice Redeems `shares` shares from the vault
     * @dev Does not return any assets to the user due to delayed settlement. Use `claim` to claim assets
     *      If account is not msg.sender, requires prior spending approval
     * @param shares The amount of shares to redeem
     * @param account The account to redeem on behalf of
     */
    function redeem(UFixed18 shares, address account) external {
        if (msg.sender != account) _consumeAllowance(account, msg.sender, shares);

        Context memory context = _settle(account);
        if (shares.gt(_maxRedeem(context, account))) revert VaultRedemptionLimitExceededError();

        if (context.latest >= _deltas[account].version) {
            _pending.redemption = _pending.redemption.add(shares);
            _delta[currentId].redemption = _delta[currentId].redemption.add(shares);
            _deltas[account].version = context.current;
            _deltas[account].redemption = shares;
        } else revert VaultExistingOrderError();

        balanceOf[account] = balanceOf[account].sub(shares);
        totalSupply = totalSupply.sub(shares); // TODO: can we keep this?

        _rebalance(context, UFixed18Lib.ZERO);

        emit Redemption(msg.sender, account, context.current, shares);
    }

    /**
     * @notice Claims all claimable assets for account, sending assets to account
     * @param account The account to claim for
     */
    function claim(address account) external {
        Context memory context = _settle(account);

        UFixed18 unclaimedAmount = unclaimed[account];
        UFixed18 unclaimedTotal = totalUnclaimed;
        unclaimed[account] = UFixed18Lib.ZERO;
        totalUnclaimed = unclaimedTotal.sub(unclaimedAmount);
        emit Claim(msg.sender, account, unclaimedAmount);

        // pro-rate if vault has less collateral than unclaimed
        UFixed18 claimAmount = unclaimedAmount;
        UFixed18 totalCollateral = UFixed18Lib.from(_collateral(context).max(Fixed18Lib.ZERO));
        if (totalCollateral.lt(unclaimedTotal))
            claimAmount = claimAmount.muldiv(totalCollateral, unclaimedTotal);

        _rebalance(context, claimAmount);

        asset.push(account, claimAmount);
    }

    /**
     * @notice Sets `amount` as the allowance of `spender` over the caller's shares
     * @param spender Address which can spend operate on shares
     * @param amount Amount of shares that spender can operate on
     * @return bool true if the approval was successful, otherwise reverts
     */
    function approve(address spender, UFixed18 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice The maximum available deposit amount
     * @dev Only exact when vault is synced, otherwise approximate
     * @return Maximum available deposit amount
     */
    function maxDeposit(address) external view returns (UFixed18) {
        return _maxDeposit(_loadContextForRead(address(0)));
    }

    /**
     * @notice The maximum available redeemable amount
     * @dev Only exact when vault is synced, otherwise approximate
     * @param account The account to redeem for
     * @return Maximum available redeemable amount
     */
    function maxRedeem(address account) external view returns (UFixed18) {
        return _maxRedeem(_loadContextForRead(account), account);
    }

    /**
     * @notice The total amount of assets currently held by the vault
     * @return Amount of assets held by the vault
     */
    function totalAssets() external view returns (UFixed18) {
        return _totalAssets(_loadContextForRead(address(0)));
    }

    /**
     * @notice Converts a given amount of assets to shares
     * @param assets Number of assets to convert to shares
     * @return Amount of shares for the given assets
     */
    function convertToShares(UFixed18 assets) external view returns (UFixed18) {
        UFixed18 totalAssets = _totalAssets(_loadContextForRead(address(0))); // TODO: clean up
        return totalAssets.isZero() ? assets: assets.muldiv(totalSupply, totalAssets);
    }

    /**
     * @notice Converts a given amount of shares to assets
     * @param shares Number of shares to convert to assets
     * @return Amount of assets for the given shares
     */
    function convertToAssets(UFixed18 shares) external view returns (UFixed18) {
        UFixed18 totalAssets = _totalAssets(_loadContextForRead(address(0)));  // TODO: clean up
        return totalSupply.isZero() ? shares : shares.muldiv(totalAssets, totalSupply);
    }

    /**
     * @notice Hook that is called before every stateful operation
     * @dev Settles the vault's account on both the long and short product, along with any global or user-specific deposits/redemptions
     * @param account The account that called the operation, or 0 if called by a keeper.
     * @return context The current epoch contexts for each market
     */
    function _settle(address account) private returns (Context memory context) {
        context = _loadContextForWrite(account);

        while (context.latest >= _delta[latestId + 1].version && currentId > latestId)
            _processDelta(_delta[latestId + 1]);
        if (context.latest >= _deltas[account].version && context.latest > latestVersions[account]) {
            _processDeltaAccount(account, _deltas[account]);
            _deltas[account].clear();
        }

        if (context.current > _delta[currentId].version) {
            for (uint256 marketId; marketId < totalMarkets; marketId++) {
                _versions[context.current].ids[marketId] = context.markets[marketId].currentId;
            }
            _versions[context.current].basis.shares = totalSupply;
            _versions[context.current].basis.assets = _assets();

            currentId++;
            _delta[currentId].version = context.current;
        }
    }

    function _processDelta(Delta memory delta) private {
        // sync state
        Basis memory basis = basis(delta.version);
        totalSupply = totalSupply.add(_convertToShares(basis, delta.deposit));
        totalUnclaimed = totalUnclaimed.add(_convertToAssets(basis, delta.redemption));

        // prepare for the next delta id
        _pending.deposit = _pending.deposit.sub(delta.deposit);
        _pending.redemption = _pending.redemption.sub(delta.redemption);
        latestId++;
    }

    function _processDeltaAccount(address account, Delta memory delta) private {
        if (account == address(0)) return; // gas optimization

        // sync state
        Basis memory basis = basis(delta.version);
        balanceOf[account] = balanceOf[account].add(_convertToShares(basis, delta.deposit));
        unclaimed[account] = unclaimed[account].add(_convertToAssets(basis, delta.redemption));
        latestVersions[account] = delta.version;
    }

    function _assets() private view returns (Fixed18) {
        return Fixed18Lib.from(asset.balanceOf())
            .sub(Fixed18Lib.from(_pending.deposit))
            .sub(Fixed18Lib.from(totalUnclaimed));
    }

    /**
     * @notice Rebalances the collateral and position of the vault
     * @dev Rebalance is executed on best-effort, any failing legs of the strategy will not cause a revert
     * @param claimAmount The amount of assets that will be withdrawn from the vault at the end of the operation
     */
    function _rebalance(Context memory context, UFixed18 claimAmount) private {
        Fixed18 collateralInVault = _collateral(context).sub(Fixed18Lib.from(claimAmount));
        UFixed18 minCollateral = _toU18(factory.parameter().minCollateral);

        // if negative assets, skip rebalance
        if (collateralInVault.lt(Fixed18Lib.ZERO)) return;

        // Compute available collateral
        UFixed18 collateral = UFixed18Lib.from(collateralInVault);
        if (collateral.muldiv(minWeight, totalWeight).lt(minCollateral)) collateral = UFixed18Lib.ZERO;

        // Compute available assets
        UFixed18 assets = UFixed18Lib.from(
                collateralInVault
                    .sub(Fixed18Lib.from(totalUnclaimed.add(_pending.deposit)))
                    .max(Fixed18Lib.ZERO)
            )
            .mul(totalSupply.unsafeDiv(totalSupply.add(_pending.redemption)))
            .add(_pending.deposit);
        if (assets.muldiv(minWeight, totalWeight).lt(minCollateral)) assets = UFixed18Lib.ZERO;

        Target[] memory targets = _computeTargets(context, collateral, assets);

        // Remove collateral from markets above target
        for (uint256 marketId; marketId < totalMarkets; marketId++) {
            if (context.markets[marketId].collateral.gt(Fixed18Lib.from(targets[marketId].collateral)))
                _update(context.markets[marketId], markets(marketId).market, targets[marketId]);
        }

        // Deposit collateral to markets below target
        for (uint256 marketId; marketId < totalMarkets; marketId++) {
            if (context.markets[marketId].collateral.lte(Fixed18Lib.from(targets[marketId].collateral)))
                _update(context.markets[marketId], markets(marketId).market, targets[marketId]);
        }
    }

    function _computeTargets(
        Context memory context,
        UFixed18 collateral,
        UFixed18 assets
    ) private view returns (Target[] memory targets) {
        targets = new Target[](totalMarkets);

        for (uint256 marketId; marketId < totalMarkets; marketId++) {
            MarketDefinition memory marketDefinition = markets(marketId);

            UFixed18 marketAssets = assets.muldiv(marketDefinition.weight, totalWeight);
            if (context.markets[marketId].closed) marketAssets = UFixed18Lib.ZERO;

            OracleVersion memory latestOracleVersion = context.markets[marketId].oracle.at(context.latest);
            context.markets[marketId].payoff.transform(latestOracleVersion);
            UFixed18 currentPrice = _toU18(latestOracleVersion.price.abs());

            targets[marketId].collateral = collateral.muldiv(marketDefinition.weight, totalWeight);
            targets[marketId].position = _toU6(marketAssets.mul(targetLeverage).div(currentPrice));
        }
    }

    /**
     * @notice Adjusts the position on `market` to `targetPosition`
     * @param market The market to adjust the vault's position on
     * @param target The new state to target
     */
    function _update(MarketContext memory marketContext, IMarket market, Target memory target) private {
        // compute headroom until hitting taker amount
        if (target.position.lt(marketContext.currentPositionAccount)) {
            UFixed6 makerAvailable = marketContext.currentPosition.maker.gt(marketContext.currentPosition.net()) ?
                marketContext.currentPosition.maker.sub(marketContext.currentPosition.net()) :
                UFixed6Lib.ZERO;
            target.position = marketContext.currentPositionAccount
                .sub(marketContext.currentPositionAccount.sub(target.position).min(makerAvailable));
        }

        // compute headroom until hitting makerLimit
        if (target.position.gt(marketContext.currentPositionAccount)) {
            UFixed6 makerLimit = marketContext.makerLimit;
            UFixed6 makerAvailable = makerLimit.gt(marketContext.currentPosition.maker) ?
                makerLimit.sub(marketContext.currentPosition.maker) :
                UFixed6Lib.ZERO;
            target.position = marketContext.currentPositionAccount
                .add(target.position.sub(marketContext.currentPositionAccount).min(makerAvailable));
        }

        // issue position update
        market.update(
            address(this),
            target.position,
            UFixed6Lib.ZERO,
            UFixed6Lib.ZERO,
            Fixed6Lib.from(_toU6(target.collateral))
        );
    }

    /**
     * @notice Decrements `spender`s allowance for `account` by `amount`
     * @dev Does not decrement if approval is for -1
     * @param account Address of allower
     * @param spender Address of spender
     * @param amount Amount to decrease allowance by
     */
    function _consumeAllowance(address account, address spender, UFixed18 amount) private {
        if (allowance[account][spender].eq(UFixed18Lib.MAX)) return;
        allowance[account][spender] = allowance[account][spender].sub(amount);
    }

    /**
     * @notice Loads the context for the given `account`, settling the vault first
     * @param account Account to load the context for
     * @return Epoch context
     */
    function _loadContextForWrite(address account) private returns (Context memory) {
        for (uint256 marketId; marketId < totalMarkets; marketId++) {
            markets(marketId).market.settle(address(this));
        }

        return _loadContextForRead(account);
    }

    /**
     * @notice Loads the context for the given `account`
     * @param account Account to load the context for
     * @return context Epoch context
     */
    function _loadContextForRead(address account) private view returns (Context memory context) {
        context.current = current();
        context.latest = latest();

        context.markets = new MarketContext[](totalMarkets);
        for (uint256 marketId; marketId < totalMarkets; marketId++) {
            MarketDefinition memory marketDefinition = markets(marketId);
            MarketParameter memory marketParameter = marketDefinition.market.parameter();
            context.markets[marketId].closed = marketParameter.closed;
            context.markets[marketId].makerLimit = marketParameter.makerLimit;
            context.markets[marketId].oracle = marketParameter.oracle;
            context.markets[marketId].payoff = marketParameter.payoff;

            // global
            Global memory global = marketDefinition.market.global();
            Position memory currentPosition = marketDefinition.market.pendingPosition(global.currentId);
            Position memory latestPosition = marketDefinition.market.position();

            context.markets[marketId].currentPosition = currentPosition;

            // local
            Local memory local = marketDefinition.market.locals(address(this));
            currentPosition = marketDefinition.market.pendingPositions(address(this), local.currentId);
            latestPosition = marketDefinition.market.positions(address(this));
            uint256 currentVersion = marketParameter.oracle.current();

            context.markets[marketId].currentId = (currentVersion > currentPosition.version) ? local.currentId + 1 : local.currentId;
            context.markets[marketId].latestVersionAccount = latestPosition.version;
            context.markets[marketId].latestPositionAccount = latestPosition.maker;
            context.markets[marketId].currentPositionAccount = currentPosition.maker;
            context.markets[marketId].collateral = _toS18(local.collateral);
            context.markets[marketId].liquidation = local.liquidation;
        }
    }

    /**
     * @notice Calculates whether or not the vault is in an unhealthy state at the provided epoch
     * @param context Epoch context to calculate health
     * @return bool true if unhealthy, false if healthy
     */
    function _unhealthyAtEpoch(Context memory context) private view returns (bool) {
        Basis memory basis = basis(latest());
        if (!basis.shares.isZero() && basis.assets.lte(Fixed18Lib.ZERO)) return true;
        for (uint256 marketId; marketId < totalMarkets; marketId++) {
            if (_unhealthy(context.markets[marketId])) return true;
        }
        return false;
    }

    /**
     * @notice Determines whether the market pair is currently in an unhealthy state
     * @dev market is unhealthy if either the long or short markets are liquidating or liquidatable
     * @param marketContext The configuration of the market
     * @return bool true if unhealthy, false if healthy
     */
    function _unhealthy(MarketContext memory marketContext) internal view returns (bool) {
        //TODO: figure out how to compute "can liquidate"
        return /* collateral.liquidatable(address(this), marketDefinition.long) || */ (
            marketContext.liquidation > marketContext.latestVersionAccount
        );
    }

    /**
     * @notice The maximum available deposit amount at the given epoch
     * @param context Epoch context to use in calculation
     * @return Maximum available deposit amount at epoch
     */
    function _maxDeposit(Context memory context) private view returns (UFixed18) {
        UFixed18 collateral = UFixed18Lib.from(_collateral(context).max(Fixed18Lib.ZERO));
        return _unhealthyAtEpoch(context) ?
            UFixed18Lib.ZERO :
            maxCollateral.gt(collateral) ?
                maxCollateral.sub(collateral).add(totalUnclaimed) :
                totalUnclaimed;
    }

    /**
     * @notice The maximum available redeemable amount at the given epoch for `account`
     * @param context Epoch context to use in calculation
     * @param account Account to calculate redeemable amount
     * @return Maximum available redeemable amount at epoch
     */
    function _maxRedeem(Context memory context, address account) private view returns (UFixed18) {
        return _unhealthyAtEpoch(context) ? UFixed18Lib.ZERO : balanceOf[account];
    }

    /**
     * @notice The total assets at the given epoch
     * @param context Epoch context to use in calculation
     * @return Total assets amount at epoch
     */
    function _totalAssets(Context memory context) private view returns (UFixed18) {
        return UFixed18Lib.from(
            _collateral(context).sub(Fixed18Lib.from(totalUnclaimed.add(_pending.deposit))).max(Fixed18Lib.ZERO)
        );
    }

    /**
     * @notice Returns the real amount of collateral in the vault
     * @return value The real amount of collateral in the vault
     **/
    function _collateral(Context memory context) public view returns (Fixed18 value) {
        value = Fixed18Lib.from(asset.balanceOf());
        for (uint256 marketId; marketId < totalMarkets; marketId++)
            value = value.add(context.markets[marketId].collateral);
    }

    /**
     * @notice Converts a given amount of assets to shares at basis
     * @param assets Number of assets to convert to shares
     * @return Amount of shares for the given assets at basis
     */
    function _convertToShares(Basis memory basis, UFixed18 assets) private pure returns (UFixed18) {
        UFixed18 basisAssets = UFixed18Lib.from(basis.assets.max(Fixed18Lib.ZERO)); // TODO: what to do if vault is insolvent
        return basisAssets.isZero() ? assets : assets.muldiv(basis.shares, basisAssets);
    }

    /**
     * @notice Converts a given amount of shares to assets with basis
     * @param shares Number of shares to convert to shares
     * @return Amount of assets for the given shares at basis
     */
    function _convertToAssets(Basis memory basis, UFixed18 shares) private pure returns (UFixed18) {
        UFixed18 basisAssets = UFixed18Lib.from(basis.assets.max(Fixed18Lib.ZERO)); // TODO: what to do if vault is insolvent
        return basis.shares.isZero() ? shares : shares.muldiv(basisAssets, basis.shares);
    }

    function latest() public view returns (uint256 version) {
        version = type(uint256).max;
        for(uint256 marketId; marketId < totalMarkets; marketId++) {
            uint256 marketLatestVersion = markets(marketId).market.position().version;
            if (marketLatestVersion < version) version = marketLatestVersion;
        }
    }

    function current() public view returns (uint256 version) {
        version = type(uint256).max;
        for(uint256 marketId; marketId < totalMarkets; marketId++) {
            uint256 marketCurrentVersion = markets(marketId).market.parameter().oracle.current();
            if (marketCurrentVersion < version) version = marketCurrentVersion;
        }
    }

    function basis(uint256 version) public view returns (Basis memory basis) {
        basis = _versions[version].basis;

        for(uint256 marketId; marketId < totalMarkets; marketId++) {
            uint256 id = _versions[version].ids[marketId];
            Position memory position = markets(marketId).market.pendingPositions(address(this), id); // TODO: fix market and move this into that
            Position memory pre = markets(marketId).market.pendingPositions(address(this), id == 0 ? 0 : id - 1);
            Fixed18 marketCollateral = _toS18(position.collateral.sub(position.delta.sub(pre.delta)));

            basis.assets = basis.assets.add(marketCollateral);
        }

        // TODO: should this cap the assets at 0?
    }

    //TODO: replace these with root functions
    function _toU18(UFixed6 n) private pure returns (UFixed18) {
        return UFixed18.wrap(UFixed6.unwrap(n) * 1e12);
    }

    function _toU6(UFixed18 n) private pure returns (UFixed6) {
        return UFixed6.wrap(UFixed18.unwrap(n) / 1e12);
    }

    function _toS18(Fixed6 n) private pure returns (Fixed18) {
        return Fixed18.wrap(Fixed6.unwrap(n) * 1e12);
    }

    function _toS6(Fixed18 n) private pure returns (Fixed6) {
        return Fixed6.wrap(Fixed18.unwrap(n) / 1e12);
    }
}

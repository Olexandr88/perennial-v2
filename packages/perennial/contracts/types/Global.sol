// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import "@equilibria/root-v2/contracts/PAccumulator6.sol";
import "./ProtocolParameter.sol";
import "./MarketParameter.sol";

/// @dev Global type
struct Global {
    /// @dev The current position ID
    uint256 currentId;

    /// @dev The accrued protocol fee
    UFixed6 protocolFee;

    /// @dev The accrued oracle fee
    UFixed6 oracleFee;

    /// @dev The accrued risk fee
    UFixed6 riskFee;

    /// @dev The accrued donation
    UFixed6 donation;

    /// @dev The current PAccumulator state
    PAccumulator6 pAccumulator;

    /// @dev The latest valid price
    Fixed6 latestPrice;
}
using GlobalLib for Global global;
struct StoredGlobal { // TODO: pack better
    /* slot 1 */
    uint32 _currentId;
    uint48 _protocolFee;
    uint48 _oracleFee;
    uint48 _riskFee;
    uint48 _donation;
    int32 _pAccumulatorValue;

    /* slot 2 */
    int24 _pAccumulatorSkew;
    int64 _latestPrice;
}
struct GlobalStorage { StoredGlobal value; }
using GlobalStorageLib for GlobalStorage global;

/// @title Global
/// @notice Holds the global market state
library GlobalLib {
    /// @notice Increments the fees by `amount` using current parameters
    /// @param self The Global object to update
    /// @param amount The amount to increment fees by
    /// @param keeper The amount to increment the keeper fee by
    /// @param marketParameter The current market parameters
    /// @param protocolParameter The current protocol parameters
    function incrementFees(
        Global memory self,
        UFixed6 amount,
        UFixed6 keeper,
        MarketParameter memory marketParameter,
        ProtocolParameter memory protocolParameter
    ) internal pure {
        UFixed6 protocolFeeAmount = amount.mul(protocolParameter.protocolFee);
        UFixed6 marketFeeAmount = amount.sub(protocolFeeAmount);

        UFixed6 oracleFeeAmount = marketFeeAmount.mul(marketParameter.oracleFee);
        UFixed6 riskFeeAmount = marketFeeAmount.mul(marketParameter.riskFee);
        UFixed6 donationAmount = marketFeeAmount.sub(oracleFeeAmount).sub(riskFeeAmount);

        self.protocolFee = self.protocolFee.add(protocolFeeAmount);
        self.oracleFee = self.oracleFee.add(keeper).add(oracleFeeAmount);
        self.riskFee = self.riskFee.add(riskFeeAmount);
        self.donation = self.donation.add(donationAmount);
    }

    /// @notice Updates the latest valid price
    /// @param self The Global object to update
    /// @param latestPrice The new latest valid price
    function update(Global memory self, Fixed6 latestPrice) internal pure {
        self.latestPrice = latestPrice;
    }
}

library GlobalStorageLib {
    error GlobalStorageInvalidError();

    function read(GlobalStorage storage self) internal view returns (Global memory) {
        StoredGlobal memory storedValue = self.value;
        return Global(
            uint256(storedValue._currentId),
            UFixed6.wrap(uint256(storedValue._protocolFee)),
            UFixed6.wrap(uint256(storedValue._oracleFee)),
            UFixed6.wrap(uint256(storedValue._riskFee)),
            UFixed6.wrap(uint256(storedValue._donation)),
            PAccumulator6(
                Fixed6.wrap(int256(storedValue._pAccumulatorValue)),
                Fixed6.wrap(int256(storedValue._pAccumulatorSkew))
            ),
            Fixed6.wrap(int256(storedValue._latestPrice))
        );
    }

    function store(GlobalStorage storage self, Global memory newValue) internal {
        if (newValue.currentId > uint256(type(uint32).max)) revert GlobalStorageInvalidError();
        if (newValue.protocolFee.gt(UFixed6.wrap(type(uint48).max))) revert GlobalStorageInvalidError();
        if (newValue.oracleFee.gt(UFixed6.wrap(type(uint48).max))) revert GlobalStorageInvalidError();
        if (newValue.riskFee.gt(UFixed6.wrap(type(uint48).max))) revert GlobalStorageInvalidError();
        if (newValue.donation.gt(UFixed6.wrap(type(uint48).max))) revert GlobalStorageInvalidError();
        if (newValue.pAccumulator._value.gt(Fixed6.wrap(type(int32).max))) revert GlobalStorageInvalidError();
        if (newValue.pAccumulator._value.lt(Fixed6.wrap(type(int32).min))) revert GlobalStorageInvalidError();
        if (newValue.pAccumulator._skew.gt(Fixed6.wrap(type(int24).max))) revert GlobalStorageInvalidError();
        if (newValue.pAccumulator._skew.lt(Fixed6.wrap(type(int24).min))) revert GlobalStorageInvalidError();
        if (newValue.latestPrice.gt(Fixed6.wrap(type(int64).max))) revert GlobalStorageInvalidError();
        if (newValue.latestPrice.lt(Fixed6.wrap(type(int64).min))) revert GlobalStorageInvalidError();

        self.value = StoredGlobal(
            uint32(newValue.currentId),
            uint48(UFixed6.unwrap(newValue.protocolFee)),
            uint48(UFixed6.unwrap(newValue.oracleFee)),
            uint48(UFixed6.unwrap(newValue.riskFee)),
            uint48(UFixed6.unwrap(newValue.donation)),
            int32(Fixed6.unwrap(newValue.pAccumulator._value)),
            int24(Fixed6.unwrap(newValue.pAccumulator._skew)),
            int64(Fixed6.unwrap(newValue.latestPrice))
        );
    }
}

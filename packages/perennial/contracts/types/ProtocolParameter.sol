// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import "@equilibria/root-v2/contracts/UFixed6.sol";

/// @dev ProtocolParameter type
struct ProtocolParameter {
    UFixed6 protocolFee;    // <= 1677%
    UFixed6 minFundingFee;  // <= 1677%
    UFixed6 liquidationFee; // <= 1677%
    UFixed6 minCollateral;  // <= 281mn
    bool paused;
}
struct StoredProtocolParameter {
    uint24 protocolFee;     // <= 1677%
    uint24 minFundingFee;   // <= 1677%
    uint24 liquidationFee;  // <= 1677
    uint48 minCollateral;   // <= 281mn
    bool paused;

    bytes16 __unallocated__;
}
struct ProtocolParameterStorage { StoredProtocolParameter value; }
using ProtocolParameterStorageLib for ProtocolParameterStorage global;

library ProtocolParameterStorageLib {
    error ProtocolParameterStorageOverflowError();

    function read(ProtocolParameterStorage storage self) internal view returns (ProtocolParameter memory) {
        StoredProtocolParameter memory value = self.value;
        return ProtocolParameter(
            UFixed6.wrap(uint256(value.protocolFee)),
            UFixed6.wrap(uint256(value.minFundingFee)),
            UFixed6.wrap(uint256(value.liquidationFee)),
            UFixed6.wrap(uint256(value.minCollateral)),
            value.paused
        );
    }

    function store(ProtocolParameterStorage storage self, ProtocolParameter memory parameter) internal {
        //TODO: check mod for precision
        if (parameter.protocolFee.gt(UFixed6Lib.ONE)) revert ProtocolParameterStorageOverflowError();
        if (parameter.minFundingFee.gt(UFixed6Lib.ONE)) revert ProtocolParameterStorageOverflowError();
        if (parameter.liquidationFee.gt(UFixed6Lib.ONE)) revert ProtocolParameterStorageOverflowError();
        if (parameter.minCollateral.gt(UFixed6Lib.from(281_474_976))) revert ProtocolParameterStorageOverflowError();

        self.value = StoredProtocolParameter(
            uint24(UFixed6.unwrap(parameter.protocolFee)),
            uint24(UFixed6.unwrap(parameter.minFundingFee)),
            uint24(UFixed6.unwrap(parameter.liquidationFee)),
            uint48(UFixed6.unwrap(parameter.minCollateral)),
            parameter.paused,
            bytes16(0x00000000000000000000000000000000)
        );
    }
}
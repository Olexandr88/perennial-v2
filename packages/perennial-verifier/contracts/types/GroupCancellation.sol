// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import { UFixed6 } from "@equilibria/root/number/types/UFixed6.sol";
import { Fixed6 } from "@equilibria/root/number/types/Fixed6.sol";
import { Common, CommonLib } from "./Common.sol";

struct GroupCancellation {
    /// @dev The group to cancel
    uint256 group;

    /// @dev The common information for the intent
    Common common;
}
using GroupCancellationLib for GroupCancellation global;

/// @title GroupCancellationLib
/// @notice Library for GroupCancellation logic and data.
library GroupCancellationLib {
    bytes32 constant public STRUCT_HASH = keccak256("GroupCancellation(uint256 group,Common common)Common(address account,address domain,uint256 nonce,uint256 group,uint256 expiry)");

    function hash(GroupCancellation memory self) internal pure returns (bytes32) {
        return keccak256(abi.encode(STRUCT_HASH, self.group, CommonLib.hash(self.common)));
    }
}

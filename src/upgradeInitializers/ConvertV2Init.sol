// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibSouls} from "../libraries/LibSouls.sol";

/// @title ConvertV2Init - one-shot initializer for the ConvertFacetV2 upgrade
/// @notice Run via diamondCut's `_init` delegatecall so the Replace+Add cut, the
///         initial pricing curve AND the treasury land ATOMICALLY. No owner check
///         needed: diamondCut itself is owner-gated, and every value here can be
///         changed later in the open by ConvertFacetV2.setPricing / setTreasury
///         (the whole config is deliberately hot-reconfigurable, not one-shot).
///         `saleStart == 0` snaps to the cut's block timestamp.
contract ConvertV2Init {
    error BadBounds();
    error ZeroTreasury();

    function init(
        uint64 saleStart,
        uint32 bound1,
        uint32 bound2,
        uint32 bound3,
        uint256 price1,
        uint256 price2,
        uint256 price3,
        address treasury
    ) external {
        if (!(bound1 <= bound2 && bound2 <= bound3)) revert BadBounds();
        if (treasury == address(0)) revert ZeroTreasury();
        LibSouls.Layout storage l = LibSouls.layout();
        l.saleStart = saleStart == 0 ? uint64(block.timestamp) : saleStart;
        l.bound1 = bound1;
        l.bound2 = bound2;
        l.bound3 = bound3;
        l.price1 = price1;
        l.price2 = price2;
        l.price3 = price3;
        l.treasury = treasury;
        // leave _reentrancyLock at 0; convert() treats 0 as "not entered".
    }
}

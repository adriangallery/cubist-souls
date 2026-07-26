// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibSouls} from "../libraries/LibSouls.sol";

/// @title ReaperInit - one-shot seed of the initial mark prices for ReaperFacet
/// @notice Delegatecalled by diamondCut's `_init` so the Add cut and the initial mark
///         prices land ATOMICALLY. No owner check needed: diamondCut itself is
///         owner-gated, and every value is hot-reconfigurable later via
///         ReaperFacet.setMarkPrice.
///
///         Prices are in Pikkazo canvases (ratified by Adrian 2026-07-26):
///           0 Orange       6
///           1 FlameCrown  12
///           2 Phoenix     18
///           3 BurningSoul 30   (full set 66)
contract ReaperInit {
    function init() external {
        LibSouls.Layout storage l = LibSouls.layout();
        l.markPrices[0] = 6; // Orange
        l.markPrices[1] = 12; // FlameCrown
        l.markPrices[2] = 18; // Phoenix
        l.markPrices[3] = 30; // BurningSoul (skin)
    }
}
